The local prerequisite query returned 20 course templates and zero syllabus topics. The only reference under functions, iOS, docs and scripts was docs/database.md:25. The authenticated read-all policy was present. The consumer was wired before adding topic data.

75 labels are sourced from five official public IB pages: Biology (4 organizing themes), Chemistry (8 concepts/headings), Computer science (10 headings from the explicitly dated 2027 update), History (24 option/group headings for the course ending in 2027), Physics (29 theme/topic labels, retaining HL-only restrictions). The other 14 records deliberately remain empty and explain the missing verification. Biology's empty topic nodes are not reconstructed. Business criteria remain untouched and empty. No migrations were edited or introduced.

The generator now deletes and replaces topics per template. The lookup embeds and orders them, and the prompt includes at most 40. A topics-only component retains grounding without inventing assessment objectives or marks. Tests exercise both embed shapes and the path from lookup to prompt.

Actual outputs: syllabus-generator.txt, syllabus-guards.txt, syllabus-deno.txt and syllabus-deno-check.txt. All nine bad in-memory fixtures were rejected and then discarded; the valid fixture passed. CI now runs the generator guards and verifies generated files match the corpus.

Local Xcode output:

```
xcodebuild build-for-testing -project ios/Albus.xcodeproj -scheme Albus -destination id=7962BB5F-E237-4225-9736-C4284C987221
** TEST BUILD SUCCEEDED **
```

This is Xcode 26.x, not evidence for CI's older Swift concurrency checks.

Database verification is blocked, not passed. The required `supabase db reset --local --no-seed --yes` exhausted host disk space during image extraction; Docker reported `read-only file system`. Its normal restart subsequently timed out. The pgTAP assertions for duplicate ordinals and one-topic outlines have been written but must still be run against the seed and deliberately violated in a rollback-only transaction. No claim is made that those two guards have been watched fail yet. Seed application and the four concurrency races also remain pending Docker recovery.
