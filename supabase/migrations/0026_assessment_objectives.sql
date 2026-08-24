-- 0026_assessment_objectives
--
-- Assessment objectives — AO1/AO2/AO3 and their weightings.
--
-- Why a new table rather than reusing `rubric_criteria`: they are different
-- things. A criterion belongs to one assessment and carries marks (IB's
-- "Criterion B: Analysis, 6 marks"). An assessment objective belongs to the
-- *subject* and is the same across every one of its papers, carrying a
-- percentage range rather than marks ("AO2: 40-45% of the A-level"). Forcing one
-- into the other would mean a weighting range stored in a marks column and an
-- objective duplicated onto every paper.
--
-- This is what makes an A-level paper groundable at all. A-level components have
-- no per-criterion marks, so before this table `loadRubric` found nothing for
-- them and every plan fell back to generic — the curriculum layer could not have
-- worked for A-level no matter how good the data was.
--
-- Read-only reference data, same shape as the curriculum tables it sits beside:
-- world-readable to signed-in users, no write grant for anyone but the service
-- role.

create table public.assessment_objectives (
  id                 uuid primary key default gen_random_uuid(),
  course_template_id uuid not null references public.course_templates(id) on delete cascade,
  code               text not null check (char_length(code) between 1 and 16),
  name               text not null check (char_length(name) between 1 and 300),
  -- Boards publish either a single figure or a range. Storing both ends and
  -- letting them be equal keeps one shape for both cases.
  weighting_min      numeric(5,2) check (weighting_min >= 0 and weighting_min <= 100),
  weighting_max      numeric(5,2) check (weighting_max >= 0 and weighting_max <= 100),
  ordinal            integer not null default 0,
  created_at         timestamptz not null default now(),
  unique (course_template_id, code),
  constraint weighting_ordered check (
    weighting_min is null or weighting_max is null or weighting_min <= weighting_max
  )
);

create index assessment_objectives_template_idx
  on public.assessment_objectives(course_template_id, ordinal);

alter table public.assessment_objectives enable row level security;

-- Revoke before granting: Supabase's default privileges hand every new public
-- table all four CRUD verbs to `authenticated`, so a narrower grant on its own
-- adds nothing. This is the same trap that left `gradings` insertable in 0022.
revoke all on public.assessment_objectives from anon, public;
revoke all on public.assessment_objectives from authenticated;
grant select on public.assessment_objectives to authenticated;

create policy assessment_objectives_read_all on public.assessment_objectives
  for select to authenticated using (true);

-- Assert it, because the failure mode is silent and this is reference data a
-- student must never be able to rewrite.
do $$
begin
  if has_table_privilege('authenticated', 'public.assessment_objectives', 'INSERT')
     or has_table_privilege('authenticated', 'public.assessment_objectives', 'UPDATE')
     or has_table_privilege('authenticated', 'public.assessment_objectives', 'DELETE') then
    raise exception 'assessment_objectives must be read-only to authenticated';
  end if;
  if has_table_privilege('anon', 'public.assessment_objectives', 'SELECT') then
    raise exception 'anon must not read assessment_objectives';
  end if;
end $$;
