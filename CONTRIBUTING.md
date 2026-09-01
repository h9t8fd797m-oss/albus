# Working on Albus

## First, install the hooks

```bash
./scripts/install-hooks.sh
```

**Do this in every clone.** `core.hooksPath` is local repository config — it is
not committed and does not survive `git clone`, so a fresh clone has no
protection against pushing straight to `main`. The script is idempotent.

A server-side workflow (`main guard`) also fails any commit that reaches `main`
without a pull request. It cannot prevent the push — nothing on this plan can —
but it makes one loud instead of silent.

## The one rule

**`main` is protected.** No direct commits, no direct pushes, no force-pushes.
Every change reaches `main` through a reviewed pull request.

This is not ceremony. Merging to `main` is what deploys migrations to the live
database, and a bad migration is the one class of mistake that is genuinely
hard to undo.

**Deploys need three repository secrets** — `SUPABASE_ACCESS_TOKEN`,
`SUPABASE_PROJECT_REF` and `SUPABASE_DB_PASSWORD`, under Settings → Secrets and
variables → Actions. Until they are set, the `Deploy migrations` workflow stops
immediately and says which are missing, and migrations have to be applied by
hand. It used to die further in with an opaque CLI error instead, which is how
it went unnoticed that it had never once run.

## Branch names

| Prefix      | For                                  |
|-------------|--------------------------------------|
| `feat/`     | new functionality                    |
| `fix/`      | bug fixes                            |
| `db/`       | migrations and schema work           |
| `chore/`    | tooling, CI, dependencies            |
| `docs/`     | documentation only                   |

## The loop

```bash
git checkout main && git pull
git checkout -b db/add-streaks-table

# ... work ...

git add -A
git commit -m "Add streaks table with owner-only RLS"
git push -u origin db/add-streaks-table
gh pr create --fill
```

Then: CI green → self-review the diff → merge → delete the branch.

## Migrations are append-only

Once a migration has been applied to the live database it is **history**.
Never edit it, never delete it, never renumber it. Fix forward with a new file.
CI enforces this on every PR.

Naming: `NNNN_short_description.sql`, four digits, zero-padded.

## Before you open a PR

The PR template carries the full checklist. The three that matter most:

1. New public table? It needs `enable row level security`, the minimum grants
   the app actually uses, and allow-and-deny policy tests for every granted
   operation. Server-owned ledgers should have no client table grants at all.
2. New user-owned table? It needs an index on `user_id` — RLS filters on it
   for every single query.
3. Run `supabase test db --local` and
   `scripts/security-concurrency-local.sh`. Both must pass.

## Applying migrations by hand

Don't, except on a throwaway branch database. The path to production is a
merged PR. If you need to apply something urgently, apply it via a PR with
`workflow_dispatch` rather than reaching into the dashboard — otherwise the
repo and the database drift, and the repo stops being the source of truth.

That drift is not hypothetical: two migrations were applied by hand and never
written to a file, so the repo could not rebuild the database it described.
They were recovered from `supabase_migrations.schema_migrations` and are now
`0016` and `0017`. If you ever have to apply something directly, write the file
in the same change — a migration that exists only in the database is a migration
nobody can review, roll forward, or reproduce.
