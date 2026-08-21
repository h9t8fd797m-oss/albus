# Albus

iOS study planner for IB, AP and university students. An on-device adaptive
scheduler, a rubric-grounded breakdown engine, and an authored curriculum
corpus.

Designs, business plan and build plan live in `~/Desktop/Albus AI/`.
This repo is code and infrastructure only.

---

## Layout

```
ios/
  AlbusCore/        Swift package — scheduler, estimator, design tokens
  App/Albus/        The app target (SwiftUI, SwiftData)
  App/AlbusTests/   Data-layer tests
  project.yml       Xcode project definition (the .xcodeproj is generated)

supabase/
  migrations/       Append-only SQL. The schema and every security rule.
  functions/        Edge Functions — breakdown, chat, receipt, webhook
  config.toml       Auth and session configuration

docs/               architecture, database, security model, backend
scripts/            verify-rls.sql, setup-github.sh
.github/workflows/  CI and migration deploy
```

## Status

| | State |
|---|---|
| Database, RLS, security rules | **done** — 14 tables, verified |
| Accounts (anonymous-first) | **done** |
| `POST /breakdown` — study plans | **done**, deployed |
| `POST /chat` — Ask Albus | **done**, deployed |
| Rate limiting | **done** — hourly and daily, race-proof |
| Scheduler | **done** — 25 tests + 300 fuzz scenarios |
| Estimator | **done** — 10 tests |
| Design tokens, app shell | **done** — runs in the simulator |
| **Screens** | **not started** — tabs show placeholders |
| Payments | deferred to RevenueCat |
| Curriculum corpus | 1 course of ~18 |

## Getting set up

```bash
cp .env.example .env      # then fill in from the Supabase dashboard
```

`.env` is gitignored. **No real credential belongs in a tracked file** — CI
fails any pull request that adds one.

### Running the app

```bash
brew install xcodegen         # once
cd ios && xcodegen generate
open Albus.xcodeproj          # then hit Run
```

Signing is deliberately unset, so it runs in the simulator as is. See
`ios/README.md` for the two-line change to run on a device.

### Running the tests

```bash
cd ios/AlbusCore && swift test        # 37 — scheduler, estimator, fuzz
cd ios && xcodebuild test -project Albus.xcodeproj -scheme Albus \
  -destination 'platform=iOS Simulator,name=iPhone 16'   # 7 — data layer
```

## Branching

`main` is protected. **Run `./scripts/install-hooks.sh` in every clone** —
`core.hooksPath` is not committed, so a fresh clone starts unprotected.

Every change goes through a pull request:

```bash
git checkout -b feat/what-it-does
git push -u origin feat/what-it-does
gh pr create --fill
```

Merging to `main` deploys migrations, which is the one class of mistake that is
genuinely hard to undo. A local `pre-push` hook blocks direct pushes as a
backstop. See `CONTRIBUTING.md`.

## Where the security actually lives

Not in application code — in the database. Row Level Security decides what
every query can see, so a bug in a function cannot leak another student's work.
Each user-owned table carries four owner-scoped policies plus a restrictive
owner-only policy that ANDs with everything, including any policy added later.

Three things worth knowing before changing anything:

- **The Anthropic key never reaches the client.** That is the entire reason the
  Edge Functions exist. An app on someone's phone can be taken apart.
- **Entitlements are written by exactly one function**, revoked from every
  client role. No code path lets a client grant itself Plus.
- **`completion_logs` has no field that could hold a title or note.** The
  privacy guarantee is structural, not a convention.

Read `docs/security-model.md` before touching the schema, and run
`scripts/verify-rls.sql` after — every row must return `pass = true`.

## Before launch

- [ ] CAPTCHA on anonymous sign-ins (`supabase/config.toml`)
- [ ] Sign in with Apple, once the Developer account is configured
- [ ] Schedule `reap_abandoned_anonymous_users` via pg_cron
- [ ] MFA on the Supabase account
- [ ] Reconcile migration history so `supabase db push` works in CI
