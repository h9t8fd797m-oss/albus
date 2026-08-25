#!/usr/bin/env python3
"""Turn the IB knowledge base into retrievable sections.

    python3 scripts/knowledge/ingest.py "~/Desktop/Albus AI/albus_ib_knowledge_base.md"

Writes `scripts/knowledge/seed.sql`, applied by `apply_seed.sh`. Deliberately
not a migration: migrations are append-only history, and this file is
regenerated every time the document is revised.

The document is already a lookup structure — numbered sections, one topic each,
cross-referenced by number — so the retrieval unit is the subsection it was
written as. Splitting it any other way would cut across the boundaries its
author drew.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field

HEADING = re.compile(r"^(#{2,4})\s+(.*)$")
# "5.3 The word-count thresholds" / "7. INTERNAL ASSESSMENT"
NUMBERED = re.compile(r"^(\d+(?:\.\d+)*)\.?\s+(.*)$")

# Sections that must reach the model on every question about this corpus.
# These are the rules that stop it inventing an IB rule or reproducing a
# copyrighted descriptor — small enough to always afford, and what keeps every
# retrieved section honest.
ALWAYS = {"0.3", "14.1"}

# Retrieval hints, for sections a student asks about in words the heading does
# not contain. Written here rather than in the document so the document stays a
# document. Anything obvious from the title is left out — it is already indexed.
KEYWORDS: dict[str, str] = {
    "0.2": "label official derived strategy uncertain confidence trust",
    "1.2": "which guide syllabus year session first assessment 2025 2026 2027 current",
    "1.3": "wrong guide outdated old syllabus changed",
    "2.1": "structure groups six subjects higher standard level HL SL core hours",
    "2.2": "points score 45 total bonus matrix how many points",
    "2.3": "pass fail diploma awarded conditions requirements failing conditions",
    "3.1": "raw mark grade boundary scaled percentage",
    "3.2": "scaling weighting components combine paper weight",
    "3.3": "grade boundaries set awarding how many marks for a 7",
    "3.6": "moderation teacher mark changed lowered sample",
    "3.7": "predicted grades university offer",
    "3.8": "remark enquiry upon results EUR recheck challenge grade",
    "3.11": "extra time access arrangements inclusive dyslexia ADHD support",
    "3.12": "retake resit again november may repeat",
    "4.2": "command term evaluate discuss analyse compare contrast explain justify "
           "outline describe state suggest examine to what extent verb",
    "4.3": "answer the question marks lost misread verb",
    "5.2": "penalty consequence caught punishment no grade awarded",
    "5.3": "word count word limit too long over the limit maximum length how many words",
    "5.6": "AI ChatGPT artificial intelligence generative allowed cite acknowledge",
    "5.8": "citation referencing bibliography cite sources format",
    "6.1": "extended essay EE 4000 words research question supervisor",
    "6.2": "theory of knowledge TOK essay exhibition prescribed title objects",
    "6.3": "CAS creativity activity service reflections experiences project",
    "7.1": "internal assessment IA why important leverage marks",
    "7.2": "IA internal assessment word limit marks weighting criteria every subject table",
    "7.3": "biology chemistry physics science IA scientific investigation lab practical "
           "research question data analysis conclusion evaluation",
    "7.4": "maths mathematics AA AI exploration IA pages personal engagement",
    "7.5": "history IA historical investigation sources evaluation 2200",
    "7.6": "economics IA portfolio commentaries articles diagrams",
    "7.7": "business management IA research project supporting documents",
    "7.8": "geography IA fieldwork report data collection",
    "7.9": "language A literature english IA individual oral extract global issue",
    "7.10": "language B spanish french IA individual oral stimulus",
    "7.11": "ESS environmental systems societies IA individual investigation",
    "7.12": "computer science psychology IA 2027 new guide",
    "8.1": "get a 7 improve grade difference between 5 and 7 top marks",
    "8.2": "recover marks per subject where to improve",
    "9": "grade descriptor what does a 5 mean 6 7 4 3",
    "10.4": "running out of time triage panic behind deadline priorities",
    "11": "risk failing diploma at risk conditions danger",
    "12": "myth false rumour untrue misconception",
}


@dataclass
class Section:
    number: str
    title: str
    parent_title: str | None
    body: list[str] = field(default_factory=list)
    ordinal: int = 0

    @property
    def text(self) -> str:
        return "\n".join(self.body).strip()


def parse(markdown: str) -> list[Section]:
    """Deepest numbered heading wins; a parent's own preamble becomes its own row."""
    sections: list[Section] = []
    current: Section | None = None
    parent_title: str | None = None

    for line in markdown.splitlines():
        match = HEADING.match(line)
        if not match:
            if current is not None:
                current.body.append(line)
            continue

        hashes, heading = match.group(1), match.group(2).strip()
        numbered = NUMBERED.match(heading)

        if len(hashes) == 2:
            # A '##' opens a part of the document. It becomes a section itself
            # only if it carries prose before its first subsection — several do,
            # and section 9 and 12 have no subsections at all.
            parent_title = heading
            current = (
                Section(numbered.group(1), numbered.group(2), None)
                if numbered else None
            )
            if current:
                sections.append(current)
            continue

        if not numbered:
            # An unnumbered '###' is part of whatever it sits under.
            if current is not None:
                current.body.append(line)
            continue

        current = Section(numbered.group(1), numbered.group(2), parent_title)
        sections.append(current)

    # A '##' with subsections usually has nothing of its own but a rule line.
    kept = [s for s in sections if s.text]
    for i, section in enumerate(kept):
        section.ordinal = i
    return kept


def split_oversized(sections: list[Section], limit: int) -> list[Section]:
    """Keep any single retrieved section affordable.

    Two sections in this document are reference tables long enough to blow the
    budget on their own. Splitting on blank lines keeps table rows intact, which
    matters: half a markdown table is worse than none.
    """
    out: list[Section] = []
    for section in sections:
        text = section.text
        if len(text) <= limit:
            out.append(section)
            continue

        blocks, buffer = [], []
        size = 0
        for para in text.split("\n\n"):
            if size + len(para) > limit and buffer:
                blocks.append("\n\n".join(buffer))
                buffer, size = [], 0
            buffer.append(para)
            size += len(para) + 2
        if buffer:
            blocks.append("\n\n".join(buffer))

        for n, block in enumerate(blocks, start=1):
            part = Section(
                number=f"{section.number}" if n == 1 else f"{section.number}p{n}",
                title=section.title if n == 1 else f"{section.title} (continued)",
                parent_title=section.parent_title,
                ordinal=section.ordinal,
            )
            part.body = block.splitlines()
            out.append(part)
    return out


def quote(value: str | None) -> str:
    if value is None:
        return "null"
    return "'" + value.replace("'", "''") + "'"


def emit(sections: list[Section], corpus: str, source: str) -> str:
    lines = [
        f"-- Generated by scripts/knowledge/ingest.py from {os.path.basename(source)}",
        "-- Do not edit by hand. Re-run the script; the document is the source.",
        "--",
        "-- Idempotent: a revised document replaces the corpus wholesale rather than",
        "-- merging into it, because a section that was deleted upstream must not",
        "-- survive here answering questions.",
        "",
        "begin;",
        "",
        f"delete from public.knowledge_sections where corpus = {quote(corpus)};",
        "",
    ]
    for s in sections:
        keywords = KEYWORDS.get(s.number, "")
        always = "true" if s.number in ALWAYS else "false"
        lines.append(
            "insert into public.knowledge_sections "
            "(corpus, section, title, parent_title, body, keywords, always_include, ordinal)\n"
            f"values ({quote(corpus)}, {quote(s.number)}, {quote(s.title)}, "
            f"{quote(s.parent_title)}, {quote(s.text)}, {quote(keywords)}, {always}, {s.ordinal});"
        )
    lines += ["", "commit;", ""]
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("document")
    ap.add_argument("--corpus", default="IB_DP")
    ap.add_argument("--max-chars", type=int, default=6000,
                    help="largest single retrievable section, in characters")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "seed.sql"))
    args = ap.parse_args()

    path = os.path.expanduser(args.document)
    if not os.path.exists(path):
        print(f"no such document: {path}", file=sys.stderr)
        return 1

    with open(path, encoding="utf-8") as fh:
        sections = split_oversized(parse(fh.read()), args.max_chars)

    if not sections:
        print("parsed no sections — has the heading structure changed?", file=sys.stderr)
        return 1

    numbers = [s.number for s in sections]
    if len(set(numbers)) != len(numbers):
        duplicates = sorted({n for n in numbers if numbers.count(n) > 1})
        print(f"duplicate section numbers: {duplicates}", file=sys.stderr)
        return 1

    missing = ALWAYS - set(numbers)
    if missing:
        print(f"the always-included sections are not in the document: {sorted(missing)}",
              file=sys.stderr)
        return 1

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(emit(sections, args.corpus, path))

    total = sum(len(s.text) for s in sections)
    largest = max(sections, key=lambda s: len(s.text))
    print(f"{len(sections)} sections, {total:,} chars (~{total // 4:,} tokens)")
    print(f"largest: {largest.number} {largest.title!r} — {len(largest.text):,} chars")
    print(f"always included: {sorted(ALWAYS)}")
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
