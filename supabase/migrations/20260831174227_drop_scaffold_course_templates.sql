-- Remove the two superseded curriculum scaffold rows. Real IB templates now
-- use IB_DP_HISTORY and IB_DP_LANG_A_LANGLIT; these old codes are unreachable
-- from the client and duplicate those subjects.
--
-- `courses.course_template_id` is ON DELETE SET NULL. That is useful for a
-- genuinely retired template, but silently detaching a real student's course
-- here would hide an incorrect assumption. Refuse the migration if either row
-- gained a user reference after this cleanup was prepared.
do $$
declare
  v_linked_courses bigint;
begin
  select count(*)
    into v_linked_courses
    from public.courses c
    join public.course_templates t on t.id = c.course_template_id
   where t.curriculum_code = 'IB_DP'
     and t.code in ('HIST_HL', 'ENG_LL_HL');

  if v_linked_courses > 0 then
    raise exception 'SCAFFOLD_COURSE_TEMPLATES_IN_USE: % course row(s) still reference HIST_HL or ENG_LL_HL',
      v_linked_courses
      using errcode = '23503';
  end if;

  -- assessment_types, syllabus_topics, and assessment_objectives all declare
  -- ON DELETE CASCADE. HIST_HL's obsolete IA and criteria leave with it.
  delete from public.course_templates
   where curriculum_code = 'IB_DP'
     and code in ('HIST_HL', 'ENG_LL_HL');

  if exists (
    select 1 from public.course_templates
     where curriculum_code = 'IB_DP'
       and code in ('HIST_HL', 'ENG_LL_HL')
  ) then
    raise exception 'SCAFFOLD_COURSE_TEMPLATE_DELETE_INCOMPLETE';
  end if;
end;
$$;
