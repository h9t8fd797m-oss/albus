## What this changes

<!-- One or two sentences. -->

## Security checklist

- [ ] Any new table has RLS enabled **and** an owner-only restrictive policy
- [ ] Every new policy names its role (`to authenticated`), never bare
- [ ] `auth.uid()` is wrapped as `(select auth.uid())` in policy predicates
- [ ] New user-owned tables have an index on `user_id`
- [ ] No secret, key or token added to a tracked file
- [ ] `completion_logs` still carries no free text
- [ ] Migrations are append-only — no edits to already-applied files

## Verified by

<!-- How you checked. `scripts/verify-rls.sql`, a simulator run, etc. -->
