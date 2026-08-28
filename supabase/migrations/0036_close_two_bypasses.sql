-- 0036 — two ways past a paid limit, both found by attacking the live database
-- rather than by reading the code.
--
-- Applied by hand and verified. The CI deploy workflow has no secrets and never
-- runs, so this repo is not the source of truth for this database.
--
-- ── 1. The RPC was a suggestion ─────────────────────────────────────────────
--
-- `create_assignment_with_plan` checks the active-task limit and then inserts,
-- in one transaction, which is the right shape. But `authenticated` holds
-- INSERT on `public.assignments` — it has to, RLS is what scopes it — so a
-- client that simply does not call the RPC is not checked at all:
--
--     POST /rest/v1/assignments  {"title":"…","task_type":"essay", …}
--
-- Verified against the live database: a Free account already holding its five
-- went to six that way, first attempt, no error. The cap has been bypassable
-- since 0008; it was never noticed because the only client we ship happens to
-- call the RPC.
--
-- The fix is the shape the rubric limit already had: a trigger, so the limit
-- holds on every write path — the RPC, a raw PostgREST insert, an import we
-- have not written yet — rather than only the one the app uses today. A limit
-- that lives in one caller is a convention, not a limit.
--
-- ── 2. Reserve-then-spend was racing ────────────────────────────────────────
--
-- 0010 claimed: "Two concurrent requests cannot both read '9 of 10 used' and
-- both proceed." That is not true under READ COMMITTED, which is what this
-- database runs. The count and the insert are in one transaction, but nothing
-- stops a second transaction reading the same snapshot before the first has
-- inserted. Both see nine, both insert, both proceed.
--
-- Verified: a Plus account with exactly one grading left this week, twelve
-- requests fired at once through PostgREST — **two** came back with a
-- reservation id and ten with ALLOWANCE_WEEKLY. One grading, two granted.
--
-- Note on how that was found. The same test run against the database through a
-- single pooled connection reported one winner and looked clean; the requests
-- were being serialised by the tooling, not by Postgres. A concurrency test
-- that cannot demonstrate concurrency proves nothing, and this one only became
-- real when it went through HTTP with twelve sockets.
--
-- The fix is a transaction-scoped advisory lock keyed on the user. Concurrent
-- requests from one account serialise; different accounts never contend. Each
-- transaction takes at most one such lock, in one place, so there is no lock
-- ordering to deadlock on. The key is derived from a namespaced string so the
-- three call sites below cannot collide in the shared advisory namespace.

-- ── The gate stops racing ───────────────────────────────────────────────────
create or replace function public.check_and_record_ai_usage(
  p_kind  text,
  p_model text
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid          uuid := (select auth.uid());
  v_tier         text;
  v_plan         public.plans%rowtype;
  v_allow_limit  integer;
  v_allow_window interval;
  v_used         integer;
  v_hour_limit   integer;
  v_day_limit    integer;
  v_model        text;
  v_global_cap   integer;
  v_global_used  integer;
  v_band         text;
  v_divisor      integer := 1;
  v_verify_on    boolean;
  v_anonymous    boolean;
  v_id           uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  if p_kind not in ('breakdown', 'chat', 'grade') then
    raise exception 'INVALID_KIND' using errcode = '22023';
  end if;

  -- Everything below reads a count and then writes a row that changes it. One
  -- account at a time, or the read is a guess. Released when the transaction
  -- ends, however it ends.
  perform pg_advisory_xact_lock(hashtextextended('albus:ai_usage:' || v_uid::text, 0));

  v_model := left(coalesce(p_model, 'unknown'), 64);
  if v_model !~ '^[A-Za-z0-9._-]+$' then
    v_model := 'unknown';
  end if;

  select c.int_value into v_global_cap
    from public.app_config c where c.key = 'global_ai_calls_per_hour';
  v_global_cap := coalesce(v_global_cap, 2000);

  select count(*) into v_global_used
    from public.ai_usage u
   where u.created_at > now() - interval '1 hour';

  if v_global_used >= v_global_cap then
    raise exception 'GLOBAL_CAPACITY_REACHED' using errcode = 'Q0004';
  end if;

  select r.band into v_band from public.account_risk(v_uid) r;
  v_band := coalesce(v_band, 'normal');

  if v_band = 'severe' then
    raise exception 'ABUSE_SUSPECTED' using errcode = 'Q0010';
  end if;

  if v_band = 'high' then
    select coalesce(c.int_value, 0) = 1 into v_verify_on
      from public.app_config c where c.key = 'risk_verification_available';
    select u.is_anonymous into v_anonymous from auth.users u where u.id = v_uid;
    if coalesce(v_verify_on, false) and coalesce(v_anonymous, false) then
      raise exception 'VERIFICATION_REQUIRED' using errcode = 'Q0009';
    end if;
  end if;

  v_divisor := case v_band when 'high' then 4 when 'elevated' then 2 else 1 end;

  v_tier := public.effective_tier(v_uid);
  select * into v_plan from public.plans p where p.tier = v_tier;
  if not found then
    raise exception 'PLAN_UNKNOWN' using errcode = 'Q0005';
  end if;

  if p_kind = 'chat' then
    v_allow_limit  := v_plan.chat_per_month;
    v_allow_window := interval '30 days';
  elsif p_kind = 'grade' then
    v_allow_limit  := v_plan.grade_per_week;
    v_allow_window := interval '7 days';
  else
    v_allow_limit := null;
  end if;

  if v_allow_limit = 0 then
    raise exception 'PLAN_UPGRADE_REQUIRED' using errcode = 'Q0007';
  elsif v_allow_limit is not null then
    v_used := public.ai_spend_count(v_uid, p_kind, v_allow_window);
    if v_used >= v_allow_limit then
      if p_kind = 'chat' then
        raise exception 'ALLOWANCE_MONTHLY' using errcode = 'Q0008';
      else
        raise exception 'ALLOWANCE_WEEKLY' using errcode = 'Q0006';
      end if;
    end if;
  end if;

  if p_kind = 'chat' then
    v_hour_limit := v_plan.chat_per_hour;
    v_day_limit  := v_plan.chat_per_day;
  elsif p_kind = 'grade' then
    v_hour_limit := v_plan.grade_per_hour;
    v_day_limit  := null;
  else
    v_hour_limit := v_plan.breakdown_per_hour;
    v_day_limit  := v_plan.breakdown_per_day;
  end if;

  if v_divisor > 1 then
    if v_hour_limit is not null and v_hour_limit > 0 then
      v_hour_limit := greatest(1, v_hour_limit / v_divisor);
    end if;
    if v_day_limit is not null and v_day_limit > 0 then
      v_day_limit := greatest(1, v_day_limit / v_divisor);
    end if;
  end if;

  if v_hour_limit is not null then
    if public.ai_spend_count(v_uid, p_kind, interval '1 hour') >= v_hour_limit then
      raise exception 'RATE_LIMIT_HOURLY' using errcode = 'Q0002';
    end if;
  end if;

  if v_day_limit is not null then
    if public.ai_spend_count(v_uid, p_kind, interval '1 day') >= v_day_limit then
      raise exception 'RATE_LIMIT_DAILY' using errcode = 'Q0003';
    end if;
  end if;

  insert into public.ai_usage (user_id, kind, model)
  values (v_uid, p_kind, v_model)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.check_and_record_ai_usage(text, text) from public, anon;
grant execute on function public.check_and_record_ai_usage(text, text) to authenticated;

-- ── The active-task limit becomes a limit ───────────────────────────────────
create or replace function public.assert_active_task_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit  integer;
  v_active integer;
begin
  -- Only a row that is active occupies a slot. Everything else is free.
  if new.status is distinct from 'active' then
    return new;
  end if;

  -- An update that leaves an already-active row active consumes nothing new.
  -- Without this, editing the title of an assignment on a full plan would fail.
  if tg_op = 'UPDATE' and old.status = 'active' then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('albus:assignments:' || new.user_id::text, 0));

  select p.active_tasks into v_limit
    from public.plans p where p.tier = public.effective_tier(new.user_id);
  if not found then
    raise exception 'PLAN_UNKNOWN' using errcode = 'Q0005';
  end if;

  -- NULL is unlimited.
  if v_limit is null then
    return new;
  end if;

  select count(*) into v_active
    from public.assignments a
   where a.user_id = new.user_id
     and a.status = 'active'
     and a.id is distinct from new.id;

  if v_active >= v_limit then
    raise exception 'PLAN_TASK_LIMIT_REACHED' using errcode = 'Q0001';
  end if;

  return new;
end;
$$;

revoke all on function public.assert_active_task_limit() from public, anon, authenticated;

drop trigger if exists assignments_active_limit on public.assignments;
create trigger assignments_active_limit
  before insert or update of status on public.assignments
  for each row execute function public.assert_active_task_limit();

-- ── The rubric limit stops racing too ───────────────────────────────────────
create or replace function public.assert_rubric_limits()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer;
  v_count integer;
begin
  if tg_table_name = 'rubrics' then
    perform pg_advisory_xact_lock(hashtextextended('albus:rubrics:' || new.user_id::text, 0));

    select count(*) into v_count from public.rubrics where user_id = new.user_id;

    -- Absolute ceiling first: it applies to every tier including Pro, because
    -- unlimited means "as many as a student needs", not "as many as a script
    -- can insert in an afternoon".
    if v_count >= 200 then
      raise exception 'RUBRIC_CEILING' using errcode = 'Q0012';
    end if;

    select p.rubrics into v_limit
      from public.plans p where p.tier = public.effective_tier(new.user_id);

    if v_limit is not null and v_count >= v_limit then
      raise exception 'RUBRIC_PLAN_LIMIT' using errcode = 'Q0011';
    end if;
  else
    if (select count(*) from public.rubric_items where rubric_id = new.rubric_id) >= 40 then
      raise exception 'rubric criterion limit reached' using errcode = 'check_violation';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.assert_rubric_limits() from public, anon, authenticated;

-- ── Steps, bounded on every path ────────────────────────────────────────────
--
-- The RPC refuses more than 20 steps in one plan. `authenticated` holds INSERT
-- on `subtasks`, so that bound was also only ever advice. Not a paid limit and
-- not worth an upgrade prompt — but an unbounded child table is a storage
-- attack, and the notification planner allocates against a plan's step count.
create or replace function public.assert_subtask_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select count(*) from public.subtasks s where s.assignment_id = new.assignment_id) >= 64 then
    raise exception 'TOO_MANY_SUBTASKS' using errcode = '22023';
  end if;
  return new;
end;
$$;

revoke all on function public.assert_subtask_limit() from public, anon, authenticated;

drop trigger if exists subtasks_limit on public.subtasks;
create trigger subtasks_limit
  before insert on public.subtasks
  for each row execute function public.assert_subtask_limit();
