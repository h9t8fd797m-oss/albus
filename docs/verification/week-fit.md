Week fit uses the existing solver result across all assignments. The notice covers deadlines within seven calendar days (including overdue work), hides when no steps are unplaced, and suppresses stale results after a failed reflow. A full-but-placeable day can still be `cooked`, so mood alone never triggers it.

“Review affected work” filters Home to the affected assignments; their existing detail screens offer step editing. The minute count is the duration of unplaced steps, not a claim about the exact extra capacity needed: a long sitting may fail because available time is fragmented.

Pure tests cover competition across six assignments, quiet states, overdue and future scope, assignment deduplication and the daylight-saving boundary. Actual output is in week-fit-core.txt (114 tests, including the 300-seed fuzz sweep). Edge functions are unchanged; their 151 tests and all three endpoint checks pass.

Database verification is pending recovery of local Docker after the required reset exhausted host disk space and made its storage filesystem read-only. No database changes belong to this client-only branch. Xcode 16.4 / Swift 6.1 verification still requires CI; a local 26.x build is not evidence of that compatibility.

Local client build output:
```
xcodebuild build-for-testing -project ios/Albus.xcodeproj -scheme Albus -destination id=7962BB5F-E237-4225-9736-C4284C987221
** TEST BUILD SUCCEEDED **
```
