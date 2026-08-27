-- 0035 — account risk, in service of not punishing a school.
--
-- Applied by hand and verified against pg_proc. The CI deploy workflow has no
-- secrets and never runs, so this repo is not the source of truth for this
-- database — see docs/plan-2026-08-25.md.
--
-- ── The problem this actually solves ─────────────────────────────────────────
--
-- Free tier is now genuinely worth farming: 5 tasks and 3 rubrics per account,
-- and anonymous sign-up is the entire onboarding, so "delete the app and
-- reinstall" is a plausible reset. The global spend fuse (0013) bounds what a
-- thousand accounts can cost us, but it is a fuse — it fires at 2000 calls an
-- hour, and long before that a farm is quietly working.
--
-- ── The problem this must not create ─────────────────────────────────────────
--
-- **A device is not a person and an IP is not a household.** A sixth-form
-- college hands out shared iPads. A family runs four students off one router.
-- A whole country's mobile traffic can leave through a handful of CGNAT
-- addresses, and a school VPN puts nine hundred students behind one /32.
-- Blocking on either signal alone does not catch a farm; it catches a class.
--
-- So the design commits to three rules, and the code enforces all three rather
-- than merely intending them:
--
--   1. **No single signal can raise a band above `elevated`.** Escalation
--      needs at least two independent families — device sharing, network, and
--      behaviour. Account age is deliberately excluded from that count: every
--      real student is new exactly once, and being new is not evidence.
--
--   2. **Paid accounts are never escalated past `elevated`.** Somebody who
--      completed a payment has performed the strongest identity check we have.
--      Rate limits still apply — a stolen account should not be able to run
--      away — but they are never asked to prove themselves again.
--
--   3. **Escalation buys friction, not a door.** `elevated` halves burst
--      limits. `high` quarters them, and asks for a real sign-in before any
--      model call — but only once there is a sign-in to ask for, because a
--      door with no key is just a wall (see `risk_verification_available`).
--      Only `severe` refuses outright, and only model calls: every screen,
--      every saved plan and every rubric the student has already written stays
--      reachable at every band. Losing your homework because a heuristic
--      disliked your Wi-Fi is not an acceptable failure mode.
--
--      Every band is recoverable without us. The signals age out of their
--      windows on their own, so a score falls back on its own — there is no
--      list to be on and nothing to appeal to.
--
-- ── What is stored ──────────────────────────────────────────────────────────
--
-- Hashes, and nothing else. The Edge Function computes
-- HMAC-SHA256(value, ALBUS_SIGNAL_PEPPER) and sends only the digest, so no raw
-- IP address and no device identifier ever reaches Postgres — not in a column,
-- not in a query log, not in a backup. The pepper lives in function secrets, so
-- rotating it retires the entire correlation set by design.
--
-- The device identifier is iOS `identifierForVendor`: per-vendor, reset when
-- the user deletes every app from this vendor, and not a hardware serial. It is
-- the weakest identifier that answers the question, which is the correct one to
-- pick.

-- ── The signal graph ────────────────────────────────────────────────────────
--
-- A bipartite user ↔ opaque-hash edge list rather than a column on the user.
-- One column would only ever hold the latest device, which cannot answer "how
-- many accounts has this device created" — the question that actually matters —
-- and would silently re-point when a student changes phone.
create table if not exists public.identity_links (
  user_id       uuid not null references auth.users(id) on delete cascade,
  kind          text not null check (kind in ('device', 'ip_prefix')),
  -- 64 lowercase hex characters: the shape of a SHA-256 digest, and the only
  -- shape accepted. A column that would take arbitrary text is a column that
  -- will eventually hold a raw IP address because somebody was in a hurry.
  hash          text not null check (hash ~ '^[0-9a-f]{64}$'),
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  hit_count     integer not null default 1,
  primary key (user_id, kind, hash)
);

create index if not exists identity_links_hash_idx
  on public.identity_links (kind, hash, last_seen_at desc);

-- Server-only in both directions. A student cannot read which other accounts
-- share their device hash — that would turn an abuse control into a way of
-- enumerating the people on your school's Wi-Fi.
alter table public.identity_links enable row level security;
revoke all on public.identity_links from anon, authenticated, public;

comment on table public.identity_links is
  'Opaque, peppered hashes linking accounts to a device or network prefix. No raw identifiers, ever.';

-- ── The audit log ───────────────────────────────────────────────────────────
--
-- Security-relevant events, deliberately thin. It records that a thing was
-- refused and roughly why; it does not record what the student was writing, who
-- they are, or where they were. `detail` is bounded and written only by our own
-- code — never by a request body.
create table if not exists public.security_events (
  id             bigint generated always as identity primary key,
  at             timestamptz not null default now(),
  -- Nullable and ON DELETE SET NULL: the log must survive the account, or
  -- "delete and start again" erases the evidence of exactly the behaviour this
  -- table exists to notice.
  user_id        uuid references auth.users(id) on delete set null,
  kind           text not null check (char_length(kind) between 1 and 64),
  severity       text not null check (severity in ('info', 'warn', 'alert')),
  device_hash    text check (device_hash ~ '^[0-9a-f]{64}$'),
  ip_prefix_hash text check (ip_prefix_hash ~ '^[0-9a-f]{64}$'),
  detail         jsonb not null default '{}'::jsonb
);

create index if not exists security_events_user_idx on public.security_events (user_id, at desc);
create index if not exists security_events_kind_idx on public.security_events (kind, at desc);
create index if not exists security_events_at_idx   on public.security_events (at desc);

alter table public.security_events enable row level security;
revoke all on public.security_events from anon, authenticated, public;

comment on table public.security_events is
  'Append-only security log. Hashed identifiers only; no request bodies, no PII.';

-- ── Recording a signal ──────────────────────────────────────────────────────
--
-- Service role only. The uid is an argument rather than auth.uid() because the
-- Edge Function calls it with the admin client after verifying the JWT itself —
-- and because nothing that runs as `authenticated` should be able to write to
-- the graph that decides whether it is trusted.
create or replace function public.record_identity_link(
  p_user_id uuid,
  p_kind    text,
  p_hash    text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_user_id is null or p_kind not in ('device', 'ip_prefix') then
    return;
  end if;
  -- Silently ignore a malformed hash rather than failing the student's request.
  -- This is telemetry for an abuse control; it is never worth an outage.
  if p_hash is null or p_hash !~ '^[0-9a-f]{64}$' then
    return;
  end if;

  insert into public.identity_links (user_id, kind, hash)
  values (p_user_id, p_kind, p_hash)
  on conflict (user_id, kind, hash) do update
    set last_seen_at = now(),
        hit_count    = public.identity_links.hit_count + 1;
end;
$$;

revoke all on function public.record_identity_link(uuid, text, text)
  from public, anon, authenticated;

create or replace function public.log_security_event(
  p_user_id        uuid,
  p_kind           text,
  p_severity       text,
  p_device_hash    text default null,
  p_ip_prefix_hash text default null,
  p_detail         jsonb default '{}'::jsonb
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.security_events (user_id, kind, severity, device_hash, ip_prefix_hash, detail)
  values (
    p_user_id,
    left(coalesce(p_kind, 'unknown'), 64),
    case when p_severity in ('info','warn','alert') then p_severity else 'info' end,
    case when p_device_hash    ~ '^[0-9a-f]{64}$' then p_device_hash    end,
    case when p_ip_prefix_hash ~ '^[0-9a-f]{64}$' then p_ip_prefix_hash end,
    -- Bounded. `detail` is written by our own code, but a log line is not worth
    -- an unbounded column and a truncated one is still readable.
    case when pg_column_size(coalesce(p_detail, '{}'::jsonb)) <= 2048
         then coalesce(p_detail, '{}'::jsonb)
         else '{"truncated": true}'::jsonb end
  );
exception when others then
  -- Logging must never fail the request it is logging. A dropped audit line is
  -- a gap; a failed grading because the audit table was full is an outage.
  null;
end;
$$;

revoke all on function public.log_security_event(uuid, text, text, text, text, jsonb)
  from public, anon, authenticated;

-- ── Tuning, without a migration ─────────────────────────────────────────────
insert into public.app_config (key, int_value) values
  ('risk_elevated_threshold', 40),
  ('risk_high_threshold',     70),
  ('risk_severe_threshold',   85),
  -- The honest switch. `high` is supposed to mean "prove you are a person
  -- before spending our money", and today there is no way for a student to do
  -- that: CAPTCHA is built but off, Apple Sign-In needs the developer account.
  -- Shipping the demand anyway would brick a false-positive account with no
  -- route back, so while this is 0 a `high` band buys tightened limits only.
  -- Flip it to 1 in the same change that turns on Turnstile or Apple Sign-In.
  ('risk_verification_available', 0)
on conflict (key) do nothing;

-- ── The score ───────────────────────────────────────────────────────────────
--
-- Returns the number, the band and — importantly — the arithmetic. A score with
-- no reasons is unauditable, and an unauditable score that refuses a real
-- student is a bug nobody can find. Every component is in the output.
create or replace function public.account_risk(p_uid uuid)
returns table (score integer, band text, reasons jsonb)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_created       timestamptz;
  v_age_minutes   numeric;
  v_is_paid       boolean;
  v_device_accts  integer := 0;
  v_device_new    integer := 0;
  v_ip_accts      integer := 0;
  v_burst         integer := 0;
  v_denials       integer := 0;
  s_age           integer := 0;
  s_device        integer := 0;
  s_velocity      integer := 0;
  s_network       integer := 0;
  s_burst         integer := 0;
  s_denials       integer := 0;
  v_score         integer;
  v_families      integer;
  v_band          text;
  t_elevated      integer;
  t_high          integer;
  t_severe        integer;
begin
  if p_uid is null then
    return query select 0, 'normal'::text, '{}'::jsonb;
    return;
  end if;

  select u.created_at into v_created from auth.users u where u.id = p_uid;
  v_age_minutes := extract(epoch from (now() - coalesce(v_created, now()))) / 60.0;

  v_is_paid := public.effective_tier(p_uid) <> 'free';

  -- ── Family A: this device has made accounts ───────────────────────────────
  --
  -- Graduated, never binary. Two accounts on one device is a student and a
  -- sibling; five is a pattern. Neither is proof, which is why this cannot
  -- escalate on its own.
  select count(distinct l2.user_id) into v_device_accts
    from public.identity_links l1
    join public.identity_links l2
      on l2.kind = 'device' and l2.hash = l1.hash
   where l1.user_id = p_uid and l1.kind = 'device'
     and l2.last_seen_at > now() - interval '30 days';

  select count(distinct l2.user_id) into v_device_new
    from public.identity_links l1
    join public.identity_links l2
      on l2.kind = 'device' and l2.hash = l1.hash
    join auth.users u2 on u2.id = l2.user_id
   where l1.user_id = p_uid and l1.kind = 'device'
     and u2.created_at > now() - interval '24 hours';

  s_device := case
    when v_device_accts >= 5 then 30
    when v_device_accts  = 4 then 20
    when v_device_accts  = 3 then 12
    when v_device_accts  = 2 then 5
    else 0 end;

  -- Rate, not total. Four accounts on a family iPad accumulated over a year is
  -- ordinary; four in one afternoon is not.
  s_velocity := case
    when v_device_new >= 5 then 25
    when v_device_new >= 3 then 15
    else 0 end;

  -- ── Family B: this network has made accounts ──────────────────────────────
  --
  -- The shallowest curve in the model, on purpose, and it tops out at 25 — a
  -- quarter of the scale — because this is the signal most likely to be a
  -- school, a hall of residence or a mobile carrier's NAT. A /24 of students
  -- must never reach a blocking band on network evidence alone, and with a
  -- ceiling of 25 against a severe threshold of 85 it structurally cannot.
  select count(distinct l2.user_id) into v_ip_accts
    from public.identity_links l1
    join public.identity_links l2
      on l2.kind = 'ip_prefix' and l2.hash = l1.hash
   where l1.user_id = p_uid and l1.kind = 'ip_prefix'
     and l2.last_seen_at > now() - interval '24 hours';

  s_network := case
    when v_ip_accts > 20 then 25
    when v_ip_accts > 10 then 18
    when v_ip_accts >  5 then 10
    when v_ip_accts >  2 then 4
    else 0 end;

  -- ── Family C: how this account is behaving ────────────────────────────────
  select count(*) into v_burst
    from public.ai_usage u
   where u.user_id = p_uid and u.created_at > now() - interval '5 minutes';

  s_burst := case
    when v_burst > 8 then 20
    when v_burst > 4 then 10
    else 0 end;

  -- Repeatedly walking into a closed door. One refusal is a student finding out
  -- what their plan includes; forty in an hour is a script probing for a gap.
  select count(*) into v_denials
    from public.security_events e
   where e.user_id = p_uid
     and e.at > now() - interval '1 hour'
     and e.kind in ('entitlement.denied', 'ratelimit.hit', 'risk.blocked');

  s_denials := case
    when v_denials > 15 then 25
    when v_denials >  5 then 15
    else 0 end;

  -- ── Family D: age. Scored, but never sufficient. ──────────────────────────
  --
  -- Excluded from the family count below. Every genuine student is minutes old
  -- exactly once, and an account's first hour is not evidence of anything.
  s_age := case
    when v_age_minutes <   10 then 25
    when v_age_minutes <   60 then 15
    when v_age_minutes < 1440 then 8
    else 0 end;

  v_score := least(100, s_age + s_device + s_velocity + s_network + s_burst + s_denials);

  -- The rule that keeps a school out of this. Two independent families, or the
  -- band cannot rise above `elevated` no matter how high the number gets.
  v_families := (case when s_device + s_velocity > 0 then 1 else 0 end)
              + (case when s_network             > 0 then 1 else 0 end)
              + (case when s_burst + s_denials   > 0 then 1 else 0 end);

  select coalesce(max(case when key = 'risk_elevated_threshold' then int_value end), 40),
         coalesce(max(case when key = 'risk_high_threshold'     then int_value end), 70),
         coalesce(max(case when key = 'risk_severe_threshold'   then int_value end), 85)
    into t_elevated, t_high, t_severe
    from public.app_config;

  v_band := case
    when v_score >= t_severe and v_families >= 2 then 'severe'
    when v_score >= t_high   and v_families >= 2 then 'high'
    when v_score >= t_elevated                   then 'elevated'
    else 'normal' end;

  -- A completed payment is the strongest identity check in this system. It is
  -- worth more than every heuristic above put together, so it caps the band.
  -- Rate limits still bite — a stolen account must not be able to run away —
  -- but a paying student is never asked to prove they are a person.
  if v_is_paid and v_band in ('high', 'severe') then
    v_band := 'elevated';
  end if;

  return query select
    v_score,
    v_band,
    jsonb_build_object(
      'age_minutes',      round(v_age_minutes),
      'device_accounts',  v_device_accts,
      'device_new_24h',   v_device_new,
      'ip_accounts_24h',  v_ip_accts,
      'calls_5m',         v_burst,
      'denials_1h',       v_denials,
      'families',         v_families,
      'paid',             v_is_paid,
      'components', jsonb_build_object(
        'age', s_age, 'device', s_device, 'velocity', s_velocity,
        'network', s_network, 'burst', s_burst, 'denials', s_denials));
end;
$$;

comment on function public.account_risk(uuid) is
  'Risk score, band and the arithmetic behind both. Escalation above `elevated` needs two independent signal families; a paid account never exceeds `elevated`.';

-- Internal. It takes a uid, and a student who could call it would learn which
-- of their classmates share a device hash by bisection.
revoke all on function public.account_risk(uuid) from public, anon, authenticated;

-- ── The gate, now risk-aware ────────────────────────────────────────────────
--
-- Same shape as 0034 with one layer inserted: authentication → global fuse →
-- risk → entitlement → rate limit → reserve. Risk sits above entitlement
-- because a farm's next move after a refusal is another account, and the answer
-- to that is not a better per-account limit.
--
-- Nothing here logs. A raised exception rolls back its own transaction, so an
-- insert into `security_events` written next to a `raise` would be discarded
-- along with it — the denial would vanish exactly when it mattered. The Edge
-- Function catches the error and logs it in a separate request, which is also
-- where the HTTP context lives.
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

  v_model := left(coalesce(p_model, 'unknown'), 64);
  if v_model !~ '^[A-Za-z0-9._-]+$' then
    v_model := 'unknown';
  end if;

  -- ── The fuse, before anything per-user ────────────────────────────────────
  select c.int_value into v_global_cap
    from public.app_config c where c.key = 'global_ai_calls_per_hour';
  v_global_cap := coalesce(v_global_cap, 2000);

  select count(*) into v_global_used
    from public.ai_usage u
   where u.created_at > now() - interval '1 hour';

  if v_global_used >= v_global_cap then
    raise exception 'GLOBAL_CAPACITY_REACHED' using errcode = 'Q0004';
  end if;

  -- ── Risk ──────────────────────────────────────────────────────────────────
  select r.band into v_band from public.account_risk(v_uid) r;
  v_band := coalesce(v_band, 'normal');

  if v_band = 'severe' then
    raise exception 'ABUSE_SUSPECTED' using errcode = 'Q0010';
  end if;

  if v_band = 'high' then
    select coalesce(c.int_value, 0) = 1 into v_verify_on
      from public.app_config c where c.key = 'risk_verification_available';

    -- Read from auth.users rather than the JWT's `is_anonymous` claim: a
    -- student who links Apple Sign-In mid-session keeps the token they signed
    -- in with, so the claim can say anonymous for an hour after it stopped
    -- being true — and asking somebody to verify twice is how you lose them.
    select u.is_anonymous into v_anonymous from auth.users u where u.id = v_uid;

    if coalesce(v_verify_on, false) and coalesce(v_anonymous, false) then
      raise exception 'VERIFICATION_REQUIRED' using errcode = 'Q0009';
    end if;
  end if;

  v_divisor := case v_band when 'high' then 4 when 'elevated' then 2 else 1 end;

  -- ── Which plan ────────────────────────────────────────────────────────────
  v_tier := public.effective_tier(v_uid);
  select * into v_plan from public.plans p where p.tier = v_tier;
  if not found then
    raise exception 'PLAN_UNKNOWN' using errcode = 'Q0005';
  end if;

  -- ── Entitlement: what the student actually bought ─────────────────────────
  --
  -- Untouched by risk, deliberately. Risk controls *rate*; it never takes away
  -- an allowance somebody paid for.
  if p_kind = 'chat' then
    v_allow_limit  := v_plan.chat_per_month;
    v_allow_window := interval '30 days';
  elsif p_kind = 'grade' then
    v_allow_limit  := v_plan.grade_per_week;
    v_allow_window := interval '7 days';
  else
    v_allow_limit := null;
  end if;

  -- NULL is unlimited. Zero is not included. Order matters: checking
  -- `used >= limit` first would render "not included" as "allowance used up"
  -- and send a free student a date instead of a price.
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

  -- ── Rate limits, tightened by band ────────────────────────────────────────
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

  -- `> 0` is load-bearing on both. `greatest(1, 0 / 2)` is 1, so dividing a
  -- zero limit would hand a suspicious account one call it does not have.
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

-- ── Retention ───────────────────────────────────────────────────────────────
--
-- Written, not scheduled — the same position `reap_abandoned_anonymous_users`
-- is in, and for the same reason: there is no traffic yet and pg_cron is off.
--
-- Both windows are longer than any window the risk model reads (30 days), so
-- pruning can never change a live score. Keeping correlation data past the
-- point it is used would be collecting for its own sake, which is exactly what
-- the hashing is meant to avoid.
create or replace function public.prune_security_data(
  p_link_days  integer default 90,
  p_event_days integer default 180
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_links  integer;
  v_events integer;
begin
  delete from public.identity_links
   where last_seen_at < now() - make_interval(days => greatest(30, p_link_days));
  get diagnostics v_links = row_count;

  delete from public.security_events
   where at < now() - make_interval(days => greatest(30, p_event_days));
  get diagnostics v_events = row_count;

  return v_links + v_events;
end;
$$;

revoke all on function public.prune_security_data(integer, integer)
  from public, anon, authenticated;
