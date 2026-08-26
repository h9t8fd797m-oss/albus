-- 0030 — grading stops being Plus-only, and gains a weekly ceiling.
--
-- Applied by hand and verified against pg_proc on 26 Aug 2026: the CI deploy
-- workflow has no secrets and never runs, so the repo is not the source of
-- truth for this database. See docs/plan-2026-08-25.md.
--
-- Why this changes at all: grading was gated `PLUS_REQUIRED` in the same
-- transaction that reserves the usage slot, which is the correct place for a
-- paywall. But there are zero Plus users and no way to become one until
-- RevenueCat exists, so the endpoint had never been reached once — 0 rows in
-- `gradings`, 0 rows in `ai_usage` for kind='grade'. A flagship feature nobody
-- can run is not a paywall, it is an outage.
--
-- So: free students get a small real allowance, and Plus raises the ceiling.
-- The paywall stays exactly where it was — in Postgres, in the same
-- transaction — it just stops being all-or-nothing.
--
-- The limits are deliberately tight, because grading now runs on Opus and is by
-- some distance the most expensive call the app makes. Two a day is enough to
-- mark a draft and then mark the revision, which is the actual use case. Five a
-- week stops "two a day, every day" adding up to a bill.
--
-- A weekly window is new: an hourly and a daily cap together still permit 14
-- gradings a week, which is not what "tight" meant.

create or replace function public.check_and_record_ai_usage(
  p_kind  text,
  p_model text
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid          uuid := (select auth.uid());
  v_tier         text;
  v_expires      timestamptz;
  v_is_plus      boolean;
  v_hour_limit   integer;
  v_day_limit    integer;
  v_week_limit   integer;
  v_hour         integer;
  v_day          integer;
  v_week         integer;
  v_model        text;
  v_global_cap   integer;
  v_global_used  integer;
  v_id           uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  if p_kind not in ('breakdown', 'chat', 'grade') then
    raise exception 'INVALID_KIND' using errcode = '22023';
  end if;

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

  select e.tier, e.expires_at into v_tier, v_expires
    from public.entitlements e where e.user_id = v_uid;

  v_is_plus := coalesce(v_tier = 'plus', false)
               and (v_expires is null or v_expires > now());

  if p_kind = 'chat' then
    v_hour_limit := case when v_is_plus then 120 else 20  end;
    v_day_limit  := case when v_is_plus then 600 else 60  end;
  elsif p_kind = 'grade' then
    -- Deliberately tight. Grading a full essay on Opus is the most expensive
    -- call the app makes, and re-marking the same piece thirty times in an hour
    -- is not a use case — it is a bill.
    v_hour_limit := case when v_is_plus then  6 else 2 end;
    v_day_limit  := case when v_is_plus then 20 else 2 end;
    v_week_limit := case when v_is_plus then  0 else 5 end;  -- 0 = no weekly cap
  else
    v_hour_limit := case when v_is_plus then  30 else  8  end;
    v_day_limit  := case when v_is_plus then 150 else 25  end;
  end if;

  select count(*) into v_hour from public.ai_usage u
   where u.user_id = v_uid and u.kind = p_kind
     and u.created_at > now() - interval '1 hour';
  if v_hour >= v_hour_limit then
    raise exception 'RATE_LIMIT_HOURLY' using errcode = 'Q0002';
  end if;

  select count(*) into v_day from public.ai_usage u
   where u.user_id = v_uid and u.kind = p_kind
     and u.created_at > now() - interval '1 day';
  if v_day >= v_day_limit then
    raise exception 'RATE_LIMIT_DAILY' using errcode = 'Q0003';
  end if;

  if coalesce(v_week_limit, 0) > 0 then
    select count(*) into v_week from public.ai_usage u
     where u.user_id = v_uid and u.kind = p_kind
       and u.created_at > now() - interval '7 days';
    if v_week >= v_week_limit then
      -- Its own code, so the client can say "you have used this week's
      -- markings" rather than a daily message that is simply untrue.
      raise exception 'RATE_LIMIT_WEEKLY' using errcode = 'Q0006';
    end if;
  end if;

  insert into public.ai_usage (user_id, kind, model)
  values (v_uid, p_kind, v_model)
  returning id into v_id;

  return v_id;
end;
$$;
