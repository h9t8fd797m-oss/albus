-- 0005_calibration
-- The completion log. Deliberately carries NO free text: no titles, no notes,
-- no assignment content. Enough to calibrate durations, never enough to learn
-- what a student is working on.

create table public.completion_logs (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users(id) on delete cascade,
  subtask_id        uuid references public.subtasks(id) on delete set null,

  -- anonymised shape (mirrors the /logs payload exactly)
  curriculum_code   text,
  course_code       text,
  task_type         text not null,
  estimated_minutes integer not null check (estimated_minutes > 0),
  actual_minutes    integer not null check (actual_minutes > 0),
  hour_bucket       smallint check (hour_bucket between 0 and 23),
  minutes_late      integer,                    -- actual_start - scheduled_start
  confidence        text not null default 'low'
                      check (confidence in ('low','high')),  -- high = real timer data
  created_at        timestamptz not null default now()
);

create index completion_logs_user_idx on public.completion_logs(user_id, created_at desc);
create index completion_logs_agg_idx  on public.completion_logs(curriculum_code, course_code, task_type);

alter table public.completion_logs enable row level security;
revoke all on public.completion_logs from anon, public;
-- Append-only from the client: insert and read your own, never edit history.
grant select, insert on public.completion_logs to authenticated;

create policy completion_logs_select_own on public.completion_logs
  for select to authenticated using ((select auth.uid()) = user_id);
create policy completion_logs_insert_own on public.completion_logs
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy completion_logs_owner_only on public.completion_logs
  as restrictive for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
