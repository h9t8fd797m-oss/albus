-- 0022_grading
--
-- Mark finished work against the student's own rubric, and give feedback.
--
-- This is the first paid surface, and the largest new cost surface in the app:
-- an essay is an order of magnitude more input than a breakdown prompt. Three
-- things follow, and all three are enforced here rather than in TypeScript,
-- because a client-side gate on a paid feature is one `curl` away from free:
--
--   1. Plus is checked inside `check_and_record_ai_usage`, in the same
--      transaction that reserves the usage slot.
--   2. Grading gets its own rate-limit bucket. Sharing chat's budget would make
--      both unpredictable and let cheap calls starve expensive ones.
--   3. The student's work is never stored. Only the marks, the feedback and a
--      character count survive the request.

-- MARK: - What a grading is

create table public.gradings (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  assignment_id uuid references public.assignments(id) on delete cascade,
  rubric_id     uuid references public.rubrics(id) on delete set null,

  model         text not null,
  -- How long the submission was. Kept instead of the submission: enough to
  -- reason about cost and to show "3,240 words marked", and it reveals nothing
  -- about what the student wrote.
  input_chars   integer not null check (input_chars >= 0),

  overall_marks integer check (overall_marks >= 0),
  total_marks   integer check (total_marks >= 0),
  -- Per-criterion marks and comments: [{code, name, marks, out_of, comment}].
  breakdown     jsonb not null default '[]'::jsonb,
  feedback      text check (char_length(feedback) <= 12000),

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint marks_within_total
    check (overall_marks is null or total_marks is null or overall_marks <= total_marks)
);

create index gradings_user_idx        on public.gradings(user_id, created_at desc);
create index gradings_assignment_idx  on public.gradings(assignment_id);

-- Same ownership invariant as rubric_items: a grading cannot be hung off
-- someone else's rubric even by a caller that bypasses RLS.
create trigger gradings_rubric_owned
  before insert or update of rubric_id, user_id on public.gradings
  for each row execute function public.assert_rubric_owned();

do $$
begin
  execute 'create trigger gradings_set_updated_at before update on public.gradings
           for each row execute function public.set_updated_at()';

  execute 'alter table public.gradings enable row level security';
  execute 'revoke all on public.gradings from anon, public';
  -- Revoke from `authenticated` *before* granting, not just grant a subset.
  --
  -- Supabase's default privileges hand every new public table
  -- select/insert/update/delete to `authenticated` automatically, so a narrower
  -- grant adds nothing and removes nothing — the extra verbs are already there.
  -- 0015 fixed this for TRUNCATE and left the four CRUD verbs in place, which is
  -- right for tables the student owns and wrong for this one. The assertion at
  -- the bottom of this file caught exactly that on the first run.
  execute 'revoke all on public.gradings from authenticated';
  -- No INSERT for authenticated: gradings are written by the edge function
  -- through the service role, after the model has actually been called. A
  -- student who could insert one could award themselves 20/20 and, more to the
  -- point, could fabricate the record the paywall exists to sell.
  execute 'grant select, delete on public.gradings to authenticated';

  execute 'create policy gradings_select_own on public.gradings for select to authenticated
           using ((select auth.uid()) = user_id)';
  execute 'create policy gradings_delete_own on public.gradings for delete to authenticated
           using ((select auth.uid()) = user_id)';
  execute 'create policy gradings_owner_only on public.gradings as restrictive for all
           to authenticated
           using ((select auth.uid()) = user_id)
           with check ((select auth.uid()) = user_id)';
end $$;

-- MARK: - Quota

alter table public.ai_usage
  drop constraint if exists ai_usage_kind_check;
alter table public.ai_usage
  add constraint ai_usage_kind_check check (kind in ('breakdown','chat','grade'));

create or replace function public.check_and_record_ai_usage(
  p_kind  text,
  p_model text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid          uuid := (select auth.uid());
  v_tier         text;
  v_expires      timestamptz;
  v_is_plus      boolean;
  v_hour_limit   integer;
  v_day_limit    integer;
  v_hour         integer;
  v_day          integer;
  v_model        text;
  v_global_cap   integer;
  v_global_used  integer;
  v_id           uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  if p_kind not in ('breakdown', 'chat', 'grade') then
    raise exception 'INVALID_KIND' using errcode = '22023';
  end if;

  v_model := left(coalesce(p_model, 'unknown'), 64);
  if v_model !~ '^[A-Za-z0-9._-]+$' then
    v_model := 'unknown';
  end if;

  select c.int_value into v_global_cap
    from public.app_config c where c.key = 'global_ai_calls_per_hour';
  v_global_cap := coalesce(v_global_cap, 2000);

  select count(*) into v_global_used
    from public.ai_usage u
   where u.created_at > now() - interval '1 hour';

  if v_global_used >= v_global_cap then
    raise exception 'GLOBAL_CAPACITY_REACHED' using errcode = 'Q0004';
  end if;

  select e.tier, e.expires_at into v_tier, v_expires
    from public.entitlements e where e.user_id = v_uid;

  v_is_plus := coalesce(v_tier = 'plus', false)
               and (v_expires is null or v_expires > now());

  -- The paywall. Here, not in the edge function, and not on the device: this
  -- runs in the same transaction that reserves the usage slot, so there is no
  -- window between "are you allowed" and "you have now used one".
  if p_kind = 'grade' and not v_is_plus then
    raise exception 'PLUS_REQUIRED' using errcode = 'Q0005';
  end if;

  if p_kind = 'chat' then
    v_hour_limit := case when v_is_plus then 120 else 20  end;
    v_day_limit  := case when v_is_plus then 600 else 60  end;
  elsif p_kind = 'grade' then
    -- Deliberately tight. Grading a full essay is the most expensive call the
    -- app makes, and re-marking the same piece thirty times in an hour is not a
    -- use case — it is a bill.
    v_hour_limit := 6;
    v_day_limit  := 20;
  else
    v_hour_limit := case when v_is_plus then  30 else  8  end;
    v_day_limit  := case when v_is_plus then 150 else 25  end;
  end if;

  select count(*) into v_hour from public.ai_usage u
   where u.user_id = v_uid and u.kind = p_kind
     and u.created_at > now() - interval '1 hour';
  if v_hour >= v_hour_limit then
    raise exception 'RATE_LIMIT_HOURLY' using errcode = 'Q0002';
  end if;

  select count(*) into v_day from public.ai_usage u
   where u.user_id = v_uid and u.kind = p_kind
     and u.created_at > now() - interval '1 day';
  if v_day >= v_day_limit then
    raise exception 'RATE_LIMIT_DAILY' using errcode = 'Q0003';
  end if;

  insert into public.ai_usage (user_id, kind, model)
  values (v_uid, p_kind, v_model)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.check_and_record_ai_usage(text, text) from public, anon;
grant execute on function public.check_and_record_ai_usage(text, text) to authenticated;

-- Assert the grants came out as intended. 0015 fixed the default privileges, but
-- the failure mode is silent, so it is checked rather than assumed.
do $$
begin
  if has_table_privilege('authenticated', 'public.gradings', 'TRUNCATE') then
    raise exception 'authenticated must not hold TRUNCATE on gradings';
  end if;
  if has_table_privilege('authenticated', 'public.gradings', 'INSERT') then
    raise exception 'authenticated must not be able to insert its own gradings';
  end if;
  if has_table_privilege('anon', 'public.gradings', 'SELECT') then
    raise exception 'anon must not read gradings';
  end if;
end $$;
