-- 0009_fix_quota_null_guard
--
-- Fixes a silent bypass of the free-tier cap.
--
-- Only a purchase creates an entitlements row, so for every free user the
-- lookup returned no row and v_tier was NULL. In SQL, NULL = 'plus' is NULL
-- rather than false, so:
--
--     not (NULL and (...))  ->  NULL
--     if NULL then ...      ->  branch not taken
--
-- The quota block was therefore skipped for exactly the users it exists to
-- limit. Caught by a probe asserting the fourth plan is refused; it wasn't.
--
-- Fix: fold NULL to false explicitly before the boolean is used. Absence of
-- an entitlements row now means "free", which is what it always meant.

create or replace function public.create_assignment_with_plan(
  p_title              text,
  p_task_type          text,
  p_deadline           timestamptz,
  p_estimated_minutes  integer,
  p_subtasks           jsonb,
  p_course_id          uuid default null,
  p_assessment_type_id uuid default null,
  p_notes              text default null
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
  v_tier          text;
  v_expires       timestamptz;
  v_is_plus       boolean;
  v_active        integer;
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

  select e.tier, e.expires_at into v_tier, v_expires
    from public.entitlements e where e.user_id = v_uid;

  -- coalesce() is load-bearing: without it a missing row yields NULL and the
  -- whole guard collapses to a no-op.
  v_is_plus := coalesce(v_tier = 'plus', false)
               and (v_expires is null or v_expires > now());

  if not v_is_plus then
    select count(*) into v_active
      from public.assignments a
     where a.user_id = v_uid and a.status = 'active';

    if v_active >= 3 then
      raise exception 'FREE_PLAN_LIMIT_REACHED' using errcode = 'P0001';
    end if;
  end if;

  insert into public.assignments (
    user_id, course_id, assessment_type_id, title, notes,
    task_type, deadline, estimated_minutes
  ) values (
    v_uid, p_course_id, p_assessment_type_id, p_title, p_notes,
    p_task_type, p_deadline, p_estimated_minutes
  ) returning id into v_assignment_id;

  for v_item in select * from jsonb_array_elements(p_subtasks)
  loop
    insert into public.subtasks (
      user_id, assignment_id, rubric_criterion_id,
      title, guidance, ordinal, estimated_minutes
    ) values (
      v_uid,
      v_assignment_id,
      nullif(v_item->>'rubric_criterion_id', '')::uuid,
      v_item->>'title',
      nullif(v_item->>'guidance', ''),
      v_ordinal,
      greatest(1, least(1440, coalesce((v_item->>'estimated_minutes')::integer, 30)))
    );
    v_ordinal := v_ordinal + 1;
  end loop;

  return v_assignment_id;
end;
$$;
