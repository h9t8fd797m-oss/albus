-- 0024_hide_trigger_functions
--
-- `assert_rubric_owned()` and `assert_rubric_limits()` are trigger functions,
-- and 0018 created them without touching their privileges. Postgres grants
-- EXECUTE on new functions to PUBLIC by default, and PostgREST exposes anything
-- executable in the `public` schema — so both were reachable as
-- `/rest/v1/rpc/assert_rubric_owned`, unauthenticated, as SECURITY DEFINER.
--
-- Neither is exploitable today: called outside a trigger, `new` is unset and the
-- function errors before it does anything. But a SECURITY DEFINER function on
-- the public API that nobody meant to publish is a bad shape regardless, and the
-- next edit to either one would be made without that in mind.
--
-- Revoking EXECUTE does not affect the triggers. Postgres does not check EXECUTE
-- on a trigger function when firing a trigger — the privilege only gates direct
-- calls, which is exactly what we are closing.
--
-- `set_updated_at()` has the same shape and predates this work; fixed here too
-- rather than left as the one remaining example of the pattern.

do $$
declare f text;
begin
  foreach f in array array[
    'public.assert_rubric_owned()',
    'public.assert_rubric_limits()',
    'public.set_updated_at()'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;

-- Deliberately still callable by `authenticated`, because the edge functions
-- invoke them as the signed-in user and the quota accounting depends on running
-- in that identity:
--   * check_and_record_ai_usage  — reserves a slot and enforces the paywall
--   * record_ai_usage_tokens     — writes token counts after the response
--   * create_assignment_with_plan, upsert_rubric — the write paths themselves
--
-- Asserted so a future blanket revoke does not silently break planning.
do $$
begin
  if not has_function_privilege('authenticated',
       'public.check_and_record_ai_usage(text, text)', 'EXECUTE') then
    raise exception 'authenticated must keep EXECUTE on check_and_record_ai_usage';
  end if;

  if has_function_privilege('anon', 'public.assert_rubric_owned()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.assert_rubric_owned()', 'EXECUTE') then
    raise exception 'assert_rubric_owned is still callable directly';
  end if;

  if has_function_privilege('anon', 'public.assert_rubric_limits()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.assert_rubric_limits()', 'EXECUTE') then
    raise exception 'assert_rubric_limits is still callable directly';
  end if;
end $$;
