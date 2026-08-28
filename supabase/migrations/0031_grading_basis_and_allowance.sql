-- 0031 — a grading remembers what it was based on, and the app can show how
-- many are left without spending one to find out.
--
-- **`basis` is the load-bearing column.** A blind reading and a rubric grading
-- that happened to award no marks are identical on the wire — both are nulls.
-- Without this, opening a saved grading from history could render a blind
-- reading as though it were marked against criteria, which is the one thing
-- this feature must never do. Stored, not inferred.
--
-- Defaulting to 'personal' is correct rather than convenient: every row that
-- could already exist was written when a rubric was mandatory. There are zero
-- of them today, which is the whole reason this feature is being rebuilt.

alter table public.gradings
  add column if not exists basis text not null default 'personal'
    check (basis in ('personal', 'curriculum', 'blind'));

alter table public.gradings
  add column if not exists improvements jsonb not null default '[]'::jsonb;

comment on column public.gradings.basis is
  'What the marks were based on. blind = no rubric, no marks, not a grade.';

-- ── How many gradings are left ───────────────────────────────────────────────
--
-- Read-only and advisory. The real gate is `check_and_record_ai_usage`, which
-- runs in the same transaction that reserves the slot; this exists so the meter
-- in the UI can be drawn without spending a grading to discover the number.
--
-- The limits are duplicated from that function deliberately rather than shared:
-- making the gate depend on a second function would put a bypass one bad
-- refactor away. If these drift, the meter is wrong and nothing is bypassed —
-- which is the correct direction for the two to fail in.
create or replace function public.grading_allowance()
returns table (used_week integer, limit_week integer, used_day integer, limit_day integer, is_plus boolean)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_tier    text;
  v_expires timestamptz;
  v_plus    boolean;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;

  select e.tier, e.expires_at into v_tier, v_expires
    from public.entitlements e where e.user_id = v_uid;

  v_plus := coalesce(v_tier = 'plus', false)
            and (v_expires is null or v_expires > now());

  return query
  select
    (select count(*)::integer from public.ai_usage u
      where u.user_id = v_uid and u.kind = 'grade'
        and u.created_at > now() - interval '7 days'),
    case when v_plus then 0 else 5 end,
    (select count(*)::integer from public.ai_usage u
      where u.user_id = v_uid and u.kind = 'grade'
        and u.created_at > now() - interval '1 day'),
    case when v_plus then 20 else 2 end,
    v_plus;
end;
$$;

revoke all on function public.grading_allowance() from public, anon;
grant execute on function public.grading_allowance() to authenticated;
