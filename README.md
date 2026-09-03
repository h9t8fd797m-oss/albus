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
  functions/        Edge Functions — breakdown, assignment chat, grader, RevenueCat
  config.toml       Auth and session configuration

docs/               architecture, database, security model, backend
scripts/            local CI, adversarial concurrency tests, data generators
.github/workflows/  CI and migration deploy
```

## Status

| | State |
|---|---|
| Database, RLS, financial controls | **built** — local adversarial suite; live deployment pending |
| Accounts (anonymous-first) | **done** |
| `POST /breakdown` — study plans | **done**, deployed |
| `POST /chat` — Ask Albus | **done**, deployed |
| Rate/cost limiting | **built** — request, attempt, allowance, per-account and global USD fuses |
| Scheduler, estimator, notifications | **built** and unit-tested |
| Albus Grader | **built** — rubric-backed history and blind-reading fallback |
| Ask Albus | **built** — Pro-only inside an assignment |
| Payments | server path fails closed; RevenueCat SDK/products still pending |

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
scripts/ci-local.sh --full

# After a database/security change, with local Supabase running:
supabase test db --local
scripts/security-concurrency-local.sh
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

Merging to `main` is the only sanctioned route to production, and migrations are
the one class of mistake that is genuinely hard to undo. A local `pre-push` hook
blocks direct pushes as a backstop. See `CONTRIBUTING.md`.

**Merging does not currently apply anything, though.** The `Deploy migrations`
workflow has failed on every run since it was added, because the three
repository secrets it needs have never been set. Migrations are applied by hand,
which means production matches this repo only because somebody checked — see
`CONTRIBUTING.md` § "Applying migrations by hand" for what that has already
cost.

## Where the security actually lives

Not in application state — in the server. Row Level Security decides what every
query can see, raw write grants are narrower than the RLS policies, and AI
entitlement/rate/cost reservations are service-only database operations.

Three things worth knowing before changing anything:

- **The Anthropic key never reaches the client.** That is the entire reason the
  Edge Functions exist. An app on someone's phone can be taken apart.
- **Entitlements are written by exactly one function**, revoked from every
  client role. No code path lets a client grant itself Plus or Pro.
- **`completion_logs` has no field that could hold a title or note.** The
  privacy guarantee is structural, not a convention.

Read `docs/security-model.md` before touching the schema, then run the pgTAP and
multi-connection attack suites documented there.

## Before launch

- [ ] Configure Turnstile keys and enable CAPTCHA on client and server together.
- [ ] Sign in with Apple, once the Developer account is configured
- [x] ~~Schedule `reap_abandoned_anonymous_users`~~ — running daily at 04:17
- [x] Schedule privacy/security-data retention — running daily at 04:43
- [ ] Rotate the Anthropic key and configure the signal pepper
- [ ] Configure RevenueCat SDK, products, webhook secrets, app-id allowlist and product allowlist
- [ ] MFA on the Supabase account (only you can do this)
- [ ] Deploy this branch, remove old Apple functions, and run live adversarial checks
