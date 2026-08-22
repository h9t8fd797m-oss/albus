-- 0016_seed_curriculum_scaffold
--
-- RECOVERED FROM THE LIVE DATABASE. This was applied on 21 Aug 2026 as
-- `20260821110921_seed_curriculum_scaffold` but never existed as a file, so the
-- repo could not rebuild the database it describes. Written back verbatim.
--
-- It is numbered 0016 rather than slotted between 0007 and 0008 where it
-- originally ran, because applied migrations are append-only — renumbering the
-- ones around it is exactly what CONTRIBUTING forbids. Nothing between 0007 and
-- 0015 depends on this data, so a fresh rebuild in this order is equivalent.
--
-- Every statement is `on conflict do nothing`, so re-running is a no-op. That
-- is what makes it safe to add to a database where it has already run.

insert into public.curricula (code, name) values
  ('IB_DP',   'International Baccalaureate Diploma Programme'),
  ('AP',      'Advanced Placement'),
  ('GENERIC', 'University / other')
on conflict (code) do nothing;

insert into public.course_templates (curriculum_code, code, name) values
  ('IB_DP', 'HIST_HL',   'History HL'),
  ('IB_DP', 'ENG_LL_HL', 'English A: Language and Literature HL'),
  ('GENERIC','GENERIC',  'General course')
on conflict (curriculum_code, code) do nothing;

with t as (select id from public.course_templates where code = 'HIST_HL')
insert into public.assessment_types (course_template_id, code, name, typical_minutes)
select t.id, 'IA', 'Internal Assessment', 1200 from t
on conflict (course_template_id, code) do nothing;

with a as (
  select at.id from public.assessment_types at
  join public.course_templates ct on ct.id = at.course_template_id
  where ct.code = 'HIST_HL' and at.code = 'IA'
)
insert into public.rubric_criteria (assessment_type_id, code, name, marks, guidance, ordinal)
select a.id, v.code, v.name, v.marks, v.guidance, v.ordinal from a,
(values
  ('A','Identifying and evaluating sources', 6,
   'Pick two sources, say why each is useful, and be honest about their limits.', 0),
  ('B','Investigation', 15,
   'The argument itself, built on evidence you can point to.', 1),
  ('C','Reflection', 4,
   'What the research taught you about how historians actually work.', 2)
) as v(code,name,marks,guidance,ordinal)
on conflict (assessment_type_id, code) do nothing;

insert into public.duration_priors (curriculum_code, course_code, task_type, median_minutes, sample_size) values
  ('IB_DP', null, 'essay',       180, 0),
  ('IB_DP', null, 'problem_set',  75, 0),
  ('IB_DP', null, 'reading',      45, 0),
  ('IB_DP', null, 'revision',     60, 0),
  ('GENERIC', null, 'essay',     150, 0),
  ('GENERIC', null, 'problem_set',60, 0),
  ('GENERIC', null, 'reading',    40, 0)
on conflict (curriculum_code, course_code, task_type) do nothing;
