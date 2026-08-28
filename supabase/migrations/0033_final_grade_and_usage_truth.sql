-- 0033 — a grading carries a real final grade, and a reservation that bought
-- nothing stops counting against the student.
--
-- Applied by hand and verified against pg_proc. The CI deploy workflow has no
-- secrets and never runs, so this repo is not the source of truth for this
-- database — see docs/plan-2026-08-25.md.
--
-- ── Two problems, both found by reading live rows rather than tests ──────────
--
-- **1. There was never a final grade.** `overall_marks` / `total_marks` is the
-- rubric's raw total: 0/32 for a four-strand MYP rubric, 36/100 for one marked
-- out of a hundred. Neither is the grade the student's course would actually
-- put on the work. The letter or band existed only inside the prose — one live
-- row opens "36/100. On a standard letter scale that is an F" — so the one
-- number a student came for was unparseable, unsortable and unstorable.
--
-- **2. A failed grading stayed charged.** The slot is reserved before the model
-- runs, which is correct: it is what stops ten parallel requests each seeing
-- zero used. The refund on failure is not enough on its own, because it needs
-- the function to survive long enough to run it — an isolate torn down at the
-- wall clock, a crash, or any failure predating the refund leaks the row
-- permanently. Live proof: user 058d0d9e holds two `ai_usage` rows for
-- kind='grade' and exactly one `gradings` row. The orphan has null tokens and
-- produced nothing, and it counts against that student forever.
--
-- So counting stops asking "is there a row" and starts asking "was anything
-- actually bought". A reservation counts when Anthropic billed us (tokens
-- recorded), when the student got a result (a grading points at it), or when it
-- is young enough to still be in flight. Everything else ages out by itself,
-- which is what makes this self-healing rather than a cleanup script that has
-- to be re-run every time the runtime kills a worker.

-- ── The final grade ──────────────────────────────────────────────────────────
--
-- Two columns, not one. The label alone ("4", "B+", "36/100") is what goes on
-- the card in 48pt; the note is the sentence that stops it being a bare number
-- the student cannot argue with — which band it sits in, how far the next one
-- is. Short by construction; both are bounded in the normaliser as well.
alter table public.gradings
  add column if not exists grade_label text,
  add column if not exists grade_note  text;

comment on column public.gradings.grade_label is
  'The final grade in the scale the student said their course uses. Null for a blind reading, always.';
comment on column public.gradings.grade_note is
  'One line on how that grade was reached. Never a substitute for the criteria.';

-- What the student was marking. Without it a history list reads as five rows of
-- "26 Aug" — the work itself is deliberately never stored, so the title is the
-- only thing that can identify a grading after the fact.
alter table public.gradings
  add column if not exists work_title text;

-- ── Which reservation bought this grading ────────────────────────────────────
--
-- The link that makes "was anything bought" answerable exactly rather than by a
-- timestamp heuristic. Nullable: every row written before this existed has no
-- reservation to point at, and those rows are old enough that the age check
-- below has already stopped counting them.
--
-- No foreign key on purpose. `ai_usage` is the billing log and rows are deleted
-- from it by the refund path; a cascade would then delete the student's
-- grading, and a real result must outlive the accounting for it.
alter table public.gradings
  add column if not exists usage_id uuid;

create index if not exists gradings_usage_idx
  on public.gradings (usage_id) where usage_id is not null;

-- ── What counts as spent ─────────────────────────────────────────────────────
--
-- One function, called by both the gate and the meter.
--
-- 0031 argued the opposite — that the meter should duplicate the gate's SQL so
-- that no refactor of a shared helper could open a bypass. That reasoning holds
-- for the *limits* and they are still duplicated. It does not hold for the
-- predicate: a meter counting differently from the gate is exactly the bug
-- being fixed here, where the screen said "3 left this week" directly above
-- "that's this week's markings used".
--
-- Under-counting is the only direction that could be abused, so each clause is
-- deliberately generous about what counts:
--
--   * tokens recorded  — Anthropic billed us. Real money, counts forever.
--   * a grading points at it — the student has the result. Counts forever.
--   * younger than the grace — may still be running. Counts, so a burst of
--     parallel requests cannot all read zero and race past the limit.
--
-- The residual leak is a call that billed Anthropic, saved nothing, and whose
-- token write also failed. That needs two independent failures in one request
-- and is bounded by the global spend fuse either way.
create or replace function public.grading_spend_count(
  p_uid   uuid,
  p_since interval
) returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select count(*)::integer
    from public.ai_usage u
   where u.user_id = p_uid
     and u.kind = 'grade'
     and u.created_at > now() - p_since
     and (
          u.input_tokens is not null
       or u.output_tokens is not null
       or exists (select 1 from public.gradings g where g.usage_id = u.id)
       or u.created_at > now() - interval '15 minutes'
     );
$$;

comment on function public.grading_spend_count(uuid, interval) is
  'Gradings actually spent in a window. A reservation that bought nothing ages out; anything billed or saved counts forever.';

-- Internal only. It takes a uid as an argument, so leaving it callable would
-- let any signed-in student read any other student's usage.
revoke all on function public.grading_spend_count(uuid, interval) from public, anon, authenticated;

-- When the oldest call still occupying a window falls out of it — i.e. when the
-- student gets one back. Null when nothing is occupying the window at all.
--
-- Always answered, whether or not the student is at the limit; only the screen
-- knows whether the number is worth showing. Same predicate as the count, so
-- the two can never disagree about which calls are still in the window.
create or replace function public.grading_window_resets_at(
  p_uid   uuid,
  p_since interval
) returns timestamptz
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select min(u.created_at) + p_since
    from public.ai_usage u
   where u.user_id = p_uid
     and u.kind = 'grade'
     and u.created_at > now() - p_since
     and (
          u.input_tokens is not null
       or u.output_tokens is not null
       or exists (select 1 from public.gradings g where g.usage_id = u.id)
       or u.created_at > now() - interval '15 minutes'
     );
$$;

revoke all on function public.grading_window_resets_at(uuid, interval) from public, anon, authenticated;

-- ── The gate ─────────────────────────────────────────────────────────────────
--
-- Unchanged in every respect except how grade rows are counted. chat and
-- breakdown keep counting rows: their limits are an order of magnitude looser,
-- their calls are seconds rather than a minute, and changing them is not what
-- this migration is for.
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
    v_hour_limit := case when v_is_plus then  6 else 2 end;
    v_day_limit  := case when v_is_plus then 20 else 2 end;
    v_week_limit := case when v_is_plus then  0 else 5 end;  -- 0 = no weekly cap
  else
    v_hour_limit := case when v_is_plus then  30 else  8  end;
    v_day_limit  := case when v_is_plus then 150 else 25  end;
  end if;

  if p_kind = 'grade' then
    v_hour := public.grading_spend_count(v_uid, interval '1 hour');
    v_day  := public.grading_spend_count(v_uid, interval '1 day');
  else
    select count(*) into v_hour from public.ai_usage u
     where u.user_id = v_uid and u.kind = p_kind
       and u.created_at > now() - interval '1 hour';
    select count(*) into v_day from public.ai_usage u
     where u.user_id = v_uid and u.kind = p_kind
       and u.created_at > now() - interval '1 day';
  end if;

  if v_hour >= v_hour_limit then
    raise exception 'RATE_LIMIT_HOURLY' using errcode = 'Q0002';
  end if;
  if v_day >= v_day_limit then
    raise exception 'RATE_LIMIT_DAILY' using errcode = 'Q0003';
  end if;

  if coalesce(v_week_limit, 0) > 0 then
    v_week := public.grading_spend_count(v_uid, interval '7 days');
    if v_week >= v_week_limit then
      raise exception 'RATE_LIMIT_WEEKLY' using errcode = 'Q0006';
    end if;
  end if;

  insert into public.ai_usage (user_id, kind, model)
  values (v_uid, p_kind, v_model)
  returning id into v_id;

  return v_id;
end;
$$;

-- ── The meter ────────────────────────────────────────────────────────────────
--
-- Now reports all three windows and when each one frees up.
--
-- The screen used to draw five dots and say "3 left this week" while the thing
-- that actually stopped the student was a daily cap of two. Both numbers were
-- individually true and together they were a lie, so the client is now given
-- everything it needs to name the window that is actually binding — and to say
-- when it lifts, which is the only part a student can do anything with.
drop function if exists public.grading_allowance();

create function public.grading_allowance()
returns table (
  used_hour      integer, limit_hour integer,
  used_day       integer, limit_day  integer,
  used_week      integer, limit_week integer,
  hour_resets_at timestamptz,
  day_resets_at  timestamptz,
  week_resets_at timestamptz,
  is_plus        boolean
)
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

  -- Limits duplicated from the gate, still deliberately. If these drift the
  -- meter is wrong and nothing is bypassed, which is the correct direction for
  -- the two to fail in. The *counting* is shared, because a meter that counts
  -- differently from the gate is the bug this migration exists to fix.
  return query
  select
    public.grading_spend_count(v_uid, interval '1 hour'),
    case when v_plus then  6 else 2 end,
    public.grading_spend_count(v_uid, interval '1 day'),
    case when v_plus then 20 else 2 end,
    public.grading_spend_count(v_uid, interval '7 days'),
    case when v_plus then  0 else 5 end,
    public.grading_window_resets_at(v_uid, interval '1 hour'),
    public.grading_window_resets_at(v_uid, interval '1 day'),
    public.grading_window_resets_at(v_uid, interval '7 days'),
    v_plus;
end;
$$;

revoke all on function public.grading_allowance() from public, anon;
grant execute on function public.grading_allowance() to authenticated;
