# Deployment review and local rehearsal

The deployment file is one transaction, including its dated migration-history
snapshot. Its embedded cached-token migration remains byte-identical to the
merged migration. The other two changes retain their migration DDL. No merged
migration was edited.

The review found that the original verification accepted a correct version with
the wrong migration name, recorded student context without checking its schema,
checked only one IB task label, and checked only the cache-write column. The
deployment file now refuses these incomplete states. This is verification of the
specific repaired entries, not certification of every historical migration.

Rerunning the file preserves logical schema and data. It still re-executes DDL
and acquires locks; it is not a literal no-op.

## Observed local results

[`2026-09-08/deploy-guards.txt`](2026-09-08/deploy-guards.txt) contains the actual
output of `python3 scripts/prove_deploy_local.py`. The rehearsal reconstructs the
documented pending schema and eleven wrongly stamped rows, then verifies that
the transaction repairs them and retains the original stamp in the backup.
A second run produces an identical logical database dump.

Six deliberately violating fixtures were rejected: missing student-context RPC,
wrong migration name, surviving wrong stamp, each cache column with a wrong
type, and an embedded task constraint missing `final_exam`. Each refusal left
the complete application/history dump identical to its pre-call state. The
temporary task-constraint mutation never changes the checked-in deployment file.
Every fixture was removed afterward.

The helper exclusively addresses `albus_deploy_rehearsal` inside the local
`supabase_db_ssvehwhblgqtvqkfbkbj` Docker container. Prepare it by restoring the
local `public`, `private`, `auth` and `supabase_migrations` schemas into that
disposable database. Exclude pg_cron, which is restricted to its configured
database. Never point this proof at production: it deliberately reconstructs
invalid states.

## Release gate

This document records local evidence, not a production deployment. Production
execution still depends on completed, green Parts 1–3 and their final CI results.
The read-only production history inspection confirmed the documented wrong
stamps and absence of the three pending versions.

After deployment, account-owned disposable test rows must return to baseline.
The new anonymised `ai_usage` cost row must remain: deleting it to force every
table count back to baseline would contradict the cost-history migration.
