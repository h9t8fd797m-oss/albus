-- 0015_harden_table_grants
--
-- Closes a privilege-escalation gap created by Supabase's default privileges.
--
-- Root cause: `alter default privileges` in the public schema grants the full
-- table privilege set — arwdDxtm, which includes TRUNCATE, REFERENCES, TRIGGER
-- and MAINTAIN — to `anon` and `authenticated` on every new table. Migrations
-- 0002–0005 ran `revoke all ... from anon, public` and then granted a specific
-- subset to `authenticated`. But `grant` is additive: it never removed the
-- privileges `authenticated` had already been handed by the default. So every
-- user table ended up with `authenticated` holding ALL privileges, not the
-- documented subset.
--
-- What that did and did not expose:
--   * RLS still gated every reachable write. INSERT/UPDATE/DELETE on the
--     read-only reference tables were denied by the permissive model (no write
--     policy = deny), and on user tables by the `owner_only` restrictive
--     policy. Verified live: cross-user writes affect zero rows.
--   * TRUNCATE is the exception. It is NOT subject to RLS. No client path
--     reaches it today — PostgREST exposes no TRUNCATE verb and `authenticated`
--     cannot log in directly — but a single future SECURITY DEFINER function or
--     a direct-SQL path would turn it into "any user wipes every user's data".
--     That is a loaded gun this migration unloads.
--   * completion_logs is documented append-only, yet `authenticated` held
--     UPDATE/DELETE and could rewrite its own calibration history.
--   * profiles was documented "no DELETE", yet DELETE was granted.
--
-- Fix, in two parts:
--   1. Reset each table to exactly the privileges its own migration intended.
--   2. Repair the default privileges so future tables never reintroduce this.

-- ── 1. existing tables: revoke everything, re-grant the intended subset ──────
do $$
declare
  r record;
begin
  for r in
    select unnest(array[
      -- table,           grants (matching the migration that created it)
      'profiles:select,insert,update',                    -- 0002 (no delete)
      'curricula:select',                                 -- 0003 (read-only)
      'course_templates:select',                          -- 0003
      'assessment_types:select',                          -- 0003
      'rubric_criteria:select',                           -- 0003
      'syllabus_topics:select',                           -- 0003
      'duration_priors:select',                           -- 0003
      'courses:select,insert,update,delete',              -- 0004
      'assignments:select,insert,update,delete',          -- 0004
      'subtasks:select,insert,update,delete',             -- 0004
      'plan_sessions:select,insert,update,delete',        -- 0004
      'completion_logs:select,insert',                    -- 0005 (append-only)
      'ai_usage:select',                                  -- 0006
      'entitlements:select'                               -- 0006
    ]) as spec
  loop
    declare
      v_table text := split_part(r.spec, ':', 1);
      v_grants text := split_part(r.spec, ':', 2);
    begin
      -- anon never needs any table access; the app runs as authenticated.
      execute format('revoke all on public.%I from anon, public', v_table);
      -- Reset authenticated to nothing, then grant only the intended subset.
      -- This strips the default-granted TRUNCATE/REFERENCES/TRIGGER/MAINTAIN.
      execute format('revoke all on public.%I from authenticated', v_table);
      execute format('grant %s on public.%I to authenticated', v_grants, v_table);
    end;
  end loop;
end $$;

-- app_config and subscription_transactions are already server-only (RLS on,
-- no grants). Strip any default-granted privileges from them too, defensively.
revoke all on public.app_config              from anon, authenticated, public;
revoke all on public.subscription_transactions from anon, authenticated, public;

-- ── 2. default privileges: stop the next table from repeating this ──────────
-- Our migrations run as `postgres`, so that is the grantor whose defaults apply
-- to tables we create. Remove anon entirely, and strip from authenticated the
-- privileges that RLS cannot gate. CRUD stays: it is RLS-gated and every new
-- table's migration grants its own subset explicitly anyway.
alter default privileges for role postgres in schema public
  revoke all on tables from anon;
alter default privileges for role postgres in schema public
  revoke truncate, references, trigger, maintain on tables from authenticated;
