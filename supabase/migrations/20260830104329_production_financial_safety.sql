-- Production financial safety.
--
-- `ai_usage` used to serve three different jobs at once:
--   * a student's purchased allowance;
--   * a per-account request-rate limit;
--   * the project-wide cost fuse.
--
-- Those are not the same number. A failed grading should not consume one of a
-- student's five successful markings, but it is still an attempt that may have
-- reached Anthropic and must count against both rate and cost protection. This
-- migration separates those meanings and makes the reservation/finalisation
-- RPCs server-only. A modified client can no longer manufacture reservations,
-- forge token counts, or exhaust the global fuse by calling the RPC directly.

-- ---------------------------------------------------------------------------
-- 1. An immutable-enough attempt ledger

alter table public.ai_usage
  add column attempt_state text not null default 'reserved'
    check (attempt_state in ('reserved', 'completed', 'failed')),
  add column finished_at timestamptz,
  add column failure_code text,
  add column reserved_cost_microusd integer not null default 0
    check (reserved_cost_microusd between 0 and 10000000),
  add column actual_cost_microusd integer
    check (actual_cost_microusd between 0 and 10000000);

-- Old rows with evidence of a delivered result are successful. Old abandoned
-- reservations bought no result and must not occupy an allowance forever.
update public.ai_usage u
   set attempt_state = 'completed',
       finished_at = coalesce(u.finished_at, u.created_at)
 where u.input_tokens is not null
    or u.output_tokens is not null
    or exists (select 1 from public.gradings g where g.usage_id = u.id);

update public.ai_usage
   set attempt_state = 'failed',
       finished_at = coalesce(finished_at, created_at),
       failure_code = 'LEGACY_ABANDONED'
 where attempt_state = 'reserved'
   and created_at <= now() - interval '15 minutes';

create index ai_usage_global_recent_idx
  on public.ai_usage (created_at desc)
  include (reserved_cost_microusd);

create index ai_usage_user_kind_recent_idx
  on public.ai_usage (user_id, kind, created_at desc)
  include (attempt_state);

-- The app reads the single `my_plan()` projection. Direct access to the raw
-- subscription and cost ledgers is unnecessary privilege and makes future
-- columns accidentally public to every client that owns the row.
revoke all on public.ai_usage from public, anon, authenticated;
revoke all on public.entitlements from public, anon, authenticated;

-- Price data is not a client API. Keeping it outside the exposed `public`
-- schema prevents a future RLS mistake from turning cost accounting into
-- user-editable data.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table private.ai_model_prices (
  model                      text primary key,
  input_microusd_per_token   integer not null check (input_microusd_per_token > 0),
  output_microusd_per_token  integer not null check (output_microusd_per_token > 0),
  updated_at                 timestamptz not null default now()
);

revoke all on private.ai_model_prices from public, anon, authenticated;

-- USD per million tokens maps numerically to micro-USD per token. These are
-- deliberately the uncached rates: a safety ledger may overestimate savings;
-- it must never assume a cache hit that did not happen.
insert into private.ai_model_prices
  (model, input_microusd_per_token, output_microusd_per_token)
values
  ('claude-opus-5',       5, 25),
  ('claude-sonnet-5',     2, 10),
  ('claude-haiku-4-5',    1,  5)
on conflict (model) do update set
  input_microusd_per_token  = excluded.input_microusd_per_token,
  output_microusd_per_token = excluded.output_microusd_per_token,
  updated_at                 = now();

create or replace function private.ai_reservation_cost(
  p_kind text,
  p_model text
) returns integer
language sql
immutable
set search_path = ''
as $$
  -- Conservative endpoint ceilings, not average prices. Unknown combinations
  -- fail expensive rather than cheap, so adding a model without adding its
  -- price can stop capacity but can never open an unmetered path.
  select case
    when p_kind = 'grade' and p_model = 'claude-opus-5'    then 450000
    when p_kind = 'grade' and p_model = 'claude-sonnet-5'  then 200000
    when p_kind = 'chat'  and p_model = 'claude-sonnet-5'  then  60000
    when p_kind = 'chat'  and p_model = 'claude-haiku-4-5' then  30000
    when p_kind = 'breakdown' and p_model = 'claude-sonnet-5'  then 60000
    when p_kind = 'breakdown' and p_model = 'claude-haiku-4-5' then 30000
    else 500000
  end;
$$;

revoke all on function private.ai_reservation_cost(text, text)
  from public, anon, authenticated;

-- A missing price must remain fail-expensive, but it must not remain silent.
-- Keep this volatile because emitting the warning is an intentional observable
-- side effect: it is the signal that the model-price catalogue needs updating.
create or replace function private.ai_metered_cost(
  p_model text,
  p_input_tokens integer,
  p_output_tokens integer
) returns bigint
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_input_rate integer;
  v_output_rate integer;
begin
  select p.input_microusd_per_token, p.output_microusd_per_token
    into v_input_rate, v_output_rate
    from private.ai_model_prices p
   where p.model = p_model;

  if not found then
    v_input_rate := 50;
    v_output_rate := 100;
    raise warning 'AI model "%" has no configured token price; using fallback input=50/output=100 micro-USD per token',
      coalesce(p_model, '<null>');
  end if;

  return greatest(0, coalesce(p_input_tokens, 0))::bigint * v_input_rate
       + greatest(0, coalesce(p_output_tokens, 0))::bigint * v_output_rate;
end;
$$;

revoke all on function private.ai_metered_cost(text, integer, integer)
  from public, anon, authenticated;

-- Price the history before any rolling money fuse can rely on it. Existing
-- token rows were written by the server and are clamped, so they can use the
-- same uncached model prices as finalisation. A row without token evidence
-- keeps the conservative endpoint reservation: an old crashed isolate must
-- not become free merely because its final token write never landed.
update public.ai_usage u
   set reserved_cost_microusd = private.ai_reservation_cost(u.kind, u.model),
       actual_cost_microusd = case
         when u.input_tokens is null and u.output_tokens is null then null
         else least(
           10000000::bigint,
           private.ai_metered_cost(u.model, u.input_tokens, u.output_tokens)
         )::integer
       end;

-- Future accounting writers must name a real reservation. Leaving the old
-- zero default in place would silently recreate the same hole when a new
-- server path forgot the field.
alter table public.ai_usage
  alter column reserved_cost_microusd drop default,
  add constraint ai_usage_reserved_cost_positive
    check (reserved_cost_microusd > 0);

-- A plan allowance says what the student may receive. This second boundary
-- says how much one account may ever make Albus spend in a rolling month. The
-- values are deliberately private: they are an operational loss ceiling, not
-- a client entitlement that a modified app should be able to inspect or use as
-- a substitute for the feature-specific limits.
--
-- These launch values fit ordinary use at the endpoint token ceilings while
-- bounding a farmed, scripted, or compromised account to US$1 / $5.50 / $12.
-- They should be revisited from observed p50/p95 cost before launch volume is
-- raised, never weakened merely because the client asks more often.
create table private.ai_tier_budgets (
  tier                       text primary key references public.plans(tier),
  rolling_30d_cost_microusd  integer not null
    check (rolling_30d_cost_microusd between 100000 and 100000000),
  updated_at                 timestamptz not null default now()
);

revoke all on private.ai_tier_budgets from public, anon, authenticated;

insert into private.ai_tier_budgets (tier, rolling_30d_cost_microusd) values
  ('free', 1000000),
  ('plus', 5500000),
  ('pro', 12000000)
on conflict (tier) do update set
  rolling_30d_cost_microusd = excluded.rolling_30d_cost_microusd,
  updated_at = now();

create or replace function private.ai_account_cost(
  p_uid uuid,
  p_since interval
) returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  -- A terminal call with provider usage pays its measured, server-priced cost.
  -- Anything unfinished or unknown keeps the conservative reservation. A
  -- crashed isolate therefore cannot turn an Anthropic call into free budget.
  select coalesce(sum(
    case
      when u.attempt_state = 'reserved' then u.reserved_cost_microusd
      when u.actual_cost_microusd is not null then u.actual_cost_microusd
      else u.reserved_cost_microusd
    end
  ), 0)::bigint
  from public.ai_usage u
  where u.user_id = p_uid
    and u.created_at > now() - p_since;
$$;

revoke all on function private.ai_account_cost(uuid, interval)
  from public, anon, authenticated;

create or replace function private.ai_attempt_count(
  p_uid uuid,
  p_kind text,
  p_since interval
) returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
    from public.ai_usage u
   where u.user_id = p_uid
     and u.kind = p_kind
     and u.created_at > now() - p_since;
$$;

revoke all on function private.ai_attempt_count(uuid, text, interval)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Allowance means delivered result; rate means every attempt

create or replace function public.ai_spend_count(
  p_uid uuid,
  p_kind text,
  p_since interval
) returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
    from public.ai_usage u
   where u.user_id = p_uid
     and u.kind = p_kind
     and u.created_at > now() - p_since
     and (
          u.attempt_state = 'completed'
       or (u.attempt_state = 'reserved'
           and u.created_at > now() - interval '15 minutes')
     );
$$;

comment on function public.ai_spend_count(uuid, text, interval) is
  'Successful results plus genuinely in-flight reservations. Failed attempts do not consume a purchased allowance.';

revoke all on function public.ai_spend_count(uuid, text, interval)
  from public, anon, authenticated;

create or replace function public.ai_window_resets_at(
  p_uid uuid,
  p_kind text,
  p_since interval
) returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select min(u.created_at) + p_since
    from public.ai_usage u
   where u.user_id = p_uid
     and u.kind = p_kind
     and u.created_at > now() - p_since
     and (
          u.attempt_state = 'completed'
       or (u.attempt_state = 'reserved'
           and u.created_at > now() - interval '15 minutes')
     );
$$;

revoke all on function public.ai_window_resets_at(uuid, text, interval)
  from public, anon, authenticated;

-- Start with deliberately small launch budgets. They are live configuration,
-- so capacity can be raised after observing real traffic without redeploying.
-- A hard stop is also available for an incident: 1 refuses every model call.
insert into public.app_config (key, int_value) values
  ('global_ai_calls_per_hour',       100),
  ('ai_budget_per_hour_microusd', 2000000), -- US$2 reserved worst-case / hour
  ('ai_budget_per_day_microusd', 10000000), -- US$10 reserved worst-case / day
  ('ai_emergency_stop',                0),
  -- Defence in depth behind the Edge Function's environment check. A sandbox
  -- purchase is free to create and must never become a production entitlement.
  ('allow_sandbox_subscriptions',      0)
on conflict (key) do update set int_value = excluded.int_value;

-- The old two-argument function trusted `auth.uid()` and therefore had to be
-- callable by every authenticated client. Remove that capability before the
-- replacement exists. Edge Functions call the three-argument version using
-- the service key and pass the user id obtained from a verified JWT.
revoke all on function public.check_and_record_ai_usage(text, text)
  from public, anon, authenticated, service_role;

create or replace function public.check_and_record_ai_usage(
  p_user_id uuid,
  p_kind text,
  p_model text
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan          public.plans%rowtype;
  v_allow_limit   integer;
  v_allow_window  interval;
  v_used          integer;
  v_hour_limit    integer;
  v_day_limit     integer;
  v_model         text;
  v_global_cap    integer;
  v_global_used   integer;
  v_hour_budget   bigint;
  v_day_budget    bigint;
  v_hour_reserved bigint;
  v_day_reserved  bigint;
  v_reservation   integer;
  v_account_budget bigint;
  v_account_spend  bigint;
  v_emergency     boolean;
  v_band          text;
  v_divisor       integer := 1;
  v_verify_on     boolean;
  v_anonymous     boolean;
  v_id            uuid;
begin
  if p_user_id is null
     or not exists (select 1 from auth.users u where u.id = p_user_id) then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  if p_kind not in ('breakdown', 'chat', 'grade') then
    raise exception 'INVALID_KIND' using errcode = '22023';
  end if;

  v_model := left(coalesce(p_model, 'unknown'), 64);
  if v_model !~ '^[A-Za-z0-9._-]+$' then v_model := 'unknown'; end if;
  v_reservation := private.ai_reservation_cost(p_kind, v_model);

  -- Global first, user second, everywhere. The short global lock closes the
  -- thousand-account race on both the call fuse and monetary budget. Holding
  -- locks in one order prevents deadlocks.
  perform pg_advisory_xact_lock(hashtextextended('albus:ai_usage:global', 0));
  perform pg_advisory_xact_lock(
    hashtextextended('albus:ai_usage:' || p_user_id::text, 0));

  select coalesce(max(case when key = 'ai_emergency_stop' then int_value end), 0) = 1,
         coalesce(max(case when key = 'global_ai_calls_per_hour' then int_value end), 100),
         coalesce(max(case when key = 'ai_budget_per_hour_microusd' then int_value end), 2000000),
         coalesce(max(case when key = 'ai_budget_per_day_microusd' then int_value end), 10000000)
    into v_emergency, v_global_cap, v_hour_budget, v_day_budget
    from public.app_config;

  if v_emergency then
    raise exception 'AI_EMERGENCY_STOP' using errcode = 'Q0013';
  end if;

  select count(*), coalesce(sum(u.reserved_cost_microusd), 0)
    into v_global_used, v_hour_reserved
    from public.ai_usage u
   where u.created_at > now() - interval '1 hour';

  if v_global_used >= v_global_cap
     or v_hour_reserved + v_reservation > v_hour_budget then
    raise exception 'GLOBAL_CAPACITY_REACHED' using errcode = 'Q0004';
  end if;

  select coalesce(sum(u.reserved_cost_microusd), 0)
    into v_day_reserved
    from public.ai_usage u
   where u.created_at > now() - interval '1 day';

  if v_day_reserved + v_reservation > v_day_budget then
    raise exception 'GLOBAL_CAPACITY_REACHED' using errcode = 'Q0004';
  end if;

  select r.band into v_band from public.account_risk(p_user_id) r;
  v_band := coalesce(v_band, 'normal');
  if v_band = 'severe' then
    raise exception 'ABUSE_SUSPECTED' using errcode = 'Q0010';
  end if;

  if v_band = 'high' then
    select coalesce(c.int_value, 0) = 1 into v_verify_on
      from public.app_config c where c.key = 'risk_verification_available';
    select u.is_anonymous into v_anonymous from auth.users u where u.id = p_user_id;
    if coalesce(v_verify_on, false) and coalesce(v_anonymous, false) then
      raise exception 'VERIFICATION_REQUIRED' using errcode = 'Q0009';
    end if;
  end if;
  v_divisor := case v_band when 'high' then 4 when 'elevated' then 2 else 1 end;

  select p.* into v_plan
    from public.plans p where p.tier = public.effective_tier(p_user_id);
  if not found then raise exception 'PLAN_UNKNOWN' using errcode = 'Q0005'; end if;

  if p_kind = 'chat' then
    v_allow_limit := v_plan.chat_per_month;
    v_allow_window := interval '30 days';
  elsif p_kind = 'grade' then
    v_allow_limit := v_plan.grade_per_week;
    v_allow_window := interval '7 days';
  else
    v_allow_limit := null;
  end if;

  if v_allow_limit = 0 then
    raise exception 'PLAN_UPGRADE_REQUIRED' using errcode = 'Q0007';
  elsif v_allow_limit is not null then
    v_used := public.ai_spend_count(p_user_id, p_kind, v_allow_window);
    if v_used >= v_allow_limit then
      if p_kind = 'chat' then
        raise exception 'ALLOWANCE_MONTHLY' using errcode = 'Q0008';
      else
        raise exception 'ALLOWANCE_WEEKLY' using errcode = 'Q0006';
      end if;
    end if;
  end if;

  -- Check cost only after entitlement. A Free account asking for Grader must
  -- hear that Grader is not on Free even if it has also spent its planning
  -- budget; reversing these checks turns an upgrade decision into a vague
  -- operational refusal.
  select b.rolling_30d_cost_microusd into v_account_budget
    from private.ai_tier_budgets b where b.tier = v_plan.tier;
  if v_account_budget is null then
    -- Missing safety configuration must fail closed. Treating it as unlimited
    -- would make a new tier or a bad deployment an unmetered provider path.
    raise exception 'AI_BUDGET_UNKNOWN' using errcode = 'Q0017';
  end if;

  v_account_spend := private.ai_account_cost(
    p_user_id, interval '30 days');
  if v_account_spend + v_reservation > v_account_budget then
    raise exception 'FAIR_USE_REACHED' using errcode = 'Q0017';
  end if;

  if p_kind = 'chat' then
    v_hour_limit := v_plan.chat_per_hour;
    v_day_limit := v_plan.chat_per_day;
  elsif p_kind = 'grade' then
    v_hour_limit := v_plan.grade_per_hour;
    v_day_limit := null;
  else
    v_hour_limit := v_plan.breakdown_per_hour;
    v_day_limit := v_plan.breakdown_per_day;
  end if;

  if v_divisor > 1 then
    if v_hour_limit is not null and v_hour_limit > 0 then
      v_hour_limit := greatest(1, v_hour_limit / v_divisor);
    end if;
    if v_day_limit is not null and v_day_limit > 0 then
      v_day_limit := greatest(1, v_day_limit / v_divisor);
    end if;
  end if;

  -- Every reservation is an attempt, including a provider failure. That makes
  -- retries finite even though failed results do not consume the allowance.
  if v_hour_limit is not null
     and private.ai_attempt_count(p_user_id, p_kind, interval '1 hour') >= v_hour_limit then
    raise exception 'RATE_LIMIT_HOURLY' using errcode = 'Q0002';
  end if;
  if v_day_limit is not null
     and private.ai_attempt_count(p_user_id, p_kind, interval '1 day') >= v_day_limit then
    raise exception 'RATE_LIMIT_DAILY' using errcode = 'Q0003';
  end if;

  insert into public.ai_usage
    (user_id, kind, model, attempt_state, reserved_cost_microusd)
  values
    (p_user_id, p_kind, v_model, 'reserved', v_reservation)
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.check_and_record_ai_usage(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.check_and_record_ai_usage(uuid, text, text)
  to service_role;

-- One terminal write: callers cannot change the model, owner, reservation, or
-- outcome twice. Cost is derived from server-owned prices, never from input.
create or replace function public.finalize_ai_usage(
  p_usage_id uuid,
  p_state text,
  p_input_tokens integer default null,
  p_output_tokens integer default null,
  p_failure_code text default null
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_input integer := least(2000000, greatest(0, coalesce(p_input_tokens, 0)));
  v_output integer := least(2000000, greatest(0, coalesce(p_output_tokens, 0)));
  v_changed integer;
begin
  if p_state not in ('completed', 'failed') then
    raise exception 'INVALID_USAGE_STATE' using errcode = '22023';
  end if;

  update public.ai_usage u
     set attempt_state = p_state,
         input_tokens = case when p_input_tokens is null then null else v_input end,
         output_tokens = case when p_output_tokens is null then null else v_output end,
         actual_cost_microusd = case
           when p_input_tokens is null and p_output_tokens is null then null
           else least(
             10000000::bigint,
             private.ai_metered_cost(u.model, v_input, v_output)
           )::integer
           end,
         failure_code = case when p_state = 'failed'
                             then left(coalesce(p_failure_code, 'UNKNOWN'), 64)
                             else null end,
         finished_at = now()
   where u.id = p_usage_id
     and u.attempt_state = 'reserved';

  get diagnostics v_changed = row_count;
  return v_changed = 1;
end;
$$;

revoke all on function public.finalize_ai_usage(uuid, text, integer, integer, text)
  from public, anon, authenticated;
grant execute on function public.finalize_ai_usage(uuid, text, integer, integer, text)
  to service_role;

-- The legacy token writer let an authenticated client poison its own cost
-- records and is no longer used by an Edge Function.
revoke all on function public.record_ai_usage_tokens(uuid, integer, integer)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Payment state fails closed until real products are explicitly mapped

create table public.subscription_products (
  product_id text primary key,
  tier text not null references public.plans(tier),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check (tier in ('plus', 'pro'))
);

alter table public.subscription_products enable row level security;
revoke all on public.subscription_products from public, anon, authenticated;

alter table public.subscription_transactions
  add column last_event_id text,
  add column last_event_at timestamptz;

create unique index subscription_transactions_last_event_idx
  on public.subscription_transactions(last_event_id)
  where last_event_id is not null;

-- Remove the old signature so a deployed superseded endpoint cannot keep using
-- the pre-three-plan implementation that granted Plus for every product id.
revoke all on function public.apply_subscription_state(
  text, uuid, text, text, text, timestamptz, timestamptz, timestamptz)
  from public, anon, authenticated, service_role;

create or replace function public.apply_subscription_state(
  p_original_transaction_id text,
  p_user_id uuid,
  p_latest_transaction_id text,
  p_product_id text,
  p_environment text,
  p_purchase_date timestamptz,
  p_expires_at timestamptz,
  p_revoked_at timestamptz,
  p_event_id text,
  p_event_at timestamptz
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing public.subscription_transactions%rowtype;
  v_had_existing boolean := false;
  v_owner uuid;
  v_product text;
  v_tier text;
  v_effective_tier text;
  v_effective_expires timestamptz;
  v_effective_transaction text;
begin
  if p_original_transaction_id is null or length(p_original_transaction_id) > 255
     or p_event_id is null or length(p_event_id) > 255
     or p_event_at is null
     or p_environment not in ('Production', 'Sandbox') then
    return 'invalid';
  end if;

  if p_environment = 'Sandbox'
     and coalesce((select c.int_value from public.app_config c
                    where c.key = 'allow_sandbox_subscriptions'), 0) <> 1 then
    return 'sandbox_ignored';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('albus:subscription:' || p_original_transaction_id, 0));

  select * into v_existing
    from public.subscription_transactions s
   where s.original_transaction_id = p_original_transaction_id;
  v_had_existing := found;

  if v_had_existing and v_existing.last_event_at is not null
     and (p_event_at < v_existing.last_event_at
          or p_event_id = v_existing.last_event_id) then
    return 'stale';
  end if;

  if v_had_existing and v_existing.user_id is not null and p_user_id is not null
     and v_existing.user_id <> p_user_id then
    return 'conflict';
  end if;

  v_owner := coalesce(p_user_id, v_existing.user_id);

  -- One account can briefly own more than one transaction during an upgrade,
  -- cross-platform purchase, or billing retry. Events are ordered per original
  -- transaction, but entitlement is one row per *user*, so transactions for
  -- the same user must also serialize. Without this lock two valid webhooks
  -- can each recompute from a different snapshot and let the last writer
  -- downgrade a still-active Pro account to Plus or Free.
  if v_owner is not null then
    perform pg_advisory_xact_lock(
      hashtextextended('albus:subscription-owner:' || v_owner::text, 0));
  end if;

  v_product := coalesce(nullif(p_product_id, ''), v_existing.product_id);
  select sp.tier into v_tier
    from public.subscription_products sp
   where sp.product_id = v_product and sp.active;

  -- Removing a product from sale prevents *new* transactions from granting it;
  -- it must not invalidate an already verified subscriber. Existing renewals
  -- and revocations therefore keep the stored mapping even after retirement.
  if v_tier is null and v_had_existing and v_product = v_existing.product_id then
    select sp.tier into v_tier
      from public.subscription_products sp
     where sp.product_id = v_existing.product_id;
  end if;
  if v_tier is null then return 'unknown_product'; end if;

  insert into public.subscription_transactions (
    original_transaction_id, user_id, latest_transaction_id, product_id,
    environment, purchase_date, expires_at, revoked_at,
    last_event_id, last_event_at, updated_at
  ) values (
    p_original_transaction_id, v_owner, p_latest_transaction_id, v_product,
    p_environment, p_purchase_date, p_expires_at, p_revoked_at,
    p_event_id, p_event_at, now()
  )
  on conflict (original_transaction_id) do update set
    user_id = coalesce(public.subscription_transactions.user_id, excluded.user_id),
    latest_transaction_id = excluded.latest_transaction_id,
    product_id = coalesce(excluded.product_id, public.subscription_transactions.product_id),
    environment = excluded.environment,
    purchase_date = excluded.purchase_date,
    expires_at = excluded.expires_at,
    revoked_at = excluded.revoked_at,
    last_event_id = excluded.last_event_id,
    last_event_at = excluded.last_event_at,
    updated_at = now();

  if v_owner is null then return 'unlinked'; end if;

  -- Derive the account from every verified transaction, not just the event
  -- that happened to arrive last. RevenueCat can legitimately deliver an old
  -- Plus expiration after a Pro upgrade. Choosing by plan rank preserves Pro;
  -- choosing by expiry within one rank preserves the longest paid period.
  select sp.tier, s.expires_at, s.original_transaction_id
    into v_effective_tier, v_effective_expires, v_effective_transaction
    from public.subscription_transactions s
    join public.subscription_products sp
      on sp.product_id = s.product_id
    join public.plans p on p.tier = sp.tier
   where s.user_id = v_owner
     and s.environment = 'Production'
     and s.revoked_at is null
     and s.expires_at is not null
     and s.expires_at > now()
   order by p.rank desc, s.expires_at desc, s.original_transaction_id
   limit 1;

  insert into public.entitlements
    (user_id, tier, expires_at, original_transaction_id, updated_at)
  values (
    v_owner, coalesce(v_effective_tier, 'free'),
    v_effective_expires, v_effective_transaction, now()
  )
  on conflict (user_id) do update set
    tier = excluded.tier,
    expires_at = excluded.expires_at,
    original_transaction_id = excluded.original_transaction_id,
    updated_at = now();

  return case when v_effective_tier is not null
              then 'active_' || v_effective_tier else 'inactive' end;
end;
$$;

revoke all on function public.apply_subscription_state(
  text, uuid, text, text, text, timestamptz, timestamptz, timestamptz, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.apply_subscription_state(
  text, uuid, text, text, text, timestamptz, timestamptz, timestamptz, text, timestamptz)
  to service_role;

-- ---------------------------------------------------------------------------
-- 4. Privacy retention actually runs

create or replace function public.prune_security_data(
  p_link_days integer default 90,
  p_event_days integer default 180
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_links integer;
  v_events integer;
  v_attempts integer;
begin
  delete from public.identity_links
   where last_seen_at < now() - make_interval(days => greatest(30, p_link_days));
  get diagnostics v_links = row_count;

  delete from public.security_events
   where at < now() - make_interval(days => greatest(30, p_event_days));
  get diagnostics v_events = row_count;

  -- Failed/abandoned attempts have served both the risk and billing-debugging
  -- windows after 30 days. Successful rows stay for annual cost reconciliation.
  delete from public.ai_usage
   where attempt_state in ('failed', 'reserved')
     and created_at < now() - interval '30 days';
  get diagnostics v_attempts = row_count;

  return v_links + v_events + v_attempts;
end;
$$;

revoke all on function public.prune_security_data(integer, integer)
  from public, anon, authenticated;

do $$
begin
  perform cron.unschedule('prune-security-data');
exception when others then null;
end $$;

select cron.schedule(
  'prune-security-data',
  '43 4 * * *',
  $$select public.prune_security_data(90, 180)$$
);
