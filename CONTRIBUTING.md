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

This is not ceremony. Merging to `main` deploys migrations to the live
database, and a bad migration is the one class of mistake that is genuinely
hard to undo.

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

1. New table? It needs `enable row level security`, four permissive policies
   scoped to the owner, and one restrictive owner-only policy.
2. New user-owned table? It needs an index on `user_id` — RLS filters on it
   for every single query.
3. Run `scripts/verify-rls.sql`. Every row must show `pass = true`.

## Applying migrations by hand

Don't, except on a throwaway branch database. The path to production is a
merged PR. If you need to apply something urgently, apply it via a PR with
`workflow_dispatch` rather than reaching into the dashboard — otherwise the
repo and the database drift, and the repo stops being the source of truth.
