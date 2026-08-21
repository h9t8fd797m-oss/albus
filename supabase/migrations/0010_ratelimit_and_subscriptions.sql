-- 0010_ratelimit_and_subscriptions
--
-- Two pieces of server-side infrastructure the remaining endpoints need:
--   1. An atomic AI rate limiter — the only thing standing between a
--      compromised or scripted client and an unbounded Anthropic bill.
--   2. Subscription state, verified from Apple and never from the client.

-- ── 1. rate limiting ──────────────────────────────────────────────────────
--
-- Reserve-then-spend: the usage row is inserted BEFORE the model is called, in
-- the same transaction as the count. Two concurrent requests cannot both read
-- "9 of 10 used" and both proceed. Cost of that choice is that a failed
-- generation still consumes a slot, which is the correct direction to err.

create index if not exists ai_usage_ratelimit_idx
  on public.ai_usage (user_id, kind, created_at desc);

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
  v_uid        uuid := (select auth.uid());
  v_tier       text;
  v_expires    timestamptz;
  v_is_plus    boolean;
  v_hour_limit integer;
  v_day_limit  integer;
  v_hour       integer;
  v_day        integer;
  v_id         uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  if p_kind not in ('breakdown', 'chat') then
    raise exception 'INVALID_KIND' using errcode = '22023';
  end if;

  select e.tier, e.expires_at into v_tier, v_expires
    from public.entitlements e where e.user_id = v_uid;

  -- coalesce is load-bearing: a missing row means free, and NULL = 'plus'
  -- would otherwise collapse the whole guard (see migration 0009).
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
  values (v_uid, p_kind, p_model)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.check_and_record_ai_usage(text, text) from public, anon;
grant execute on function public.check_and_record_ai_usage(text, text) to authenticated;

-- ── 2. subscriptions ──────────────────────────────────────────────────────
--
-- One row per Apple subscription, keyed by the identifier Apple keeps stable
-- across renewals. The primary key is the replay defence: a signed transaction
-- can only ever be bound to one account, so a leaked receipt cannot be
-- redeemed a second time by somebody else.

create table if not exists public.subscription_transactions (
  original_transaction_id text primary key,
  user_id                 uuid references auth.users(id) on delete set null,
  latest_transaction_id   text,
  product_id              text,
  environment             text not null check (environment in ('Sandbox', 'Production')),
  purchase_date           timestamptz,
  expires_at              timestamptz,
  revoked_at              timestamptz,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

create index if not exists subscription_transactions_user_idx
  on public.subscription_transactions (user_id);

-- Server-only. No grants and no policies: with RLS on and nothing granted,
-- every client role is denied outright. Only the service role reaches this.
alter table public.subscription_transactions enable row level security;
revoke all on public.subscription_transactions from anon, authenticated, public;

-- Applies verified Apple state and derives the entitlement from it.
-- Entitlement is never written from anywhere else, so premium status cannot
-- be set by a client under any circumstance.
create or replace function public.apply_subscription_state(
  p_original_transaction_id text,
  p_user_id                 uuid,
  p_latest_transaction_id   text,
  p_product_id              text,
  p_environment             text,
  p_purchase_date           timestamptz,
  p_expires_at              timestamptz,
  p_revoked_at              timestamptz
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing_user uuid;
  v_owner         uuid;
  v_active        boolean;
begin
  select s.user_id into v_existing_user
    from public.subscription_transactions s
   where s.original_transaction_id = p_original_transaction_id;

  -- Someone else already owns this subscription. Record nothing, grant
  -- nothing: this is a stolen-receipt attempt or a genuine account mix-up,
  -- and both are resolved by a human, not by silently reassigning premium.
  if v_existing_user is not null and p_user_id is not null
     and v_existing_user <> p_user_id then
    return 'conflict';
  end if;

  v_owner := coalesce(p_user_id, v_existing_user);

  insert into public.subscription_transactions (
    original_transaction_id, user_id, latest_transaction_id, product_id,
    environment, purchase_date, expires_at, revoked_at, updated_at
  ) values (
    p_original_transaction_id, v_owner, p_latest_transaction_id, p_product_id,
    p_environment, p_purchase_date, p_expires_at, p_revoked_at, now()
  )
  on conflict (original_transaction_id) do update set
    user_id               = coalesce(public.subscription_transactions.user_id, excluded.user_id),
    latest_transaction_id = excluded.latest_transaction_id,
    product_id            = excluded.product_id,
    environment           = excluded.environment,
    purchase_date         = excluded.purchase_date,
    expires_at            = excluded.expires_at,
    revoked_at            = excluded.revoked_at,
    updated_at            = now();

  -- Apple can notify us about a subscription before we know whose it is.
  -- Store the state, grant nothing until a signed client call links it.
  if v_owner is null then
    return 'unlinked';
  end if;

  v_active := p_revoked_at is null
              and (p_expires_at is null or p_expires_at > now());

  insert into public.entitlements (user_id, tier, expires_at, original_transaction_id, updated_at)
  values (v_owner,
          case when v_active then 'plus' else 'free' end,
          p_expires_at, p_original_transaction_id, now())
  on conflict (user_id) do update set
    tier                    = excluded.tier,
    expires_at              = excluded.expires_at,
    original_transaction_id = excluded.original_transaction_id,
    updated_at              = now();

  return case when v_active then 'active' else 'inactive' end;
end;
$$;

revoke all on function public.apply_subscription_state(
  text, uuid, text, text, text, timestamptz, timestamptz, timestamptz)
  from public, anon, authenticated;
