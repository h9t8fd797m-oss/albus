# Content verification — 9 September 2026

The matching publications support assessment objectives for all 16 IB records and syllabus outlines for 15. These are subject-wide objectives and factual topic headings, not a promise that every examination assesses every objective or every optional topic. The existing server consumer remains bounded to 40 topic rows.

IB subject | Objectives | Topics
--- | ---: | ---:
Biology | 4 | 4
Business management | 4 | 43
Chemistry | 4 | 8
Computer science | 4 | 10
Economics | 4 | 4
Environmental systems and societies | 4 | 14
Extended essay | 4 | 0
Geography | 4 | 16
History | 4 | 24
Language A: language and literature | 3 | 3
Language A: literature | 3 | 3
Language B | 5 | 5
Mathematics: analysis and approaches | 6 | 5
Mathematics: applications and interpretation | 6 | 5
Physics | 4 | 29
Theory of knowledge | 7 | 13

There are 70 IB objective rows and 186 IB topic rows. Previously there were 16 objective rows across four IB subjects and 75 topic rows across five. Three A-level records remain unchanged.

## Source decisions

Each populated field names its sources, retrieval date, matching first-assessment vintage and relevant pages in the subject JSON. All newly populated fields are corroborated by two independently hosted school publications; no new field claims to have been read directly on ibo.org.

- Mathematics AA/AI: matching 2021 briefs agree on five topic headings and six shared objectives. The Cygnus-hosted 2021 AA guide confirms numbering 1–6 on printed page 23. Its page 24 ranges differ by assessment paper and cannot become whole-subject percentages.
- Economics: Didzdvaris SL/HL briefs and the Nord Anglia collection agree on the 2022 guide. Four shared unit headings avoid claiming that the SL course includes all HL subtopics. Objective paraphrases preserve HL extension and policy-recommendation scope.
- ESS: AISC's 2026 brief and the Living Academy collection agree on eight topics, three Foundation subheadings, three HL-only lenses and four objectives. The old absence note's reference to seven topics was wrong. Research activities are not extra syllabus topics.
- Geography: the 2019 standalone Nord Anglia brief and Living Academy collection agree on the syllabus and four existing objective headings. The older brief contains an unrelated film bullet under AO1; the other does not. Full objective descriptors were therefore not expanded, and this discrepancy is recorded in the subject notes. The matching headings remain usable. Optional themes and HL-only content retain their restrictions.
- Language A literature and language/literature: independently hosted 2021 briefs agree on three areas of exploration and three objectives. The bullet expressly limited to literature and performance is excluded. School reading choices are unknown.
- Language B: two 2020 briefs agree on five themes and five objectives, with numbering independently checked in the matching guide. Both assessment tables explicitly give HL external 75% and oral 25%; the previous 80/20 values were incorrect and are corrected. This is the only numerical component-data change.
- Computer science: the official 2027 brief hosted by Mickiewicz Katowice and Heidelberg's 2026–28 handbook agree on four objectives. The handbook's inconsistent adjacent timing table is not used. The superseded 2026 course supplies no new data.
- History: two independently hosted 2017 briefs agree on four objectives. Their projected last-assessment-2025 date is recorded as stale in light of this record's established extension through 2027; no 2028 objectives are substituted.
- Extended essay criteria provenance: the existing reference to a 2018 guide was wrong for the 2027 rubric. Two independently hosted copies of the 2027 IB guide (CHMS and Harlem Village Academies, URLs in the JSON) confirm the five names and maxima 6/6/6/8/4 on printed pages 112–114 (PDF pages 118–120). All marks are retained; confidence is honestly corroborated and the source is corrected. SHA-256: CHMS `15719b17d6ff170c5c3af17323c9d8b1967a8a6dfb49ad998e0840e4052625c0`; Harlem `ed31f61f8fb9817fd87c34660a38eb93c3fe9e087b6cc4c290fb221223733f01`.
- TOK and extended essay: matching 2022 and 2027 publications respectively agree on seven and four objective groups. Their unnumbered lists use visibly local `Albus 1` identifiers, preserving source order without claiming official IB AO codes.
- Business: matching 2024 SL and HL briefs in the Podar and ISD school collections agree on objectives and topic labels. Only these fields and their absence notes changed. Components and deliberately empty criteria compare exactly equal to main; no criterion research or modification was performed.

All new objective guidance is Albus's second-person paraphrase. No published per-AO percentage was found that applies to an entire subject at both levels, so all IB objective weightings remain null.

## Deliberately incomplete

Extended essay has no prescribed topic list in the matching sources: students select a research topic. Its topic array remains empty with unverified confidence and an explicit note. Biology and Chemistry retain their previously sourced high-level outlines; individual subtopics and level scope not established by those sources are not invented. Geography and History school option choices and language reading choices remain unknown. Business criteria remain permanently empty; the source disagreement notes and all component data are preserved.

## Observed verification

- `gen.py --check`: `✓ 19 subjects valid`.
- Both generated artifacts were regenerated; a second run was byte-identical.
- `check_guards.py`: `All 20 violating fixtures rejected; clean fixture accepted. No fixture persisted.` Each expected failure is captured in [content-guards.txt](content-guards.txt).
- Seed applied to **local** Postgres using `psql -v ON_ERROR_STOP=1 -q`.
- Full pgTAP: `Files=3, Tests=115` and `Result: PASS`; see [content-db.txt](content-db.txt).
- Swift: `Test run with 114 tests in 24 suites passed after 1.331 seconds.` See [content-core.txt](content-core.txt).
- Xcode build-for-testing: `** TEST BUILD SUCCEEDED **`; see [content-xcode.txt](content-xcode.txt).
- Security concurrency: `grading 1/12, task 1/12, rubric 1/12, rubric-owner 1/12`; see [content-races.txt](content-races.txt).
- Deno: `ok | 153 passed | 0 failed (1s)`; see [content-deno.txt](content-deno.txt). Breakdown/chat/grade type checks exited zero; see [content-deno-check.txt](content-deno-check.txt).

The new database assertions were deliberately made red in rollback-only copies of the test: a blank objective name failed assertion 5 (have 1, want 0), a single weighting bound failed assertion 6 (have 1, want 0), and deleting Mathematics AA AO6 failed assertion 7 (have 1, want 2). Each produced `Result: FAIL`; the unchanged test then produced `Result: PASS`. See [content-db-guards.txt](content-db-guards.txt). The inserted/changed rows did not persist. Existing topic guards were also reproved; see [content-topics-db-guards.txt](content-topics-db-guards.txt).

The local database mutation used to prove each assertion was respectively:

```sql
update public.assessment_objectives set name = ' '
where id = (select id from public.assessment_objectives limit 1);

update public.assessment_objectives set weighting_min = 20, weighting_max = null
where id = (select id from public.assessment_objectives limit 1);

delete from public.assessment_objectives where code = 'AO6'
and course_template_id = (select id from public.course_templates
                         where code = 'IB_DP_MATHS_AA');
```

Each statement was injected after `begin` and before the test plan in a temporary copy of `curriculum_objectives_test.sql`, which ends in `rollback`. It was run with `supabase test db <temporary-file> --local`, followed by the unmodified test. No production database was accessed for these checks.
