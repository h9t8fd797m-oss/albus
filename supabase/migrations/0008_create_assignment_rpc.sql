-- 0008_create_assignment_rpc
-- Atomic creation of an assignment plus its generated steps.
--
-- Why an RPC rather than several inserts from the Edge Function:
--   * Atomicity — a half-written plan (assignment with no steps) is worse
--     than no plan at all.
--   * No TOCTOU on the quota. Checking the free-tier limit in the Edge
--     Function and inserting a moment later leaves a window where two
--     concurrent requests both pass the check. Here the check and the
--     insert share one transaction.
--
-- SECURITY INVOKER on purpose: RLS still applies, and user_id is taken from
-- auth.uid() rather than anything the caller sent. A caller cannot create
-- work owned by someone else even if this function had a bug.

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

  -- Free tier caps ACTIVE plans, not plans per month: finishing an
  -- assignment frees a slot, so a student in exam season is never walled off.
  select e.tier, e.expires_at into v_tier, v_expires
    from public.entitlements e where e.user_id = v_uid;

  if not (v_tier = 'plus' and (v_expires is null or v_expires > now())) then
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

revoke all on function public.create_assignment_with_plan(
  text, text, timestamptz, integer, jsonb, uuid, uuid, text) from public, anon;
grant execute on function public.create_assignment_with_plan(
  text, text, timestamptz, integer, jsonb, uuid, uuid, text) to authenticated;
