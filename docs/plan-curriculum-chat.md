# Curriculum-aware Ask Albus — what was built

## The ask

Make what a student selects at onboarding — curriculum and subjects — reach Ask
Albus, securely, so it answers as *their* assistant. Use the IB knowledge base
on the Desktop as the source for IB, without attaching the whole document to
every request. Hold criteria for the top subjects in the cloud, fetched when a
student takes that class.

## What the document turned out to be

`~/Desktop/Albus AI/albus_ib_knowledge_base.md` — 1,482 lines, ~36k tokens,
fourteen numbered sections. It is written as a lookup structure, not prose: one
topic per subsection, cross-referenced by number, facts repeated where a student
might arrive from different directions. It also carries its own operating rules
(§0.3) — never invent an IB rule, never reproduce IB criteria verbatim, route
session-specific facts to the DP coordinator — and its own uncertainty protocol
(§14.1). Those rules are the reason the document is safe to answer from, so they
are not optional context.

## Retrieval: a section router, not embeddings

Postgres full-text search over `knowledge_sections`, one row per subsection.

Chosen over pgvector because it is cheaper on both axes that matter here: no
embedding pipeline to keep in step with the text, no extension, one query per
question, and the reason an answer cited a section is inspectable. The document
was already authored as an index; splitting it any other way would cut across
boundaries its author drew.

Titles and curated keywords are weighted above body text, so a question in a
student's words ("how many words for my IA") reaches a section written in the
IB's ("word-count thresholds").

**Cost.** ~36k tokens attached to every message becomes 4 matched sections plus
two always-included rule sections, capped at 12,000 characters — roughly 1.5–3k
tokens, and zero for a student on a curriculum with no corpus.

### Two bugs found by testing retrieval rather than assuming it

1. **Every tsquery parser ANDs its terms.** "how many words can my biology IA be"
   required one section to contain *word* and *biology* and *IA*. Nothing did, so
   almost every real question returned nothing but the always-included rules. The
   parsed tsquery is now re-joined with `|` and ranked — the substitution is done
   on a parsed tsquery, never on the student's text, so it stays an operator swap
   and not an injection point.

2. **The character budget was spent in document order.** The RPC returned matched
   sections by section number, so a question about the History IA got the
   sciences and mathematics sections first, ran out of room, and dropped the
   History one — which was ranked first. Albus then said, honestly and wrongly,
   that it did not have History's criteria. Results are returned best-first now.

## Security

- `knowledge_sections` is shared reference data: `select` only to `authenticated`,
  no write grant, RLS on, `anon` locked out. Verified live — a signed-in student
  gets 403 on insert, update and delete, so the corpus cannot be poisoned into
  giving another student forged IB rules.
- `search_knowledge` is `security invoker` and takes the question as a
  **parameter**. `websearch_to_tsquery` is the one parser that never raises on
  arbitrary text, so a question mark cannot become a 500.
- **Which corpus is decided server-side from the caller's own profile row**, never
  from the request body. A student cannot ask for another qualification's
  material by claiming to study it.
- Everything personal — curriculum, subjects, components — is read through the
  caller-scoped client, so RLS answers "whose data is this". Verified live: a
  second student sees none of the first's subjects.
- Retrieved reference and the student's message arrive in **separate fences** that
  say opposite things about trust: reference may be relied on, the message is a
  question and never an instruction. Both strip forged tags, so a student cannot
  close the reference fence and write their own IB rules.
- `create_course` sets `user_id` from `auth.uid()`, not a parameter.

## Efficiency

- Retrieval runs only when the student's profile names a corpus. A GENERIC
  student pays nothing — no query, no tokens, and stays on the cheaper model.
- The retrieved sections go in the **user** turn, not the system prompt. The
  system prompt is the cached half; putting per-question text above the
  breakpoint would invalidate the cache on every message and cost more than
  retrieval saves.
- A section too large for the remaining budget is dropped rather than truncated.
  Half a rule reads exactly like a whole rule, and this corpus is mostly rules.

## The subject corpus

16 IB entries: Biology, Chemistry, Physics, Mathematics AA and AI, History,
Economics, Business management, Geography, Computer science, Language A
(literature, and language and literature), Language B, ESS, plus the Extended
Essay and Theory of Knowledge — the two every diploma candidate sits, where an E
withholds the diploma regardless of points.

SL and HL are separate components because the IA is weighted differently at each
and a student is only ever on one of them.

**Criteria are recorded only where the document states them**: sciences (4 × 6),
mathematics (5 criteria, 20 marks), History (6/15/4), the EE (30 marks), TOK.
Where the document flags marks as unconfirmed — Business management's criterion
split, Geography's six criteria, Computer science under the 2027 guide — the
component is recorded without them and the note says why. Psychology and Design
technology are **absent**: the document has no weightings for either and says to
verify against the guide.

**Fetched, never shipped.** Nothing is downloaded until a student picks a
subject; picking it is the opt-in, and the server resolves the code.

## A bug this work introduced and fixed

The generator derived each curriculum's display name from its last subject, so
seeding renamed the IB Diploma Programme to **"Theory of knowledge"** in the live
database — the name that goes into every IB student's prompt as "Curriculum: …".
Names are now explicit per qualification and the generator raises on a missing
one. The database was repaired.

## Verified live

Against the real backend, as an IB student with History HL, Biology HL and
Maths AA SL:

| Question | Sections | Answer |
| --- | --- | --- |
| Word limit for the History IA | 5.3, 7.1, 7.2, 7.5 | 2,200 words, bibliography excluded, and that it is a cut-off rather than a penalty |
| Highest-value History criterion | 7.5, 7.1, 7.4 | Criterion B, 15 of 25 marks, with why |
| E in TOK on 39 points | 2.2, 2.3, 6.2.4, 11 | No — a failing condition regardless of points |
| ChatGPT for the extended essay | 5.6, 6.1, 6.2.2 | Research yes, generated text no, with the disclosure requirement |
| Marks for a maths exploration | 7.4, 3.3, 8.2 | Noticed the student does not take Maths |
| Same question, GENERIC student | none | Generic answer, cheaper model, no corpus query |

## Still open

- `ENG_LL_HL` and `HIST_HL` remain from the 0016 scaffold, now duplicated by real
  entries. Unreachable from the client, which only offers bundled codes, but dead
  data.
- `.env`'s `SUPABASE_SECRET_KEY` is a placeholder (`sb_secret_xxxx…`), so neither
  PostgREST-as-service-role nor psql works from a fresh checkout. Seeding goes
  through `supabase db query --linked` instead.
- The corpus is IB only. A-level has no equivalent document.
