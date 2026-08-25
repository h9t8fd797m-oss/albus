-- 0029_subtask_tool_need
--
-- What each step needs doing to it, so the app can pick tools for it.
--
-- The tool suggestions on a step used to come from keyword-matching its title
-- against fourteen hard-coded tools, so every essay step offered the same two
-- and 211 of the 225 tools in the catalogue were unreachable. The planner
-- already knows why it wrote a step; recording that is what lets the app choose
-- from the whole catalogue without a second model call.
--
-- Constrained to the generated vocabulary rather than left free text: the value
-- is a lookup key into the tool catalogue, and a need no tool serves shows the
-- student nothing while looking like it worked.

alter table public.subtasks
  add column tool_need text
  check (tool_need is null or tool_need in ('source_research', 'reading', 'note_taking', 'outlining', 'drafting', 'editing', 'proofreading', 'citation', 'feedback', 'worked_examples', 'problem_practice', 'error_analysis', 'computation', 'graphing', 'data_analysis', 'simulation', 'diagramming', 'translation', 'vocabulary', 'listening_speaking', 'memorisation', 'spaced_practice', 'self_testing', 'coding', 'debugging', 'presentation', 'design', 'planning', 'focus', 'wellbeing'));

comment on column public.subtasks.tool_need is
  'Generated vocabulary — see scripts/tools/capabilities.py. Nullable: a step
   that needs nothing in particular is normal.';

-- Same signature, so this replaces rather than overloads. A different parameter
-- list would have created a second function and left the old one being called.
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
