begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;
select plan(3);
select ok(exists(select 1 from public.syllabus_topics), 'syllabus seed is loaded');
select is((select count(*) from (
  select course_template_id, ordinal from public.syllabus_topics
  group by course_template_id, ordinal having count(*) > 1
) duplicates), 0::bigint, 'syllabus topic ordinals are unique per template');
select is((select count(*) from (
  select course_template_id from public.syllabus_topics
  group by course_template_id having count(*) = 1
) incomplete), 0::bigint, 'no subject has an incomplete one-topic outline');
select * from finish();
rollback;
