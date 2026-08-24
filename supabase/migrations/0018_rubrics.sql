-- 0018_rubrics
--
-- A rubric the student owns, saves once and reuses.
--
-- Until now "rubric" meant `public.rubric_criteria`: global, read-only IB/AP
-- reference data hanging off `assessment_types`. That stays exactly as it is and
-- becomes a *seed source* — "use the IB Biology IA rubric" copies the template
-- into a personal rubric. One concept the student can edit, not two they cannot.
--
-- Shape note: a rubric carries both a free-text `body` (what was pasted off the
-- assignment sheet) and optional structured `rubric_items`. Grading prefers the
-- items when they exist and falls back to the body. That means pasting works on
-- day one with no model call to parse it, and adding a parser later is additive.

create table public.rubrics (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  name               text not null check (char_length(name) between 1 and 120),
  -- Where it came from. 'template' rows were copied out of rubric_criteria and
  -- keep the link, so we can tell a curriculum rubric from a pasted one.
  source             text not null default 'custom'
                       check (source in ('custom','template')),
  assessment_type_id uuid references public.assessment_types(id) on delete set null,
  -- The pasted sheet. Capped because this reaches a model: a rubric is a page,
  -- not a book, and an uncapped text column is an uncapped bill.
  body               text check (char_length(body) <= 8000),
  total_marks        integer check (total_marks between 1 and 1000),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table public.rubric_items (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  rubric_id  uuid not null references public.rubrics(id) on delete cascade,
  code       text check (char_length(code) <= 24),
  name       text not null check (char_length(name) between 1 and 200),
  marks      integer check (marks between 0 and 1000),
  guidance   text check (char_length(guidance) <= 2000),
  ordinal    integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- The assignment's rubric. Nullable: plenty of work has no rubric, and refusing
-- to plan without one would be worse than planning without one.
--
-- Ownership is enforced by trigger below rather than by the foreign key. A
-- composite (rubric_id, user_id) reference would be stronger, but `on delete
-- set null` would then try to null user_id too, which is not null. The trigger
-- is the honest version of the same invariant.
alter table public.assignments
  add column rubric_id uuid references public.rubrics(id) on delete set null;

create index rubrics_user_idx        on public.rubrics(user_id, updated_at desc);
create index rubric_items_user_idx   on public.rubric_items(user_id);
create index rubric_items_rubric_idx on public.rubric_items(rubric_id, ordinal);
create index assignments_rubric_idx  on public.assignments(rubric_id)
  where rubric_id is not null;

-- MARK: invariants

-- An item cannot be attached to someone else's rubric, and an assignment cannot
-- point at one. RLS already makes a foreign rubric invisible, so this is not the
-- only line of defence — it is the one that turns "you would see nothing" into
-- "the write is rejected", which is the difference between a confusing empty
-- screen and a clear error.
create or replace function public.assert_rubric_owned()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_owner uuid;
begin
  if new.rubric_id is null then
    return new;
  end if;

  select user_id into v_owner from public.rubrics where id = new.rubric_id;

  if v_owner is null or v_owner <> new.user_id then
    raise exception 'rubric does not belong to this user'
      using errcode = 'check_violation';
  end if;

  return new;
end $$;

create trigger rubric_items_owned
  before insert or update of rubric_id, user_id on public.rubric_items
  for each row execute function public.assert_rubric_owned();

create trigger assignments_rubric_owned
  before insert or update of rubric_id, user_id on public.assignments
  for each row execute function public.assert_rubric_owned();

-- Caps. Unbounded rows a client can create are a storage bill and a way to make
-- every later query slow. Both limits are far above honest use.
create or replace function public.assert_rubric_limits()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_table_name = 'rubrics' then
    if (select count(*) from public.rubrics where user_id = new.user_id) >= 200 then
      raise exception 'rubric limit reached' using errcode = 'check_violation';
    end if;
  else
    if (select count(*) from public.rubric_items where rubric_id = new.rubric_id) >= 40 then
      raise exception 'rubric criterion limit reached' using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;

create trigger rubrics_limit
  before insert on public.rubrics
  for each row execute function public.assert_rubric_limits();

create trigger rubric_items_limit
  before insert on public.rubric_items
  for each row execute function public.assert_rubric_limits();

-- MARK: grants and RLS, identical to 0004

do $$
declare t text;
begin
  foreach t in array array['rubrics','rubric_items'] loop
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

    execute format('create policy %I on public.%I as restrictive for all to authenticated
                    using ((select auth.uid()) = user_id)
                    with check ((select auth.uid()) = user_id)', t || '_owner_only', t);
  end loop;
end $$;

-- 0015 reset default privileges so new tables do not inherit TRUNCATE. These two
-- were created after that, so they already come out clean — asserted rather than
-- assumed, because the failure mode is silent.
do $$
declare t text;
begin
  foreach t in array array['rubrics','rubric_items'] loop
    if has_table_privilege('authenticated', 'public.' || t, 'TRUNCATE') then
      raise exception 'authenticated must not hold TRUNCATE on %', t;
    end if;
  end loop;
end $$;
