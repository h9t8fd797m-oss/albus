# Albus

iOS study planner. An on-device adaptive scheduler, a rubric-grounded breakdown
engine, and an authored curriculum corpus.

Design source, business plan and build plan live in `~/Desktop/Albus AI/`.
This repo is code and infrastructure only.

---

## Layout

```
.github/workflows/   CI guards + migration deploy
docs/                architecture and security model
ios/                 Xcode project (added in build-plan P0)
scripts/             verify-rls.sql — run after every schema change
supabase/
  config.toml        auth, session and API configuration
  migrations/        append-only SQL, one concern per file
  functions/         Edge Functions (breakdown, chat, receipt)
  seed.sql           minimal curriculum scaffolding
```

## Getting set up

```bash
cp .env.example .env      # then fill in from the Supabase dashboard
```

`.env` is gitignored. Nothing in it should ever appear in a tracked file.

## Branching — main is protected

`main` is never committed to directly. Every change goes:

```
git checkout -b feat/what-it-does
# work, commit
git push -u origin feat/what-it-does
gh pr create --fill
# review, CI green, then merge
```

Merging to `main` triggers `deploy-migrations.yml`, which is the only path by
which schema changes reach the database. See `CONTRIBUTING.md`.

## Security

Read `docs/security-model.md` before touching the schema. The short version:
every table has RLS, every user-owned table carries a restrictive owner-only
policy, and `completion_logs` never stores free text.

After any schema change, run `scripts/verify-rls.sql` and confirm every check
returns `pass = true`.
