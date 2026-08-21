-- 0002_profiles
-- One row per auth user. Created automatically by the 0001 trigger.

create table public.profiles (
  id                    uuid primary key references auth.users(id) on delete cascade,
  display_name          text check (char_length(display_name) <= 60),
  curriculum_code       text,
  daily_study_minutes   integer not null default 150
                          check (daily_study_minutes between 0 and 960),
  study_window_start    time    not null default '16:00',
  study_window_end      time    not null default '22:00',
  onboarding_completed_at timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint study_window_ordered check (study_window_start < study_window_end)
);

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ── access control ────────────────────────────────────────────────────────
alter table public.profiles enable row level security;

revoke all on public.profiles from anon, public;
grant select, insert, update on public.profiles to authenticated;
-- deliberately no DELETE: profile lifetime follows auth.users

-- Permissive policies, one per operation, each scoped to the owner.
-- auth.uid() is wrapped in a subquery so Postgres evaluates it once per
-- statement instead of once per row (Supabase lint 0003_auth_rls_initplan).
create policy profiles_select_own on public.profiles
  for select to authenticated
  using ((select auth.uid()) = id);

create policy profiles_insert_own on public.profiles
  for insert to authenticated
  with check ((select auth.uid()) = id);

create policy profiles_update_own on public.profiles
  for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- Defense in depth. RESTRICTIVE policies AND with every permissive policy,
-- so a carelessly broad policy added later still cannot leak another user's
-- row. This is the invariant: on this table, uid() must equal id. Always.
create policy profiles_owner_only on public.profiles
  as restrictive for all to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);
