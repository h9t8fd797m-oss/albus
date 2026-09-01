-- IB student context: which year, which level, what they are aiming for.
--
-- The server knew a student took "Biology" and nothing about whether that is
-- Higher or Standard level, which year of the Diploma they are in, or what
-- grade they want. All three change how a task should be planned — an HL
-- Biology IA in DP2 is not the same piece of work as an SL one in DP1 — so
-- until now the planner has been reasoning without them.
--
-- **Why the exam session and not the DP year.** The obvious column is
-- `dp_year integer check (dp_year in (1, 2))`. It is wrong. "DP1" is true for
-- about twelve months and then silently false forever, with no event anywhere
-- to correct it: the student does not re-onboard, and nothing else knows the
-- academic year rolled over. A stored `1` becomes a lie that every generated
-- prompt then repeats. The exam session is the durable fact — a student sitting
-- May 2027 is sitting May 2027 in perpetuity — so that is what is stored, and
-- the DP year is derived from it. Onboarding still *asks* for DP1/DP2, because
-- that is what a student knows about themselves; the conversion happens once,
-- at the point of writing.

-- ---------------------------------------------------------------------------
-- 1. Student-level context

alter table public.profiles
  -- 'YYYY-MM' where MM is 05 or 11. The IB has exactly two sessions a year.
  add column exam_session text
    check (exam_session is null or exam_session ~ '^[0-9]{4}-(05|11)$'),
  -- The Diploma total, out of 45. Deliberately named so it cannot be confused
  -- with the per-subject 1-7 grade added to `courses` below.
  add column target_points smallint
    check (target_points is null or target_points between 1 and 45);

comment on column public.profiles.exam_session is
  'IB examination session as YYYY-MM (05 or 11). Durable; the DP year is derived from this and the current date, never stored.';

-- Derive the year rather than storing it. Returns 1 or 2 during the programme,
-- and null outside it — a student whose session has passed is not "DP3", and
-- inventing a number there would be worse than admitting we do not know.
create or replace function public.dp_year_for_session(
  p_exam_session text,
  p_now timestamptz default now()
) returns smallint
language sql
immutable
set search_path = ''
as $$
  select case
    when p_exam_session is null then null
    when p_exam_session !~ '^[0-9]{4}-(05|11)$' then null
    else (
      with s as (
        select make_date(
                 split_part(p_exam_session, '-', 1)::integer,
                 split_part(p_exam_session, '-', 2)::integer,
                 1
               ) as exam_month
      )
      select case
        -- Two years of programme, counted back from the exam month.
        when p_now::date > s.exam_month then null
        when p_now::date > (s.exam_month - interval '12 months')::date then 2::smallint
        when p_now::date > (s.exam_month - interval '24 months')::date then 1::smallint
        else null
      end
      from s
    )
  end;
$$;

comment on function public.dp_year_for_session(text, timestamptz) is
  'DP1 or DP2 derived from the exam session and the current date; null before the programme starts or after the session has passed.';

revoke all on function public.dp_year_for_session(text, timestamptz)
  from public, anon;
grant execute on function public.dp_year_for_session(text, timestamptz)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Subject-level context

alter table public.courses
  -- Constrained, not free text: this value reaches generated prompts, and
  -- `curriculum_code` was bound to a foreign key after a prompt-injection
  -- issue on exactly this class of column. Nullable with no default on
  -- purpose — Theory of Knowledge and the Extended Essay genuinely have no
  -- level, and defaulting to 'SL' would be a fact Albus invented and then
  -- reasoned from.
  add column level text check (level is null or level in ('HL', 'SL')),
  add column target_grade smallint
    check (target_grade is null or target_grade between 1 and 7);

comment on column public.courses.level is
  'HL or SL for IB subjects that have one. Null for TOK, the Extended Essay, and any subject where the level is genuinely unknown.';

-- ---------------------------------------------------------------------------
-- 3. Writing that context

-- Adding parameters creates a *second* function rather than replacing the
-- existing one: PostgreSQL overloads on signature, so the old three-argument
-- version would stay callable and separately granted. Create the new one,
-- then drop the old, then re-apply privileges to the new signature — the same
-- pattern `check_and_record_ai_usage` used when it gained its user-id
-- parameter.
create or replace function public.create_course(
  p_display_name text,
  p_color_key text default 'violet',
  p_template_code text default null,
  p_level text default null,
  p_target_grade smallint default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_template uuid;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  -- Reject at the boundary with a name the client can act on, rather than
  -- letting the column constraint produce a generic 23514 from a layer the
  -- caller cannot see.
  if p_level is not null and p_level not in ('HL', 'SL') then
    raise exception 'INVALID_LEVEL' using errcode = '22023';
  end if;
  if p_target_grade is not null and (p_target_grade < 1 or p_target_grade > 7) then
    raise exception 'INVALID_TARGET_GRADE' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('albus:courses:' || v_uid::text, 0));
  if (select count(*) from public.courses c where c.user_id = v_uid) >= 50 then
    raise exception 'COURSE_CEILING' using errcode = 'Q0015';
  end if;

  if p_template_code is not null then
    select ct.id into v_template
      from public.course_templates ct
     where ct.code = left(p_template_code, 80)
     limit 1;
  end if;

  insert into public.courses
    (user_id, course_template_id, display_name, color_key, level, target_grade)
  values
    (v_uid, v_template, p_display_name, coalesce(p_color_key, 'violet'),
     p_level, p_target_grade)
  returning id into v_id;
  return v_id;
end;
$$;

drop function public.create_course(text, text, text);

revoke all on function public.create_course(text, text, text, text, smallint)
  from public, anon;
grant execute on function public.create_course(text, text, text, text, smallint)
  to authenticated;

-- A student changes from HL to SL in the first term more often than anyone
-- would like, and deleting the subject to re-add it would take its assignments
-- with it. `security invoker`, so the owner policy on `courses` decides whether
-- this row is writable — the same control that protects every other write, not
-- a second one that could drift away from it.
create or replace function public.update_course(
  p_course_id uuid,
  p_level text default null,
  p_target_grade smallint default null,
  p_clear_level boolean default false,
  p_clear_target_grade boolean default false
) returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_changed integer;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  if p_course_id is null then
    raise exception 'COURSE_ID_REQUIRED' using errcode = '22023';
  end if;
  if p_level is not null and p_level not in ('HL', 'SL') then
    raise exception 'INVALID_LEVEL' using errcode = '22023';
  end if;
  if p_target_grade is not null and (p_target_grade < 1 or p_target_grade > 7) then
    raise exception 'INVALID_TARGET_GRADE' using errcode = '22023';
  end if;

  -- Explicit clear flags rather than "null means clear". A partial update that
  -- omits target_grade must not silently erase it, and a student who genuinely
  -- wants no level must still be able to say so.
  update public.courses c
     set level = case when p_clear_level then null
                      when p_level is not null then p_level
                      else c.level end,
         target_grade = case when p_clear_target_grade then null
                             when p_target_grade is not null then p_target_grade
                             else c.target_grade end,
         updated_at = now()
   where c.id = p_course_id
     and c.user_id = v_uid;

  get diagnostics v_changed = row_count;
  return v_changed = 1;
end;
$$;

revoke all on function public.update_course(uuid, text, smallint, boolean, boolean)
  from public, anon;
grant execute on function public.update_course(uuid, text, smallint, boolean, boolean)
  to authenticated;

-- `profiles` is written through this rather than a raw update, for the same
-- reason the course path is: the values are validated once, server-side, where
-- a repackaged client cannot skip the check.
create or replace function public.set_ib_context(
  p_exam_session text default null,
  p_target_points smallint default null,
  p_clear_exam_session boolean default false,
  p_clear_target_points boolean default false
) returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_changed integer;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  if p_exam_session is not null and p_exam_session !~ '^[0-9]{4}-(05|11)$' then
    raise exception 'INVALID_EXAM_SESSION' using errcode = '22023';
  end if;
  if p_target_points is not null and (p_target_points < 1 or p_target_points > 45) then
    raise exception 'INVALID_TARGET_POINTS' using errcode = '22023';
  end if;

  update public.profiles p
     set exam_session = case when p_clear_exam_session then null
                             when p_exam_session is not null then p_exam_session
                             else p.exam_session end,
         target_points = case when p_clear_target_points then null
                              when p_target_points is not null then p_target_points
                              else p.target_points end,
         updated_at = now()
   where p.id = v_uid;

  get diagnostics v_changed = row_count;
  return v_changed = 1;
end;
$$;

revoke all on function public.set_ib_context(text, smallint, boolean, boolean)
  from public, anon;
grant execute on function public.set_ib_context(text, smallint, boolean, boolean)
  to authenticated;
