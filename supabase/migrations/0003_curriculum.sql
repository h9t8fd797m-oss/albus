-- 0003_curriculum
-- Global reference data: curricula, course templates, assessments, rubrics.
-- Readable by every signed-in user; writable only by the service role
-- (which bypasses RLS). No write policy exists for `authenticated`, and an
-- operation with no matching policy is denied — that is the enforcement.

create table public.curricula (
  code        text primary key,              -- 'IB_DP', 'AP', 'GENERIC'
  name        text not null,
  created_at  timestamptz not null default now()
);

create table public.course_templates (
  id              uuid primary key default gen_random_uuid(),
  curriculum_code text not null references public.curricula(code) on delete cascade,
  code            text not null,             -- 'HIST_HL'
  name            text not null,             -- 'History HL'
  created_at      timestamptz not null default now(),
  unique (curriculum_code, code)
);

create table public.assessment_types (
  id                 uuid primary key default gen_random_uuid(),
  course_template_id uuid not null references public.course_templates(id) on delete cascade,
  code               text not null,          -- 'IA', 'PAPER_1'
  name               text not null,
  typical_minutes    integer check (typical_minutes > 0),
  created_at         timestamptz not null default now(),
  unique (course_template_id, code)
);

create table public.rubric_criteria (
  id                 uuid primary key default gen_random_uuid(),
  assessment_type_id uuid not null references public.assessment_types(id) on delete cascade,
  code               text not null,          -- 'A'
  name               text not null,          -- 'Analysis'
  marks              integer check (marks >= 0),
  guidance           text,                   -- OUR paraphrase, never published descriptor text
  ordinal            integer not null default 0,
  created_at         timestamptz not null default now(),
  unique (assessment_type_id, code)
);

create table public.syllabus_topics (
  id                 uuid primary key default gen_random_uuid(),
  course_template_id uuid not null references public.course_templates(id) on delete cascade,
  name               text not null,
  ordinal            integer not null default 0,
  created_at         timestamptz not null default now()
);

-- Population priors: median minutes by (curriculum, course, task type).
-- Shipped to clients as cold-start defaults for the local estimator.
create table public.duration_priors (
  id               uuid primary key default gen_random_uuid(),
  curriculum_code  text not null references public.curricula(code) on delete cascade,
  course_code      text,
  task_type        text not null,
  median_minutes   integer not null check (median_minutes > 0),
  sample_size      integer not null default 0 check (sample_size >= 0),
  updated_at       timestamptz not null default now(),
  unique (curriculum_code, course_code, task_type)
);

create index course_templates_curriculum_idx on public.course_templates(curriculum_code);
create index assessment_types_template_idx    on public.assessment_types(course_template_id);
create index rubric_criteria_assessment_idx   on public.rubric_criteria(assessment_type_id);
create index syllabus_topics_template_idx     on public.syllabus_topics(course_template_id);

do $$
declare t text;
begin
  foreach t in array array[
    'curricula','course_templates','assessment_types',
    'rubric_criteria','syllabus_topics','duration_priors'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, public', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (true)',
      t || '_read_all', t
    );
  end loop;
end $$;
