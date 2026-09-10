-- 20260909180000_drop_curriculum_content
--
-- Albus is a study-hour planner for any student, not an IB product. The
-- curriculum corpus is withdrawn: nothing seeds it, no Edge Function reads it,
-- and grading resolves a rubric the student saved or marks blind.
--
-- WHAT THIS DROPS. `syllabus_topics` and `assessment_objectives` existed only
-- to hold reference content. Nothing in the schema points at them -- no
-- user-owned column carries a foreign key into either -- so dropping them can
-- take no student data with it.
--
-- WHAT THIS DELIBERATELY KEEPS.
--
-- `curricula`, `course_templates`, `assessment_types` and `rubric_criteria`
-- stay, empty. User-owned rows point into all four: `courses.course_template_id`
-- and `assignments.assessment_type_id` are `on delete set null`, and
-- `subtasks.rubric_criterion_id` references `rubric_criteria`. Dropping them
-- would mean dropping those columns first -- surgery on student data to remove
-- tables that cost nothing while empty. They also remain the mechanism 0018
-- described: a saved rubric can be seeded from a template, whoever writes the
-- template later.
--
-- `profiles.curriculum_code` stays and keeps its foreign key. The client no
-- longer writes it, so it stays null, which is exactly true: no curriculum.
--
-- `profiles.exam_session`, `profiles.target_points`, `courses.level` and
-- `courses.target_grade` stay. They belong to a migration that has NOT been
-- deployed, and `scripts/deploy-2026-09-05.sql` refuses to record that
-- migration unless it finds those columns with those types. Dropping them here
-- would break the pending production deploy. The client stops writing them and
-- sends null instead; retiring the columns is a later migration, after the
-- deploy has run.

begin;

drop table if exists public.syllabus_topics;
drop table if exists public.assessment_objectives;

do $$
begin
  if to_regclass('public.syllabus_topics') is not null
     or to_regclass('public.assessment_objectives') is not null then
    raise exception 'a curriculum content table survived the drop';
  end if;

  -- The tables student data points at must still be here.
  if to_regclass('public.curricula') is null
     or to_regclass('public.course_templates') is null
     or to_regclass('public.assessment_types') is null
     or to_regclass('public.rubric_criteria') is null then
    raise exception 'a table student rows reference was dropped';
  end if;

  -- And the pending deploy's preconditions must be untouched.
  if to_regprocedure('public.set_ib_context(text,smallint,boolean,boolean)') is null
     or to_regprocedure('public.create_course(text,text,text,text,smallint)') is null then
    raise exception 'a routine the pending production deploy verifies is missing';
  end if;
end $$;

commit;
