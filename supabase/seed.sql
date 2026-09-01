-- supabase/seed.sql
-- Minimal curriculum scaffolding so a fresh database is usable immediately.
-- The real corpus (≈18 subjects) is authored in build-plan P2.
--
-- IMPORTANT: `guidance` must be OUR OWN paraphrase. Never paste published
-- IB or College Board descriptor text into this file.

insert into public.curricula (code, name) values
  ('IB_DP',   'International Baccalaureate Diploma Programme'),
  ('AP',      'Advanced Placement'),
  ('GENERIC', 'University / other')
on conflict (code) do nothing;

insert into public.course_templates (curriculum_code, code, name) values
  ('GENERIC','GENERIC',  'General course')
on conflict (curriculum_code, code) do nothing;

-- Cold-start priors for the local estimator. Replaced by fitted values
-- once completion_logs has volume.
insert into public.duration_priors (curriculum_code, course_code, task_type, median_minutes, sample_size) values
  ('IB_DP', null, 'essay',       180, 0),
  ('IB_DP', null, 'problem_set',  75, 0),
  ('IB_DP', null, 'reading',      45, 0),
  ('IB_DP', null, 'revision',     60, 0),
  ('GENERIC', null, 'essay',     150, 0),
  ('GENERIC', null, 'problem_set',60, 0),
  ('GENERIC', null, 'reading',    40, 0)
on conflict (curriculum_code, course_code, task_type) do nothing;
