-- 0034 — Free, Plus and Pro, with one place that decides what each one buys.
--
-- Applied by hand and verified against pg_proc. The CI deploy workflow has no
-- secrets and never runs, so this repo is not the source of truth for this
-- database — see docs/plan-2026-08-25.md.
--
-- ── Why a table rather than a CASE ───────────────────────────────────────────
--
-- Every limit in this app was previously a literal, and the same literal was
-- written out in four places: the gate, the meter, the pre-flight check in the
-- Edge Function, and the sentence on screen. Migration 0031 argued for that
-- duplication on the grounds that a shared helper is a bypass one bad refactor
-- away. 0033 had to walk half of it back, because the meter and the gate had
-- drifted and the screen said "3 left this week" directly above "that's this
-- week's markings used".
--
-- Three tiers make that argument untenable: fifteen numbers in four places is
-- sixty chances to disagree. So the numbers live in one table, read by the
-- gate, the meter and the paywall alike — and the *structure* of the checks
-- stays duplicated, which is where the original reasoning actually applied. A
-- bad refactor of a limit now shows the wrong price; it cannot open a hole.
--
-- The table is readable by every signed-in user on purpose. It is a price list.
-- A student who reads it learns what Plus costs, which is what the paywall is
-- there to tell them anyway.
--
-- ── Null is unlimited. Zero is not included. ─────────────────────────────────
--
-- This is the load-bearing convention in the whole migration and it reverses
-- what 0031 did. There, `limit_week = 0` meant "no ceiling" — the way Plus was
-- expressed. With a Free tier that genuinely gets *zero* gradings, that reading
-- would hand every free student unlimited marking.
--
-- So: NULL means no ceiling, 0 means the plan does not include this at all, and
-- a positive number is a real allowance. The two cases are different errors,
-- different screens and different sentences — "upgrade to get this" is not
-- "you have used this week's".

-- ── The catalogue ───────────────────────────────────────────────────────────

create table if not exists public.plans (
  tier                 text primary key check (tier in ('free', 'plus', 'pro')),
  -- Ordering for "is this at least Plus" questions. Never compare tier names.
  rank                 smallint not null,
  price_cents          integer  not null check (price_cents >= 0),
  currency             text     not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  display_name         text     not null,

  -- ── Entitlements. NULL = unlimited, 0 = not included. ─────────────────────
  active_tasks         integer check (active_tasks >= 0),
  -- Rolling 30 days, not a calendar month. A calendar reset is gameable at the
  -- boundary and, worse, it cannot answer "when do I get another one" with
  -- anything more useful than a date three weeks out. Rolling lets the meter
  -- name the hour the next message arrives.
  chat_per_month       integer check (chat_per_month >= 0),
  grade_per_week       integer check (grade_per_week >= 0),
  rubrics              integer check (rubrics >= 0),

  -- ── Rate limits. Abuse control, not entitlement. ──────────────────────────
  --
  -- Separate on purpose: an allowance is what the student bought, a rate limit
  -- is what stops a compromised or scripted client burning it in four seconds.
  -- A Pro student has five gradings a week and still cannot fire them all in
  -- one minute, which is the difference between using a product and driving it.
  chat_per_hour        integer check (chat_per_hour >= 0),
  chat_per_day         integer check (chat_per_day >= 0),
  grade_per_hour       integer check (grade_per_hour >= 0),
  breakdown_per_hour   integer check (breakdown_per_hour >= 0),
  breakdown_per_day    integer check (breakdown_per_day >= 0),

  -- ── Feature flags ─────────────────────────────────────────────────────────
  tools_access            text    not null default 'basic'
                            check (tools_access in ('basic', 'expanded', 'all')),
  curriculum_intelligence boolean not null default false,
  advanced_models         boolean not null default false,

  updated_at           timestamptz not null default now()
);

comment on table public.plans is
  'What each tier buys. One source of truth for the gate, the meter and the paywall. NULL = unlimited, 0 = not included.';

insert into public.plans (
  tier, rank, price_cents, display_name,
  active_tasks, chat_per_month, grade_per_week, rubrics,
  chat_per_hour, chat_per_day, grade_per_hour, breakdown_per_hour, breakdown_per_day,
  tools_access, curriculum_intelligence, advanced_models
) values
  ('free', 0,    0, 'Free',
      5,    0,  0,  3,
      0,    0,  0,  6,  20,
   'basic',    false, false),
  ('plus', 1,  799, 'Plus',
     10,   25,  2,  5,
     20,   60,  3, 20,  60,
   'expanded', false, true),
  ('pro',  2, 1499, 'Pro',
   null, null,  5, null,
     60,  300,  3, 40, 150,
   'all',      true,  true)
on conflict (tier) do update set
  rank                    = excluded.rank,
  price_cents             = excluded.price_cents,
  display_name            = excluded.display_name,
  active_tasks            = excluded.active_tasks,
  chat_per_month          = excluded.chat_per_month,
  grade_per_week          = excluded.grade_per_week,
  rubrics                 = excluded.rubrics,
  chat_per_hour           = excluded.chat_per_hour,
  chat_per_day            = excluded.chat_per_day,
  grade_per_hour          = excluded.grade_per_hour,
  breakdown_per_hour      = excluded.breakdown_per_hour,
  breakdown_per_day       = excluded.breakdown_per_day,
  tools_access            = excluded.tools_access,
  curriculum_intelligence = excluded.curriculum_intelligence,
  advanced_models         = excluded.advanced_models,
  updated_at              = now();

-- Read-only reference data. There is no insert, update or delete policy for
-- `authenticated`, and an operation with no matching policy is denied — that is
-- the enforcement, not an oversight. A student cannot rewrite the price list to
-- give themselves ten gradings.
alter table public.plans enable row level security;
revoke all on public.plans from anon, authenticated, public;
grant select on public.plans to authenticated;

drop policy if exists plans_readable on public.plans;
create policy plans_readable on public.plans
  for select to authenticated using (true);

-- ── Pro joins the tier vocabulary ───────────────────────────────────────────
--
-- The constraint is what stops a bad webhook writing tier='premium' and every
-- `tier = 'plus'` comparison silently answering false — which is the same shape
-- as the NULL bug migration 0009 fixed, one level up.
alter table public.entitlements drop constraint if exists entitlements_tier_check;
alter table public.entitlements
  add constraint entitlements_tier_check check (tier in ('free', 'plus', 'pro'));

-- Foreign key to the catalogue, so a tier that has no plan cannot be granted.
alter table public.entitlements drop constraint if exists entitlements_tier_fkey;
alter table public.entitlements
  add constraint entitlements_tier_fkey foreign key (tier) references public.plans(tier);

-- ── Resolving a tier ────────────────────────────────────────────────────────
--
-- One function, used by every gate. It takes a uid, so it stays internal: made
-- callable, it would let any signed-in student read anyone's subscription
-- state. The client-facing version below takes no argument and can only ever
-- answer about the caller.
--
-- An expired row is free, whatever it says. `coalesce` is load-bearing for the
-- same reason it was in 0009: a missing row yields NULL, and `NULL = 'plus'` is
-- NULL rather than false, which collapses the guard it was written to be.
create or replace function public.effective_tier(p_uid uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select e.tier
       from public.entitlements e
      where e.user_id = p_uid
        and e.tier in ('plus', 'pro')
        and (e.expires_at is null or e.expires_at > now())
      limit 1),
    'free');
$$;

revoke all on function public.effective_tier(uuid) from public, anon, authenticated;

-- ── What counts as spent ────────────────────────────────────────────────────
--
-- Generalised from `grading_spend_count` (0033), which proved the argument on
-- the most expensive endpoint and is now the rule for all of them.
--
-- A reservation is taken before the model runs, because that is what stops ten
-- parallel requests each seeing zero used. The refund on failure is a fast path
-- and not a guarantee: it needs the function to survive long enough to run it,
-- and an isolate torn down at the wall clock leaks the row permanently.
--
-- So counting asks whether anything was actually bought:
--
--   * tokens recorded   — Anthropic billed us. Real money, counts forever.
--   * a result exists   — the student has the answer. Counts forever.
--   * younger than 15m  — may still be running. Counts, so a burst cannot all
--                         read zero and race past the limit.
--
-- Under-counting is the only direction that could be abused, so each clause is
-- deliberately generous. The residual leak is a call that billed Anthropic,
-- saved nothing, and whose token write also failed — two independent failures
-- in one request, bounded by the global spend fuse either way.
create or replace function public.ai_spend_count(
  p_uid   uuid,
  p_kind  text,
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
          u.input_tokens is not null
       or u.output_tokens is not null
       or (p_kind = 'grade'
           and exists (select 1 from public.gradings g where g.usage_id = u.id))
       or u.created_at > now() - interval '15 minutes'
     );
$$;

comment on function public.ai_spend_count(uuid, text, interval) is
  'Calls actually spent in a window. A reservation that bought nothing ages out; anything billed or saved counts forever.';

revoke all on function public.ai_spend_count(uuid, text, interval) from public, anon, authenticated;

-- When the oldest call still occupying a window falls out of it — i.e. when the
-- student gets one back. Null when nothing occupies the window at all. Same
-- predicate as the count, so the two can never disagree about which calls are
-- still in it.
create or replace function public.ai_window_resets_at(
  p_uid   uuid,
  p_kind  text,
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
          u.input_tokens is not null
       or u.output_tokens is not null
       or (p_kind = 'grade'
           and exists (select 1 from public.gradings g where g.usage_id = u.id))
       or u.created_at > now() - interval '15 minutes'
     );
$$;

revoke all on function public.ai_window_resets_at(uuid, text, interval) from public, anon, authenticated;

-- ── The gate ────────────────────────────────────────────────────────────────
--
-- Authentication, entitlement, rate limit and the usage slot, in one
-- transaction. Everything downstream of this call costs money; nothing
-- upstream of it does.
--
-- Two kinds of refusal, deliberately distinguished:
--
--   PLAN_UPGRADE_REQUIRED  the plan does not include this at all (limit 0).
--                          The answer is a price list.
--   ALLOWANCE_*            the plan includes it and this window is used up.
--                          The answer is a date, and the meter says which one.
--
-- Collapsing those two into one error is how you end up showing a paying
-- student a paywall for something they already bought.
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
  v_allow_code   text;
  v_used         integer;
  v_hour_limit   integer;
  v_day_limit    integer;
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

  -- The model name is written to a row a human will later read in a bill
  -- reconciliation. Bounded and character-restricted so it can only ever be a
  -- label, never a payload.
  v_model := left(coalesce(p_model, 'unknown'), 64);
  if v_model !~ '^[A-Za-z0-9._-]+$' then
    v_model := 'unknown';
  end if;

  -- ── The fuse, before anything per-user ────────────────────────────────────
  --
  -- Per-user limits cap what one account can spend; this caps what a thousand
  -- fresh accounts can. It is checked first because it is the only control that
  -- still holds when the attacker's answer to a per-user limit is another user.
  select c.int_value into v_global_cap
    from public.app_config c where c.key = 'global_ai_calls_per_hour';
  v_global_cap := coalesce(v_global_cap, 2000);

  select count(*) into v_global_used
    from public.ai_usage u
   where u.created_at > now() - interval '1 hour';

  if v_global_used >= v_global_cap then
    raise exception 'GLOBAL_CAPACITY_REACHED' using errcode = 'Q0004';
  end if;

  -- ── Which plan ────────────────────────────────────────────────────────────
  v_tier := public.effective_tier(v_uid);
  select * into v_plan from public.plans p where p.tier = v_tier;
  if not found then
    -- A tier with no plan row must never fail open. The foreign key on
    -- entitlements makes this unreachable; the guard is here because "should be
    -- unreachable" is how the NULL bug in 0009 got in.
    raise exception 'PLAN_UNKNOWN' using errcode = 'Q0005';
  end if;

  -- ── Entitlement: what the student actually bought ─────────────────────────
  if p_kind = 'chat' then
    v_allow_limit  := v_plan.chat_per_month;
    v_allow_window := interval '30 days';
    v_allow_code   := 'ALLOWANCE_MONTHLY';
  elsif p_kind = 'grade' then
    v_allow_limit  := v_plan.grade_per_week;
    v_allow_window := interval '7 days';
    v_allow_code   := 'ALLOWANCE_WEEKLY';
  else
    -- Plan generation has no allowance window of its own: how much planning a
    -- student may do is expressed as how many assignments they may hold open,
    -- and that is enforced in create_assignment_with_plan, in the transaction
    -- that does the insert. Rate limits below still apply.
    v_allow_limit := null;
  end if;

  -- NULL is unlimited. Zero is not included. The order of these two branches is
  -- the whole convention: checking `used >= limit` first would render "not
  -- included" as "allowance used up" and send a free student a date instead of
  -- a price.
  if v_allow_limit = 0 then
    raise exception 'PLAN_UPGRADE_REQUIRED' using errcode = 'Q0007';
  elsif v_allow_limit is not null then
    v_used := public.ai_spend_count(v_uid, p_kind, v_allow_window);
    if v_used >= v_allow_limit then
      if v_allow_code = 'ALLOWANCE_MONTHLY' then
        raise exception 'ALLOWANCE_MONTHLY' using errcode = 'Q0008';
      else
        raise exception 'ALLOWANCE_WEEKLY' using errcode = 'Q0006';
      end if;
    end if;
  end if;

  -- ── Rate limits: what stops a script ──────────────────────────────────────
  --
  -- Checked after the allowance so the student is told the more useful of the
  -- two truths. Someone with nothing left this week does not need to hear that
  -- they are also going too fast.
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

-- ── The meter ───────────────────────────────────────────────────────────────
--
-- One call the whole app draws from, replacing `grading_allowance()`.
--
-- Dropped rather than kept for compatibility, on purpose. Its contract said
-- `limit_week = 0` means "no ceiling" — the old way of expressing Plus — and
-- under three tiers zero is what Free genuinely has. A client still holding the
-- old reading would show a free student unlimited marking. A missing function
-- is a loud failure; a reversed sentinel is a silent one.
drop function if exists public.grading_allowance();

create or replace function public.my_plan()
returns table (
  tier                    text,
  display_name            text,
  price_cents             integer,
  currency                text,
  expires_at              timestamptz,

  active_tasks_limit      integer,
  active_tasks_used       integer,

  chat_limit_month        integer,
  chat_used_month         integer,
  chat_resets_at          timestamptz,

  grade_limit_week        integer,
  grade_used_week         integer,
  grade_resets_at         timestamptz,

  rubrics_limit           integer,
  rubrics_used            integer,

  tools_access            text,
  curriculum_intelligence boolean,
  advanced_models         boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_tier text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;

  -- No argument, so it can only ever answer about the caller. That is what
  -- makes reading someone else's subscription state impossible here rather
  -- than merely unauthorised.
  v_tier := public.effective_tier(v_uid);

  return query
  select
    p.tier,
    p.display_name,
    p.price_cents,
    p.currency,
    (select e.expires_at from public.entitlements e where e.user_id = v_uid),

    p.active_tasks,
    (select count(*)::integer from public.assignments a
      where a.user_id = v_uid and a.status = 'active'),

    p.chat_per_month,
    public.ai_spend_count(v_uid, 'chat', interval '30 days'),
    public.ai_window_resets_at(v_uid, 'chat', interval '30 days'),

    p.grade_per_week,
    public.ai_spend_count(v_uid, 'grade', interval '7 days'),
    public.ai_window_resets_at(v_uid, 'grade', interval '7 days'),

    p.rubrics,
    (select count(*)::integer from public.rubrics r where r.user_id = v_uid),

    p.tools_access,
    p.curriculum_intelligence,
    p.advanced_models
  from public.plans p
  where p.tier = v_tier;
end;
$$;

comment on function public.my_plan() is
  'The caller''s plan, limits and current usage. NULL limit = unlimited, 0 = not included.';

revoke all on function public.my_plan() from public, anon;
grant execute on function public.my_plan() to authenticated;

-- ── Resolving the caller's own tier ─────────────────────────────────────────
--
-- `effective_tier(uuid)` stays internal because it takes a uid and would
-- otherwise let any signed-in student read anyone's subscription state. But
-- SECURITY INVOKER functions and triggers need the same answer, and they cannot
-- call a function they have no EXECUTE on.
--
-- So: one wrapper that takes no argument. It resolves `auth.uid()` itself,
-- which makes asking about somebody else structurally impossible rather than
-- merely forbidden — the same reason `my_plan()` has no parameters.
create or replace function public.my_tier()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select public.effective_tier((select auth.uid()));
$$;

revoke all on function public.my_tier() from public, anon;
grant execute on function public.my_tier() to authenticated;

-- ── Active assignments ──────────────────────────────────────────────────────
--
-- Free 5, Plus 10, Pro unlimited — and the cap is on *active* work, not work
-- per month. Finishing an assignment frees a slot, so a student in exam season
-- is never walled off by a counter that only goes up.
--
-- SECURITY INVOKER on purpose, unchanged: RLS still applies, and user_id comes
-- from auth.uid() rather than anything the caller sent. The check and the
-- insert share one transaction, which is what makes the limit un-raceable —
-- two concurrent requests cannot both read "4 active" and both proceed.
create or replace function public.create_assignment_with_plan(
  p_title              text,
  p_task_type          text,
  p_deadline           timestamptz,
  p_estimated_minutes  integer,
  p_subtasks           jsonb,
  p_course_id          uuid default null,
  p_assessment_type_id uuid default null,
  p_notes              text default null,
  p_rubric_id          uuid default null,
  p_priority           text default 'normal'
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid           uuid := (select auth.uid());
  v_assignment_id uuid;
  v_item          jsonb;
  v_ordinal       integer := 0;
  v_limit         integer;
  v_active        integer;
  v_priority      text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;

  if jsonb_typeof(p_subtasks) <> 'array' or jsonb_array_length(p_subtasks) = 0 then
    raise exception 'SUBTASKS_REQUIRED' using errcode = '22023';
  end if;

  if jsonb_array_length(p_subtasks) > 20 then
    raise exception 'TOO_MANY_SUBTASKS' using errcode = '22023';
  end if;

  -- Normalise rather than reject: an unknown priority is a client bug, and
  -- refusing to save the student's assignment over it would be the wrong trade.
  v_priority := case when p_priority in ('low','normal','high')
                     then p_priority else 'normal' end;

  select p.active_tasks into v_limit
    from public.plans p where p.tier = public.my_tier();

  -- NULL is unlimited. A plan row that failed to resolve leaves v_limit NULL
  -- too, which would fail open — so the lookup is checked, not assumed.
  if not found then
    raise exception 'PLAN_UNKNOWN' using errcode = 'Q0005';
  end if;

  if v_limit is not null then
    select count(*) into v_active
      from public.assignments a
     where a.user_id = v_uid and a.status = 'active';

    if v_active >= v_limit then
      raise exception 'PLAN_TASK_LIMIT_REACHED' using errcode = 'Q0001';
    end if;
  end if;

  -- Rubric ownership is checked by the assignments_rubric_owned trigger, which
  -- runs inside this transaction. A forged rubric_id aborts the insert rather
  -- than quietly attaching to a stranger's rubric.
  insert into public.assignments (
    user_id, course_id, assessment_type_id, title, notes,
    task_type, deadline, estimated_minutes, rubric_id, priority
  ) values (
    v_uid, p_course_id, p_assessment_type_id, p_title, p_notes,
    p_task_type, p_deadline, p_estimated_minutes, p_rubric_id, v_priority
  ) returning id into v_assignment_id;

  for v_item in select * from jsonb_array_elements(p_subtasks)
  loop
    insert into public.subtasks (
      user_id, assignment_id, rubric_criterion_id,
      title, guidance, ordinal, estimated_minutes, tool_need
    ) values (
      v_uid,
      v_assignment_id,
      nullif(v_item->>'rubric_criterion_id', '')::uuid,
      v_item->>'title',
      nullif(v_item->>'guidance', ''),
      v_ordinal,
      greatest(1, least(1440, coalesce((v_item->>'estimated_minutes')::integer, 30))),
      nullif(v_item->>'tool_need', '')
    );
    v_ordinal := v_ordinal + 1;
  end loop;

  return v_assignment_id;
end;
$$;

revoke all on function public.create_assignment_with_plan(
  text, text, timestamptz, integer, jsonb, uuid, uuid, text, uuid, text) from public, anon;
grant execute on function public.create_assignment_with_plan(
  text, text, timestamptz, integer, jsonb, uuid, uuid, text, uuid, text) to authenticated;

-- ── Saved rubrics ───────────────────────────────────────────────────────────
--
-- Free 3, Plus 5, Pro unlimited, enforced in a BEFORE INSERT trigger so it
-- holds for every write path — the RPC, a direct PostgREST insert, a future
-- import — rather than only the one the app happens to use today. That is the
-- difference between a limit and a suggestion.
--
-- The 200-row ceiling stays underneath as a separate abuse guard. It is not a
-- plan limit and does not mean "upgrade"; it means something is wrong.
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
