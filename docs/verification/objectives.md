Biology, Chemistry and Physics now carry AO1–AO4, paraphrased in Albus's own second-person register. Each was checked against two separately hosted IB publications of the first-assessment-2025 vintage. URLs and confidence are in each subject JSON. Biology and Chemistry agree across two school-hosted briefs; Physics agrees between its brief and Bradfield College's guide, printed page 22. These are corroborated sources rather than a claim to have read the objectives on ibo.org.

Per-AO weights remain null: the briefs publish component weights. The Physics guide's combined AO1+AO2 percentages are not individual objective ranges and were not copied into those fields. AO4 is a subject-wide investigation objective, not a claim about every external paper.

The remaining twelve missing IB objective sets are left empty with notes naming the unconfirmed guide vintage and scope. Geography's existing objectives are preserved. No Business criteria were researched or changed. Generated Swift and SQL come only from gen.py.

Actual generator, Deno and weighting-guard outputs are stored beside this report. The existing min <= max generator guard was deliberately violated in memory, observed failing, and discarded. The new pgTAP test checks the seeded rows and deliberately attempts a reversed-range insert against the existing check constraint, expecting SQLSTATE 23514 and no persisted fixture. The existing database workflow now applies the current seed before these tests; CI must run that negative probe before it is claimed verified.

The required local reset failed after host disk exhaustion while pulling an image, leaving Docker reporting a read-only filesystem; its normal restart timed out. This is not a green database result. Seed application, pgTAP and security concurrency races remain pending. Xcode 16.4 / Swift 6.1 compatibility must be established in CI.

Local Xcode 26.x output:
```
** TEST BUILD SUCCEEDED **
```
