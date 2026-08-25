-- 0028_create_course_rpc
--
-- Creating a subject and linking it to its specification, in one statement.
--
-- `courses.course_template_id` has existed since 0004 and nothing ever set it,
-- so the server knew a student took "Biology" and nothing about how Biology is
-- assessed. Ask Albus could name the subject and not one fact about it. The
-- client holds the specification code (`IB_DP_BIOLOGY`), the server holds the
-- uuid, and that gap is what this closes.
--
-- A code rather than the uuid, for the same reason `breakdown` takes codes: the
-- device has the subject list compiled in and must be able to offer it before it
-- has ever reached the network, so it cannot know an id Postgres generated.
--
-- `security invoker`, so the insert is subject to the same RLS as any other
-- write to `courses`. `user_id` comes from `auth.uid()` and is not a parameter —
-- the row cannot be attributed to another student even if this code were wrong,
-- and the restrictive owner policy on `courses` would reject it regardless.
create function public.create_course(
  p_display_name text,
  p_color_key    text default 'violet',
  p_template_code text default null
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_template uuid;
  v_id       uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  -- An unknown code links nothing rather than failing: a subject the student
  -- can see and use, minus the grounding, beats an error on the one screen
  -- where they are trying to tell us what they study.
  if p_template_code is not null then
    select ct.id into v_template
    from public.course_templates ct
    where ct.code = p_template_code
    limit 1;
  end if;

  insert into public.courses (user_id, course_template_id, display_name, color_key)
  values (v_uid, v_template, p_display_name, coalesce(p_color_key, 'violet'))
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.create_course(text, text, text) from public, anon;
grant execute on function public.create_course(text, text, text) to authenticated;

do $$
begin
  if has_function_privilege('anon', 'public.create_course(text, text, text)', 'EXECUTE') then
    raise exception 'anon must not execute create_course';
  end if;
end $$;
