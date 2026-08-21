-- 0013_cost_circuit_breaker
--
-- Closes the one security gap left open: account farming.
--
-- Per-user limits bound what one account can spend, but nothing bounded what
-- ONE THOUSAND accounts could spend. Anonymous sign-up is the product's whole
-- onboarding, so it cannot be removed, and CAPTCHA cannot be enabled until the
-- client can present a challenge. Lowering the per-IP sign-up limit raises the
-- cost of farming but does not cap the damage.
--
-- This does. It is a ceiling on total AI spend across every user per hour. A
-- runaway — scripted abuse, a client retry loop, a bug — stops at a known
-- number instead of running until someone notices the bill.
--
-- Deliberately generous: it should never fire in normal operation. It is a
-- fuse, not a quota.

create table if not exists public.app_config (
  key         text primary key,
  int_value   integer,
  updated_at  timestamptz not null default now()
);

-- Server-only. RLS on with no grants and no policies denies every client role.
alter table public.app_config enable row level security;
revoke all on public.app_config from anon, authenticated, public;

insert into public.app_config (key, int_value) values
  ('global_ai_calls_per_hour', 2000)
on conflict (key) do nothing;

comment on table public.app_config is
  'Server-only operational limits. Adjustable without a migration.';

create index if not exists ai_usage_created_idx on public.ai_usage (created_at desc);

create or replace function public.check_and_record_ai_usage(
  p_kind  text,
  p_model text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid          uuid := (select auth.uid());
  v_tier         text;
  v_expires      timestamptz;
  v_is_plus      boolean;
  v_hour_limit   integer;
  v_day_limit    integer;
  v_hour         integer;
  v_day          integer;
  v_model        text;
  v_global_cap   integer;
  v_global_used  integer;
  v_id           uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  if p_kind not in ('breakdown', 'chat') then
    raise exception 'INVALID_KIND' using errcode = '22023';
  end if;

  v_model := left(coalesce(p_model, 'unknown'), 64);
  if v_model !~ '^[A-Za-z0-9._-]+$' then
    v_model := 'unknown';
  end if;

  -- ── the fuse: total spend across every account ────────────────────────
  -- Checked before the per-user limits so that a flood of fresh accounts,
  -- each individually within its allowance, still cannot get through.
  select c.int_value into v_global_cap
    from public.app_config c where c.key = 'global_ai_calls_per_hour';
  v_global_cap := coalesce(v_global_cap, 2000);

  select count(*) into v_global_used
    from public.ai_usage u
   where u.created_at > now() - interval '1 hour';

  if v_global_used >= v_global_cap then
    raise exception 'GLOBAL_CAPACITY_REACHED' using errcode = 'P0004';
  end if;

  -- ── per-user limits ───────────────────────────────────────────────────
  select e.tier, e.expires_at into v_tier, v_expires
    from public.entitlements e where e.user_id = v_uid;

  v_is_plus := coalesce(v_tier = 'plus', false)
               and (v_expires is null or v_expires > now());

  if p_kind = 'chat' then
    v_hour_limit := case when v_is_plus then 120 else 20  end;
    v_day_limit  := case when v_is_plus then 600 else 60  end;
  else
    v_hour_limit := case when v_is_plus then  30 else  8  end;
    v_day_limit  := case when v_is_plus then 150 else 25  end;
  end if;

  select count(*) into v_hour from public.ai_usage u
   where u.user_id = v_uid and u.kind = p_kind
     and u.created_at > now() - interval '1 hour';
  if v_hour >= v_hour_limit then
    raise exception 'RATE_LIMIT_HOURLY' using errcode = 'P0002';
  end if;

  select count(*) into v_day from public.ai_usage u
   where u.user_id = v_uid and u.kind = p_kind
     and u.created_at > now() - interval '1 day';
  if v_day >= v_day_limit then
    raise exception 'RATE_LIMIT_DAILY' using errcode = 'P0003';
  end if;

  insert into public.ai_usage (user_id, kind, model)
  values (v_uid, p_kind, v_model)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.check_and_record_ai_usage(text, text) from public, anon;
grant execute on function public.check_and_record_ai_usage(text, text) to authenticated;
