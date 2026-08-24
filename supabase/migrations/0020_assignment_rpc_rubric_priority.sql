-- 0020_assignment_rpc_rubric_priority
--
-- Teach create_assignment_with_plan about the two things the add flow now asks
-- for: the student's own rubric, and priority.
--
-- The old signature is dropped rather than replaced. `create or replace` with a
-- different parameter list creates an *overload*, and two functions reachable by
-- the same call is an ambiguity waiting for the first request that omits an
-- argument. One function, one signature.

drop function if exists public.create_assignment_with_plan(
  text, text, timestamptz, integer, jsonb, uuid, uuid, text
);

create function public.create_assignment_with_plan(
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
  v_tier          text;
  v_expires       timestamptz;
  v_is_plus       boolean;
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

  select e.tier, e.expires_at into v_tier, v_expires
    from public.entitlements e where e.user_id = v_uid;

  v_is_plus := coalesce(v_tier = 'plus', false)
               and (v_expires is null or v_expires > now());

  if not v_is_plus then
    select count(*) into v_active
      from public.assignments a
     where a.user_id = v_uid and a.status = 'active';

    if v_active >= 3 then
      raise exception 'FREE_PLAN_LIMIT_REACHED' using errcode = 'Q0001';
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
  text, text, timestamptz, integer, jsonb, uuid, uuid, text, uuid, text
) from public, anon;

grant execute on function public.create_assignment_with_plan(
  text, text, timestamptz, integer, jsonb, uuid, uuid, text, uuid, text
) to authenticated;
