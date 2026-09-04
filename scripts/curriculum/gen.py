#!/usr/bin/env python3
"""Turn verified specification data into the two things the app needs.

    data/*.json                          ← hand-verified against official specs
        │
        ├── ios/App/Albus/Models/Curriculum.swift        (bundled: drives the UI)
        └── supabase/migrations/NNNN_seed_curriculum.sql (server: grounds prompts)

**Why both, and why they are not interchangeable.** The bundled Swift drives
onboarding and the add-assignment pickers, so subject selection works offline and
costs nothing. The *prompt* is grounded from the server's copy, looked up by an
id the client sends.

That split is a security property. If the client supplied the criteria text used
to build a prompt, a modified client could put anything it liked into the model's
context. The client sends an id; the server reads its own trusted row.

Run after editing data/:

    python3 gen.py            # write both outputs
    python3 gen.py --check    # validate only, non-zero exit on a problem (CI)
"""

import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).parent
DATA = HERE / "data"
ROOT = HERE.parent.parent
SWIFT_OUT = ROOT / "ios" / "App" / "Albus" / "Models" / "Curriculum.swift"

# Deliberately NOT a migration.
#
# Migrations are append-only history — once applied they are never edited. This
# file is *regenerated* every time the corpus grows, so as a migration it would
# violate that rule on the second subject added. Seeding read-only reference data
# is not a schema change: the schema lives in migrations, the content lives here
# and is re-applied idempotently.
#
# `0025_seed_curriculum.sql` was the one-time bootstrap and is history now. It
# stays applied and untouched; everything after it flows through this file.
SQL_OUT = HERE / "seed.sql"

QUALIFICATIONS = {"A_LEVEL", "IB_DP", "AP", "OTHER"}

# What a curriculum is called on screen and in a prompt. A-level is absent
# because its name carries the board and is built per record.
QUALIFICATION_NAMES = {
    "IB_DP": "International Baccalaureate Diploma Programme",
    "AP": "Advanced Placement",
    "OTHER": "Other",
}
COMPONENT_KINDS = {"exam", "coursework", "internal_assessment", "practical", "oral"}

# How well we actually know a component's per-criterion mark split.
#
# This exists because the failure it prevents is invisible once shipped: a
# plausible-looking rubric that is not the real one sends a student to optimise
# their IA against marks that do not exist, and it does so with the authority of
# a printed table. Empty is a worse product and a better outcome than wrong.
#
#   official     — transcribed from the subject guide itself
#   corroborated — two or more independent sources agree; guide not seen
#   unverified   — we do not know, and must therefore publish no criteria
CRITERIA_CONFIDENCE = {"official", "corroborated", "unverified"}


class DataError(Exception):
    pass


def load():
    subjects = []
    for path in sorted(DATA.glob("*.json")):
        try:
            subjects.append((path.name, json.loads(path.read_text())))
        except json.JSONDecodeError as e:
            raise DataError(f"{path.name}: invalid JSON — {e}")
    return subjects


def validate(name, s):
    """Fail loudly on the mistakes that are invisible once shipped."""
    errs = []

    for field in ("code", "qualification", "subject", "source", "retrievedAt"):
        if not s.get(field):
            errs.append(f"missing '{field}'")

    if s.get("qualification") not in QUALIFICATIONS:
        errs.append(f"qualification must be one of {sorted(QUALIFICATIONS)}")

    # A board is part of a subject's identity only where boards differ. A-level
    # is assessed differently by each of them, so a missing board there is a
    # record that cannot be trusted; the IB is a single authority, so demanding
    # one would mean inventing it.
    if s.get("qualification") == "A_LEVEL" and not s.get("board"):
        errs.append("missing 'board' — A-level assessment differs by board")

    # Provenance is not optional. A record with no source cannot be re-checked
    # when a specification is revised, and every one of these will be revised.
    src = s.get("source", "")
    if src and not src.startswith("https://"):
        errs.append("source must be an https URL")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(s.get("retrievedAt", ""))):
        errs.append("retrievedAt must be YYYY-MM-DD")

    components = s.get("components", [])
    if not components:
        errs.append("no components — a subject with no assessment cannot ground anything")

    seen = set()
    total = 0
    for c in components:
        code = c.get("code")
        if not code:
            errs.append("a component has no code")
        elif code in seen:
            errs.append(f"duplicate component code '{code}'")
        seen.add(code)

        if c.get("kind") not in COMPONENT_KINDS:
            errs.append(f"{code}: kind must be one of {sorted(COMPONENT_KINDS)}")

        w = c.get("weighting")
        if not isinstance(w, (int, float)):
            errs.append(f"{code}: weighting must be a number")
        else:
            total += w

        # Where a component lists criteria AND a mark total, they must agree.
        # A rubric whose parts do not add up to its whole is worse than no
        # rubric — the student cannot tell which half is wrong.
        criteria = c.get("criteria") or []
        marks = c.get("marks")
        if criteria and isinstance(marks, int):
            summed = sum(x.get("marks") or 0 for x in criteria)
            if summed and summed != marks:
                errs.append(f"{code}: criteria sum to {summed} but component is {marks} marks")

        # Publishing a rubric is a claim about how a student is marked, so it
        # has to carry how well we know it. The sum check above catches a split
        # that is internally inconsistent; this catches one that is merely
        # invented — internally perfect and still not the real mark scheme.
        confidence = c.get("criteriaConfidence")
        if criteria:
            if confidence not in CRITERIA_CONFIDENCE:
                errs.append(
                    f"{code}: lists criteria, so criteriaConfidence must be one of "
                    f"{sorted(CRITERIA_CONFIDENCE)} (got {confidence!r})"
                )
            elif confidence == "unverified":
                errs.append(
                    f"{code}: criteriaConfidence is 'unverified', so it must publish no "
                    "criteria — remove them or raise the confidence with a source"
                )
            elif not c.get("criteriaSource"):
                errs.append(f"{code}: criteriaConfidence '{confidence}' needs a criteriaSource")
        elif confidence not in (None, "unverified"):
            errs.append(
                f"{code}: criteriaConfidence '{confidence}' but no criteria — "
                "either add them or drop the claim"
            )

    # Levels (SL/HL) are assessed separately, so each level sums to 100 alone.
    levels = {c.get("level") for c in components}
    for level in levels:
        at_level = [c for c in components if c.get("level") == level]
        total = sum(c.get("weighting") or 0 for c in at_level)
        if round(total) != 100:
            label = level or "(single level)"
            errs.append(f"weightings for {label} sum to {total}, not 100")

    for o in s.get("objectives", []):
        lo, hi = o.get("weightingMin"), o.get("weightingMax")
        if lo is not None and hi is not None and lo > hi:
            errs.append(f"{o.get('code')}: weightingMin > weightingMax")

    if errs:
        raise DataError(name + ":\n  - " + "\n  - ".join(errs))


def swift_literal(v):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    escaped = str(v).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def emit_swift(subjects):
    out = ['''import Foundation

// Generated by scripts/curriculum/gen.py — do not edit by hand.
//
// What a qualification assesses, and what each piece is worth. Bundled rather
// than fetched: subject selection has to work on a plane, and this never
// changes between releases.
//
// **What is deliberately not here.** Band descriptors — the prose explaining
// what 5-6 marks looks like — are the exam board's copyrighted assessment
// material. What is here is factual: component names, durations, marks,
// weightings, assessment objective codes. That is also what a planner actually
// needs; it turns into steps and time estimates. Descriptors would not.
//
// The server holds the same data and is what grounds a generated plan. This
// copy drives the UI. See gen.py for why they are separate.

struct CurriculumSubject: Identifiable, Hashable, Sendable {
    let code: String
    let qualification: Qualification
    /// Exam board. A-level assessment genuinely differs between boards, so this
    /// is part of a subject's identity rather than decoration. Nil where the
    /// qualification has a single authority, as the IB does.
    let board: String?
    let subject: String
    let specCode: String?
    let objectives: [Objective]
    let components: [Component]
    let notes: [String]
    /// Where the figures came from, so a revised specification can be re-checked
    /// against the exact page rather than re-researched from nothing.
    let source: String
    let retrievedAt: String

    var id: String { code }

    enum Qualification: String, CaseIterable, Sendable {
        case aLevel = "A_LEVEL"
        case ibDP = "IB_DP"
        case ap = "AP"
        case other = "OTHER"

        var title: String {
            switch self {
            case .aLevel: "A-Level"
            case .ibDP: "IB Diploma"
            case .ap: "Advanced Placement"
            case .other: "Other"
            }
        }
    }

    struct Objective: Hashable, Sendable {
        let code: String
        let name: String
        let weightingMin: Int?
        let weightingMax: Int?

        /// "30-35%", or "35%" when a board publishes a single figure.
        var weightingText: String? {
            switch (weightingMin, weightingMax) {
            case let (lo?, hi?) where lo != hi: "\\(lo)-\\(hi)%"
            case let (lo?, _): "\\(lo)%"
            default: nil
            }
        }
    }

    struct Component: Identifiable, Hashable, Sendable {
        let code: String
        let name: String
        let kind: Kind
        let minutes: Int?
        let marks: Int?
        let weighting: Double
        /// SL / HL for the IB. Nil where a qualification has one level.
        let level: String?
        let covers: String?
        let format: String?
        let criteria: [Criterion]

        var id: String { code }

        enum Kind: String, Hashable, Sendable {
            case exam, coursework, practical, oral
            case internalAssessment = "internal_assessment"

            /// What a student calls it.
            var title: String {
                switch self {
                case .exam: "Exam"
                case .coursework: "Coursework"
                case .practical: "Practical"
                case .oral: "Oral"
                case .internalAssessment: "Internal assessment"
                }
            }
        }
    }

    struct Criterion: Identifiable, Hashable, Sendable {
        let code: String
        let name: String
        let marks: Int?
        /// Our own one-line note on what this criterion rewards — written here,
        /// never lifted from the official descriptor.
        let guidance: String?

        var id: String { code }
    }
}

extension CurriculumSubject {
    /// Every subject we have verified assessment data for.
    static let all: [CurriculumSubject] = [
''']

    for _, s in subjects:
        objectives = ", ".join(
            "        .init(code: {}, name: {}, weightingMin: {}, weightingMax: {})".format(
                swift_literal(o["code"]), swift_literal(o["name"]),
                swift_literal(o.get("weightingMin")), swift_literal(o.get("weightingMax")),
            )
            for o in s.get("objectives", [])
        )
        components = []
        for c in s["components"]:
            criteria = ", ".join(
                ".init(code: {}, name: {}, marks: {}, guidance: {})".format(
                    swift_literal(x["code"]), swift_literal(x["name"]),
                    swift_literal(x.get("marks")), swift_literal(x.get("guidance")),
                )
                for x in (c.get("criteria") or [])
            )
            components.append(
                "            .init(code: {}, name: {}, kind: .{}, minutes: {}, marks: {}, "
                "weighting: {}, level: {}, covers: {}, format: {}, criteria: [{}])".format(
                    swift_literal(c["code"]), swift_literal(c["name"]),
                    {"internal_assessment": "internalAssessment"}.get(c["kind"], c["kind"]),
                    swift_literal(c.get("minutes")), swift_literal(c.get("marks")),
                    swift_literal(c["weighting"]), swift_literal(c.get("level")),
                    swift_literal(c.get("covers")), swift_literal(c.get("format")), criteria,
                )
            )
        notes = ", ".join(swift_literal(n) for n in s.get("notes", []))
        out.append(
            "        .init(\n"
            f"            code: {swift_literal(s['code'])},\n"
            f"            qualification: .{ {'A_LEVEL':'aLevel','IB_DP':'ibDP','AP':'ap','OTHER':'other'}[s['qualification']] },\n"
            f"            board: {swift_literal(s.get('board'))},\n"
            f"            subject: {swift_literal(s['subject'])},\n"
            f"            specCode: {swift_literal(s.get('specCode'))},\n"
            f"            objectives: [\n{objectives}\n            ],\n"
            "            components: [\n" + ",\n".join(components) + "\n            ],\n"
            f"            notes: [{notes}],\n"
            f"            source: {swift_literal(s['source'])},\n"
            f"            retrievedAt: {swift_literal(s['retrievedAt'])}\n"
            "        ),\n"
        )

    out.append('''    ]

    /// Subjects for one qualification, and — for A-level — one board, since the
    /// same subject is assessed differently by different boards.
    static func subjects(qualification: Qualification, board: String? = nil) -> [CurriculumSubject] {
        all.filter {
            $0.qualification == qualification && (board == nil || $0.board == board)
        }
        .sorted { $0.subject < $1.subject }
    }

    /// Boards offering a qualification, for the onboarding picker.
    static func boards(for qualification: Qualification) -> [String] {
        Set(all.filter { $0.qualification == qualification }.compactMap(\\.board))
            .sorted()
    }

    static func find(code: String) -> CurriculumSubject? {
        all.first { $0.code == code }
    }
}
''')
    return "".join(out)


def sql_quote(v):
    if v is None:
        return "null"
    return "'" + str(v).replace("'", "''") + "'"


def emit_sql(subjects):
    """Seed the tables the breakdown endpoint already reads.

    Idempotent: re-running must not duplicate rows, because this migration will
    be re-applied every time the corpus grows.
    """
    lines = ['''-- scripts/curriculum/seed.sql
--
-- Generated by scripts/curriculum/gen.py — do not edit by hand. Edit
-- scripts/curriculum/data/*.json and regenerate, or the file and the database
-- drift and the repo stops describing what is deployed.
--
-- Not a migration, on purpose: migrations are append-only history and this is
-- regenerated whenever a subject is added. Apply with ./apply_seed.sh.
--
-- This is what makes a generated plan curriculum-aware. `breakdown` looks up an
-- assessment type by the id the client sends and grounds the prompt in what that
-- component actually is — how long the paper is, what it is worth, what the
-- assessment objectives reward.
--
-- Read-only reference data: every table here already carries a read-all policy
-- for signed-in users and no write grant, so seeding adds no new attack surface.
--
-- Idempotent by design. It re-runs whenever the corpus grows.

''']

    curricula = {}
    for _, s in subjects:
        if s["qualification"] == "A_LEVEL":
            code = f"A_LEVEL_{s['board'].upper().replace(' ', '_')}"
            name = f"A-Level ({s['board']})"
        else:
            code = s["qualification"]
            # Named explicitly, never derived from the subject. This line used to
            # read `name = s["subject"]`, so the last subject in the corpus won
            # the dictionary and the IB Diploma Programme was renamed "Theory of
            # knowledge" in the live database — the name that goes into every IB
            # student's prompt as "Curriculum: ...".
            name = QUALIFICATION_NAMES.get(code)
            if not name:
                raise DataError(f"no display name for qualification '{code}' — add one")
        curricula[code] = name

    lines.append("-- Curricula. A-level is split by board because the boards genuinely\n"
                 "-- assess the same subject differently; treating them as one would be wrong.\n")
    for code, name in sorted(curricula.items()):
        lines.append(
            f"insert into public.curricula (code, name) values ({sql_quote(code)}, {sql_quote(name)})\n"
            f"  on conflict (code) do update set name = excluded.name;\n"
        )

    lines.append("\n-- Subjects, their components, and their assessment objectives.\n")
    for _, s_ in subjects:
        if s_["qualification"] == "A_LEVEL":
            curriculum = f"A_LEVEL_{s_['board'].upper().replace(' ', '_')}"
        else:
            curriculum = s_["qualification"]
        subject_code = s_["code"]

        lines.append(f"""
do $$
declare v_template uuid; v_assessment uuid;
begin
  insert into public.course_templates (curriculum_code, code, name)
  values ({sql_quote(curriculum)}, {sql_quote(subject_code)}, {sql_quote(s_['subject'])})
  on conflict (curriculum_code, code) do update set name = excluded.name
  returning id into v_template;

  delete from public.assessment_objectives where course_template_id = v_template;
""")
        for i, o in enumerate(s_.get("objectives", [])):
            lines.append(
                "  insert into public.assessment_objectives "
                "(course_template_id, code, name, weighting_min, weighting_max, ordinal)\n"
                f"  values (v_template, {sql_quote(o['code'])}, {sql_quote(o['name'])}, "
                f"{o.get('weightingMin') if o.get('weightingMin') is not None else 'null'}, "
                f"{o.get('weightingMax') if o.get('weightingMax') is not None else 'null'}, {i});\n"
            )
        for c in s_["components"]:
            lines.append(f"""
  insert into public.assessment_types (course_template_id, code, name, typical_minutes)
  values (v_template, {sql_quote(c['code'])}, {sql_quote(c['name'])}, {c.get('minutes') or 'null'})
  on conflict (course_template_id, code) do update
    set name = excluded.name, typical_minutes = excluded.typical_minutes
  returning id into v_assessment;
""")
            criteria = c.get("criteria") or []
            if criteria:
                lines.append("  delete from public.rubric_criteria where assessment_type_id = v_assessment;\n")
                for i, x in enumerate(criteria):
                    lines.append(
                        "  insert into public.rubric_criteria "
                        "(assessment_type_id, code, name, marks, guidance, ordinal)\n"
                        f"  values (v_assessment, {sql_quote(x['code'])}, {sql_quote(x['name'])}, "
                        f"{x.get('marks') or 'null'}, {sql_quote(x.get('guidance'))}, {i});\n"
                    )
        lines.append("end $$;\n")

    return "".join(lines)


def main():
    check_only = "--check" in sys.argv
    try:
        subjects = load()
        if not subjects:
            raise DataError("no data files in scripts/curriculum/data/")
        for name, s in subjects:
            validate(name, s)
    except DataError as e:
        print(f"✗ {e}", file=sys.stderr)
        return 1

    codes = [s["code"] for _, s in subjects]
    if len(codes) != len(set(codes)):
        print("✗ duplicate subject codes", file=sys.stderr)
        return 1

    print(f"✓ {len(subjects)} subjects valid")
    for _, s in subjects:
        board = f" [{s['board']}]" if s.get("board") else ""
        print(f"    {s['qualification']}{board} {s['subject']}: "
              f"{len(s['components'])} components, {len(s.get('objectives', []))} objectives")

    if check_only:
        return 0

    SWIFT_OUT.write_text(emit_swift(subjects))
    SQL_OUT.write_text(emit_sql(subjects))
    print(f"→ {SWIFT_OUT.relative_to(ROOT)}")
    print(f"→ {SQL_OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
