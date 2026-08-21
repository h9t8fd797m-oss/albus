-- 0004_planning
-- The student's own work: courses, assignments, steps, scheduled sessions.
-- Every table carries user_id and is protected by the same four permissive
-- policies plus one restrictive owner-only invariant.

create table public.courses (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  course_template_id uuid references public.course_templates(id) on delete set null,
  display_name       text not null check (char_length(display_name) between 1 and 80),
  color_key          text not null default 'violet'
                       check (color_key in ('violet','red','amber','green','blue','pink')),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table public.assignments (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  course_id          uuid references public.courses(id) on delete set null,
  assessment_type_id uuid references public.assessment_types(id) on delete set null,
  title              text not null check (char_length(title) between 1 and 200),
  notes              text check (char_length(notes) <= 2000),
  task_type          text not null default 'other'
                       check (task_type in ('essay','problem_set','lab_report','reading',
                                            'revision','project','presentation','other')),
  deadline           timestamptz not null,
  estimated_minutes  integer not null check (estimated_minutes between 5 and 12000),
  status             text not null default 'active'
                       check (status in ('active','completed','archived')),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table public.subtasks (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users(id) on delete cascade,
  assignment_id       uuid not null references public.assignments(id) on delete cascade,
  rubric_criterion_id uuid references public.rubric_criteria(id) on delete set null,
  title               text not null check (char_length(title) between 1 and 200),
  guidance            text check (char_length(guidance) <= 1000),
  ordinal             integer not null default 0,
  estimated_minutes   integer not null check (estimated_minutes between 1 and 1440),
  completed_at        timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create table public.plan_sessions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  subtask_id    uuid references public.subtasks(id) on delete cascade,
  assignment_id uuid not null references public.assignments(id) on delete cascade,
  starts_at     timestamptz not null,
  ends_at       timestamptz not null,
  state         text not null default 'scheduled'
                  check (state in ('scheduled','active','completed','missed','skipped')),
  is_fixed      boolean not null default false,   -- classes: scheduler routes around, never through
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint session_ordered check (starts_at < ends_at)
);

-- Indexes: RLS predicates filter on user_id on every single query, so these
-- are correctness-adjacent, not just nice-to-have.
create index courses_user_idx            on public.courses(user_id);
create index assignments_user_idx        on public.assignments(user_id);
create index assignments_user_deadline_idx on public.assignments(user_id, deadline);
create index subtasks_user_idx           on public.subtasks(user_id);
create index subtasks_assignment_idx     on public.subtasks(assignment_id, ordinal);
create index plan_sessions_user_idx      on public.plan_sessions(user_id);
create index plan_sessions_user_start_idx on public.plan_sessions(user_id, starts_at);

do $$
declare t text;
begin
  foreach t in array array['courses','assignments','subtasks','plan_sessions'] loop
    execute format('create trigger %I before update on public.%I
                    for each row execute function public.set_updated_at()',
                   t || '_set_updated_at', t);

    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, public', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);

    execute format('create policy %I on public.%I for select to authenticated
                    using ((select auth.uid()) = user_id)', t || '_select_own', t);
    execute format('create policy %I on public.%I for insert to authenticated
                    with check ((select auth.uid()) = user_id)', t || '_insert_own', t);
    execute format('create policy %I on public.%I for update to authenticated
                    using ((select auth.uid()) = user_id)
                    with check ((select auth.uid()) = user_id)', t || '_update_own', t);
    execute format('create policy %I on public.%I for delete to authenticated
                    using ((select auth.uid()) = user_id)', t || '_delete_own', t);

    -- The invariant, ANDed with everything above and anything added later.
    execute format('create policy %I on public.%I as restrictive for all to authenticated
                    using ((select auth.uid()) = user_id)
                    with check ((select auth.uid()) = user_id)', t || '_owner_only', t);
  end loop;
end $$;
