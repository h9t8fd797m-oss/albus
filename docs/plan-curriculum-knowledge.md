# Curriculum knowledge layer — plan

## 0. What research access actually looks like

Established by testing, not assumption, before designing anything.

| Source | Reachable | Authoritative | Notes |
| --- | --- | --- | --- |
| `ibo.org` (all paths) | **No — 403** | — | Cloudflare bot-detection. A real browser gets "Performing security verification". Not bypassed, deliberately. |
| IB full subject guides | **No** | Yes | Paywalled: IB store or the Programme Resource Centre (login). Not public to anyone without an IB account. |
| IB subject briefs (2pp) | **No** (to automation) | Yes | Public *to humans* on ibo.org; blocked to automated fetch like everything else on that host. |
| AQA | Yes (200) | Yes | Full specs public |
| OCR | Yes (200) | Yes | Full specs public |
| Pearson / Edexcel | Yes (200) | Yes | Full specs public |
| WJEC / Eduqas | Yes (200) | Yes | Full specs public |
| Cambridge International | Yes (200) | Yes | Full specs public |

**The consequence, stated plainly.** The A-Level half can be done to the standard
asked for: official board specifications, current versions, board-by-board. The
IB half cannot be done by me autonomously — the official documents are either
behind bot-detection I will not circumvent or behind a paywall.

The tempting move is to fill IB from tutoring sites (Clastify, RevisionDojo,
Studocu, and similar dominate every search for IB criteria). I am not doing that.
Those are third-party paraphrases of copyrighted criteria, of unknown accuracy
and unknown syllabus vintage — IB revised the sciences for 2025 and other groups
on rolling cycles. A student planning six weeks of coursework around a criterion
that no longer exists is worse off than a student with no curriculum layer at
all, and they would have no way to tell.

So: **IB gets the structure and an ingestion path, not invented content.**

## 1. What gets stored, and what deliberately does not

**Stored — facts, not prose:**

- component names (`Paper 1`, `Internal Assessment`, `NEA`), durations, raw
  marks, percentage weightings, SL/HL split
- assessment objective codes and their weighting ranges (`AO1: 35–40%`)
- criterion codes, names and mark allocations (`Criterion B: Analysis, 6 marks`)
- word/time limits, and how many separately-assessed pieces a component has

**Not stored — the band descriptors.** The paragraph explaining what 5–6 marks
looks like under Criterion B is creative expression owned by the IB or the board.
Reproducing those at scale into a shipped commercial app is republishing someone
else's assessment material. Two reasons this costs us nothing:

1. The planner does not need them. It needs to know a component exists, what it
   is worth, and roughly how long it takes — that is what turns into steps and
   time estimates.
2. Where guidance genuinely helps, we write our own one-line planning note
   ("this criterion rewards evaluating sources, not summarising them"). Ours,
   short, and honest about being ours.

Marks, weightings and component structure are facts about a qualification, not
authorship, and are quoted routinely by schools and universities.

## 2. Data structure

One source of truth, two generated outputs — the pattern `scripts/tools/gen.py`
already establishes for the tool catalogue.

```
scripts/curriculum/data/*.json      ← hand-verified, one file per board/curriculum
scripts/curriculum/gen.py           ← validates + emits both outputs
   ├── ios/App/Albus/Models/Curriculum.swift     (bundled, drives the UI)
   └── supabase/migrations/00NN_seed_curriculum.sql  (server-side grounding)
```

Shape:

```jsonc
{
  "code": "AQA_ALEVEL_BIOLOGY",
  "board": "AQA",
  "qualification": "A-Level",
  "subject": "Biology",
  "specCode": "7402",
  "source": "https://www.aqa.org.uk/...",   // exact page the numbers came from
  "retrievedAt": "2026-08-24",
  "objectives": [ { "code": "AO1", "name": "...", "weightingMin": 35, "weightingMax": 40 } ],
  "components": [
    { "code": "PAPER_1", "name": "Paper 1", "marks": 91, "minutes": 120,
      "weighting": 35, "level": null, "criteria": [] }
  ]
}
```

**Why both outputs, and why the server copy is the one that grounds prompts.**
The bundled Swift file drives onboarding and the add-assignment pickers — it must
be local so subject selection works offline and costs nothing. But the *prompt*
is grounded from the server's own seeded copy, looked up by an id the client
sends. The client never sends criteria text.

That is a security property, not a preference: if the client supplied the rubric
text used to build a prompt, a modified client could put anything it liked into
the model's context. Sending `assessment_type_id` and letting the server read its
own trusted row keeps that door shut, and it is exactly how `loadRubric()`
already works.

## 3. Integration

This also fixes a dead path found earlier: `assessment_type_id` is currently
never sent, so `loadRubric()` always receives `nil` and the curriculum branch of
the breakdown prompt can never fire. The corpus is useless until this is wired.

1. **Onboarding** — pick curriculum (IB / A-Level + board / Other), then pick
   subjects from that curriculum's real subject list.
2. **Add assignment** — when the chosen subject has known components, offer them
   ("Biology HL → Internal Assessment") instead of only free-text.
3. **Breakdown** — send `assessment_type_id`; the server grounds from its seed.
4. **Fallback is unchanged** — no subject match, or "Other", still plans
   generically. Nothing regresses for a student we have no data for.

Personal rubrics keep priority over curriculum rubrics: the sheet the teacher
actually handed out beats our generic copy of the specification.

## 4. Verification

Data this size is exactly where silent errors hide, so it is tested like code:

- weightings sum to 100 per subject/level (catches a mistyped percentage)
- criterion marks sum to the component total where both are given
- every `source` is a real URL and every record has `retrievedAt`
- no orphan references between subjects, components and criteria
- a spot-check diff of a sample of records against the source page

## 5. Order of execution

1. Schema, generator, and the two emitters — machinery first, so data has
   somewhere correct to land.
2. Wire `assessment_type_id` end to end and prove the curriculum branch fires.
3. A-Level subjects, board by board, from official specs.
4. IB: subject/group structure only, plus a documented ingestion path.
5. Tests and a verification pass over everything populated.

## 6. What stays open for Felipe

**The IB corpus needs one manual step.** ibo.org serves a human browser fine —
the block is on automation. Either:

- download the official subject briefs for the IB subjects that matter and drop
  the PDFs into `scripts/curriculum/inbox/`, and I parse them; or
- if you have IB Programme Resource Centre access, the full guides give the
  actual IA criteria and mark allocations, which briefs do not.

Either way the parsing is mine. The retrieval has to be yours.

---

## What was built (2026-08-24)

**The pipeline is complete and proven end to end.** The differentiator now
works; before today it was structurally impossible, for two independent reasons
that both had to be fixed.

### Verified subjects

| Qualification | Board | Subject | Source |
| --- | --- | --- | --- |
| A-Level | AQA | Biology (7402) | spec v1.5, pp. 9-10, 60 |
| A-Level | AQA | Chemistry (7405) | spec v1.1, pp. 10, 73 |
| A-Level | AQA | Physics (7408) | spec v1.3, pp. 9, 71 |

Every figure was read off the official specification PDF, not recalled. Each
record carries its `source` URL, `specVersion`, `retrievedAt`, and the exact
pages checked.

**Three, not the fifteen asked for.** The rate limit is verification, not
machinery: adding a subject is now "fetch the spec, read the assessment pages,
write ~40 lines of JSON, regenerate". The scaffolding, validation, both
emitters, the server grounding and the tests are done and are the part that does
not have to be repeated.

### The second break, found on the way

`assessment_type_id` was never sent by the client, so `loadRubric()` always
received `nil`. Even a perfect corpus would have been unreachable. Now threaded
through `NewAssignment` → `PlanCoordinator` → `PlanService`.

And A-level components have no per-criterion marks, so `loadRubric` — which
required `criteria.length > 0` — returned null for every one of them. Assessment
objectives (migration 0026) are what make an exam paper groundable at all.

### Proof

A real breakdown against AQA Biology Paper 3 returned `rubric_grounded: true`,
`rubric_source: "curriculum"`, on the stronger model, with steps shaped by the
paper's actual structure — "drill the 25-mark essay question", "practise data
and statistics questions" — which correspond to the real 25-mark essay and
15-mark critical-analysis sections. Every step carried a null criterion code
rather than inventing one, as the prompt instructs for criteria-less components.

### Still open

- **IB: nothing populated, deliberately.** ibo.org is behind bot-detection and
  the guides are paywalled. Fabricating criteria into a planner students trust
  is the one outcome worse than an empty corpus.
- **The component picker UI.** The id threads all the way through, but no screen
  sets it yet — so grounding is reachable by API and not yet by a tap. This is
  the next piece.
- **12 more A-level subjects**, at roughly 15 minutes each now the machinery
  exists.
