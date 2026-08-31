-- Close the non-AI ways a manipulated client could still create a bill.
--
-- The model quota protects Anthropic spend. It does not protect Postgres from
-- a caller that sends malformed requests forever, invents a new device id on
-- every request, or bypasses the app and writes unused sync tables directly.
-- These controls are deliberately below the client and below every Edge
-- handler: a repackaged app sees exactly the same limits as the real one.

-- ---------------------------------------------------------------------------
-- 1. A compact request limiter before parsing, retrieval, or telemetry

create table private.api_rate_windows (
  user_id      uuid not null references auth.users(id) on delete cascade,
  window_kind  text not null check (window_kind in ('minute', 'hour')),
  window_start timestamptz not null,
  hits         integer not null check (hits between 1 and 1000000),
  primary key (user_id, window_kind, window_start)
);

revoke all on private.api_rate_windows from public, anon, authenticated;

-- Deleting an anonymous account used to cascade-delete every device/network
-- observation attached to it. A farm could therefore erase the evidence and
-- immediately create another Free account. Keep the now-pseudonymous account
-- UUID only for the 90-day fraud-prevention window; the auth row and all user
-- content still delete normally, raw device/IP values were never stored, and
-- prune_security_data removes this link on schedule.
alter table public.identity_links
  drop constraint if exists identity_links_user_id_fkey;
comment on column public.identity_links.user_id is
  'Pseudonymous account UUID retained for at most the identity-link retention window so account deletion cannot reset abuse history.';

insert into public.app_config (key, int_value) values
  ('api_requests_per_minute', 30),
  ('api_requests_per_hour',  180),
  ('security_events_per_user_hour', 50)
on conflict (key) do update set int_value = excluded.int_value;

create or replace function public.check_api_request_rate(
  p_user_id uuid,
  p_endpoint text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now          timestamptz := statement_timestamp();
  v_minute       timestamptz := date_trunc('minute', v_now);
  v_hour         timestamptz := date_trunc('hour', v_now);
  v_minute_limit integer;
  v_hour_limit   integer;
begin
  if p_user_id is null
     or not exists (select 1 from auth.users u where u.id = p_user_id) then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  if p_endpoint not in ('breakdown', 'chat', 'grade') then
    raise exception 'INVALID_ENDPOINT' using errcode = '22023';
  end if;

  select coalesce(max(case when key = 'api_requests_per_minute' then int_value end), 30),
         coalesce(max(case when key = 'api_requests_per_hour' then int_value end), 180)
    into v_minute_limit, v_hour_limit
    from public.app_config;

  insert into private.api_rate_windows (user_id, window_kind, window_start, hits)
  values (p_user_id, 'minute', v_minute, 1)
  on conflict (user_id, window_kind, window_start) do update
    set hits = private.api_rate_windows.hits + 1
    where private.api_rate_windows.hits < v_minute_limit;
  if not found then
    raise exception 'API_RATE_LIMIT' using errcode = 'Q0014';
  end if;

  insert into private.api_rate_windows (user_id, window_kind, window_start, hits)
  values (p_user_id, 'hour', v_hour, 1)
  on conflict (user_id, window_kind, window_start) do update
    set hits = private.api_rate_windows.hits + 1
    where private.api_rate_windows.hits < v_hour_limit;
  if not found then
    raise exception 'API_RATE_LIMIT' using errcode = 'Q0014';
  end if;
end;
$$;

revoke all on function public.check_api_request_rate(uuid, text)
  from public, anon, authenticated;
grant execute on function public.check_api_request_rate(uuid, text)
  to service_role;

-- ---------------------------------------------------------------------------
-- 2. Telemetry is bounded even when every header is hostile

create or replace function public.record_identity_link(
  p_user_id uuid,
  p_kind text,
  p_hash text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer;
begin
  if p_user_id is null or p_kind not in ('device', 'ip_prefix')
     or p_hash is null or p_hash !~ '^[0-9a-f]{64}$'
     or not exists (select 1 from auth.users u where u.id = p_user_id) then
    return;
  end if;

  -- Existing observations are cheap and useful. Do this before taking the lock
  -- so the normal path does not serialize every request from one student.
  update public.identity_links l
     set last_seen_at = now(),
         hit_count = least(2147483647, l.hit_count + 1)
   where l.user_id = p_user_id and l.kind = p_kind and l.hash = p_hash;
  if found then return; end if;

  perform pg_advisory_xact_lock(
    hashtextextended('albus:identity:' || p_user_id::text || ':' || p_kind, 0));

  -- A modified client can send a fresh, UUID-shaped device header each time.
  -- Eight devices and sixteen network prefixes cover real travel/reinstalls;
  -- the seventeenth random value is storage amplification, not identity.
  v_limit := case when p_kind = 'device' then 8 else 16 end;
  if (select count(*) from public.identity_links l
       where l.user_id = p_user_id and l.kind = p_kind) >= v_limit then
    return;
  end if;

  insert into public.identity_links (user_id, kind, hash)
  values (p_user_id, p_kind, p_hash)
  on conflict (user_id, kind, hash) do update
    set last_seen_at = now(),
        hit_count = least(2147483647, public.identity_links.hit_count + 1);
end;
$$;

revoke all on function public.record_identity_link(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.record_identity_link(uuid, text, text)
  to service_role;

create or replace function public.log_security_event(
  p_user_id uuid,
  p_kind text,
  p_severity text,
  p_device_hash text default null,
  p_ip_prefix_hash text default null,
  p_detail jsonb default '{}'::jsonb
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer;
begin
  if p_user_id is null
     or not exists (select 1 from auth.users u where u.id = p_user_id) then
    return;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('albus:security_events:' || p_user_id::text, 0));
  select coalesce(c.int_value, 50) into v_limit
    from public.app_config c where c.key = 'security_events_per_user_hour';
  v_limit := coalesce(v_limit, 50);
  if (select count(*) from public.security_events e
       where e.user_id = p_user_id and e.at > now() - interval '1 hour') >= v_limit then
    return;
  end if;

  insert into public.security_events
    (user_id, kind, severity, device_hash, ip_prefix_hash, detail)
  values (
    p_user_id,
    left(coalesce(p_kind, 'unknown'), 64),
    case when p_severity in ('info', 'warn', 'alert') then p_severity else 'info' end,
    case when p_device_hash ~ '^[0-9a-f]{64}$' then p_device_hash end,
    case when p_ip_prefix_hash ~ '^[0-9a-f]{64}$' then p_ip_prefix_hash end,
    case when pg_column_size(coalesce(p_detail, '{}'::jsonb)) <= 2048
         then coalesce(p_detail, '{}'::jsonb)
         else '{"truncated": true}'::jsonb end
  );
exception when others then
  -- Audit telemetry cannot be allowed to take the product down.
  null;
end;
$$;

revoke all on function public.log_security_event(uuid, text, text, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.log_security_event(uuid, text, text, text, text, jsonb)
  to service_role;

-- ---------------------------------------------------------------------------
-- 3. The app writes through narrow RPCs; unused raw table writes are closed

-- The bodies already derive user_id from auth.uid() and fully qualify every
-- relation. SECURITY DEFINER lets those two RPCs keep writing after raw INSERT
-- and UPDATE privileges are removed from the app role.
alter function public.create_assignment_with_plan(
  text, text, timestamptz, integer, jsonb, uuid, uuid, text, uuid, text)
  security definer;

-- `upsert_rubric` receives a client-generated UUID. The original implementation
-- checked ownership and then used INSERT ... ON CONFLICT, leaving a narrow
-- check/use race: two accounts presenting the same unused UUID concurrently
-- could both see no owner, after which one conflict path updated the other's
-- row and deleted its criteria under SECURITY DEFINER. Serialize by the object
-- id before checking ownership, then use separate INSERT and owner-scoped
-- UPDATE/DELETE paths so a future refactor cannot reopen the sink.
create or replace function public.upsert_rubric(
  p_id uuid,
  p_name text,
  p_source text default 'custom',
  p_body text default null,
  p_total_marks integer default null,
  p_items jsonb default '[]'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_owner   uuid;
  v_item    jsonb;
  v_ordinal integer := 0;
  v_source  text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  if p_id is null then
    raise exception 'RUBRIC_ID_REQUIRED' using errcode = '22023';
  end if;
  if coalesce(btrim(p_name), '') = '' or char_length(btrim(p_name)) > 120 then
    raise exception 'RUBRIC_NAME_INVALID' using errcode = '22023';
  end if;
  if p_body is not null and char_length(p_body) > 8000 then
    raise exception 'RUBRIC_BODY_TOO_LONG' using errcode = '22023';
  end if;
  if p_total_marks is not null and (p_total_marks < 1 or p_total_marks > 1000) then
    raise exception 'RUBRIC_MARKS_INVALID' using errcode = '22023';
  end if;
  if jsonb_typeof(p_items) <> 'array' then
    raise exception 'ITEMS_MUST_BE_ARRAY' using errcode = '22023';
  end if;
  if jsonb_array_length(p_items) > 40 then
    raise exception 'TOO_MANY_CRITERIA' using errcode = '22023';
  end if;

  v_source := case when p_source in ('custom', 'template') then p_source else 'custom' end;

  perform pg_advisory_xact_lock(
    hashtextextended('albus:rubric-id:' || p_id::text, 0));
  select r.user_id into v_owner from public.rubrics r where r.id = p_id;

  if found then
    if v_owner <> v_uid then
      raise exception 'RUBRIC_NOT_YOURS' using errcode = '42501';
    end if;
    update public.rubrics r
       set name = btrim(p_name),
           source = v_source,
           body = nullif(btrim(coalesce(p_body, '')), ''),
           total_marks = p_total_marks
     where r.id = p_id and r.user_id = v_uid;
  else
    insert into public.rubrics (id, user_id, name, source, body, total_marks)
    values (
      p_id, v_uid, btrim(p_name), v_source,
      nullif(btrim(coalesce(p_body, '')), ''), p_total_marks
    );
  end if;

  delete from public.rubric_items i
   where i.rubric_id = p_id and i.user_id = v_uid;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    if coalesce(btrim(v_item->>'name'), '') = ''
       or char_length(btrim(v_item->>'name')) > 200
       or char_length(coalesce(v_item->>'code', '')) > 24
       or char_length(coalesce(v_item->>'guidance', '')) > 2000
       or (nullif(v_item->>'marks', '') is not null and
           ((v_item->>'marks')::integer < 0 or (v_item->>'marks')::integer > 1000)) then
      raise exception 'RUBRIC_ITEM_INVALID' using errcode = '22023';
    end if;

    insert into public.rubric_items
      (user_id, rubric_id, code, name, marks, guidance, ordinal)
    values (
      v_uid,
      p_id,
      nullif(btrim(coalesce(v_item->>'code', '')), ''),
      btrim(v_item->>'name'),
      nullif(v_item->>'marks', '')::integer,
      nullif(btrim(coalesce(v_item->>'guidance', '')), ''),
      v_ordinal
    );
    v_ordinal := v_ordinal + 1;
  end loop;

  return p_id;
end;
$$;

create or replace function public.create_course(
  p_display_name text,
  p_color_key text default 'violet',
  p_template_code text default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_template uuid;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('albus:courses:' || v_uid::text, 0));
  if (select count(*) from public.courses c where c.user_id = v_uid) >= 50 then
    raise exception 'COURSE_CEILING' using errcode = 'Q0015';
  end if;

  if p_template_code is not null then
    select ct.id into v_template
      from public.course_templates ct
     where ct.code = left(p_template_code, 80)
     limit 1;
  end if;

  insert into public.courses (user_id, course_template_id, display_name, color_key)
  values (v_uid, v_template, p_display_name, coalesce(p_color_key, 'violet'))
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.create_course(text, text, text) from public, anon;
grant execute on function public.create_course(text, text, text) to authenticated;

-- A SECURITY DEFINER assignment RPC must reject a course belonging to another
-- user before it writes. The rubric has an equivalent trigger already.
create or replace function public.assert_assignment_course_owned()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.course_id is not null and not exists (
    select 1 from public.courses c
     where c.id = new.course_id and c.user_id = new.user_id
  ) then
    raise exception 'COURSE_NOT_YOURS' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function public.assert_assignment_course_owned()
  from public, anon, authenticated, service_role;

drop trigger if exists assignments_course_owned on public.assignments;
create trigger assignments_course_owned
  before insert or update of course_id, user_id on public.assignments
  for each row execute function public.assert_assignment_course_owned();

-- Grading rows are written with the service role after the model returns. RLS
-- therefore cannot protect the assignment foreign key at that sink: enforce
-- the same user_id invariant in Postgres so every present and future writer is
-- covered. Loose work deliberately has no assignment and remains valid.
create or replace function public.assert_grading_assignment_owned()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.assignment_id is not null and not exists (
    select 1 from public.assignments a
     where a.id = new.assignment_id and a.user_id = new.user_id
  ) then
    raise exception 'ASSIGNMENT_NOT_YOURS' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function public.assert_grading_assignment_owned()
  from public, anon, authenticated, service_role;

drop trigger if exists gradings_assignment_owned on public.gradings;
create trigger gradings_assignment_owned
  before insert or update of assignment_id, user_id on public.gradings
  for each row execute function public.assert_grading_assignment_owned();

-- "Unlimited" is a product word, not permission to allocate unbounded rows.
-- Free/Plus still stop at their advertised active-task limits; Pro has a very
-- high abuse ceiling that an honest student will never notice.
create or replace function public.assert_active_task_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer;
  v_active integer;
  v_total integer;
begin
  if tg_op = 'INSERT' then
    perform pg_advisory_xact_lock(
      hashtextextended('albus:assignments:' || new.user_id::text, 0));
    select count(*) into v_total from public.assignments a where a.user_id = new.user_id;
    if v_total >= 2000 then
      raise exception 'ASSIGNMENT_CEILING' using errcode = 'Q0016';
    end if;
  end if;

  if new.status is distinct from 'active' then return new; end if;
  if tg_op = 'UPDATE' and old.status = 'active' and old.user_id = new.user_id then
    return new;
  end if;

  -- INSERT already holds this lock. Advisory locks are re-entrant in the same
  -- transaction, so taking it here also covers inactive-to-active updates.
  perform pg_advisory_xact_lock(
    hashtextextended('albus:assignments:' || new.user_id::text, 0));
  select p.active_tasks into v_limit
    from public.plans p where p.tier = public.effective_tier(new.user_id);
  if not found then raise exception 'PLAN_UNKNOWN' using errcode = 'Q0005'; end if;

  select count(*) into v_active
    from public.assignments a
   where a.user_id = new.user_id and a.status = 'active'
     and a.id is distinct from new.id;

  if v_limit is not null and v_active >= v_limit then
    raise exception 'PLAN_TASK_LIMIT_REACHED' using errcode = 'Q0001';
  elsif v_limit is null and v_active >= 500 then
    raise exception 'ASSIGNMENT_CEILING' using errcode = 'Q0016';
  end if;
  return new;
end;
$$;
revoke all on function public.assert_active_task_limit()
  from public, anon, authenticated, service_role;

drop trigger if exists assignments_active_limit on public.assignments;
create trigger assignments_active_limit
  before insert or update of status, user_id on public.assignments
  for each row execute function public.assert_active_task_limit();

-- Make the per-rubric child ceiling exact under concurrent inserts and refuse
-- a child whose user/parent relationship is inconsistent.
create or replace function public.assert_rubric_limits()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer;
  v_count integer;
  v_existing_owner uuid;
begin
  if tg_table_name = 'rubrics' then
    perform pg_advisory_xact_lock(hashtextextended('albus:rubrics:' || new.user_id::text, 0));

    -- INSERT ... ON CONFLICT runs BEFORE INSERT triggers before it decides to
    -- update. Without this distinction a Free student at three saved rubrics
    -- could not edit any of those three: the edit looked like a fourth insert.
    select r.user_id into v_existing_owner
      from public.rubrics r where r.id = new.id;
    if found then
      if v_existing_owner <> new.user_id then
        raise exception 'RUBRIC_NOT_YOURS' using errcode = '42501';
      end if;
      return new;
    end if;

    select count(*) into v_count from public.rubrics where user_id = new.user_id;
    if v_count >= 200 then raise exception 'RUBRIC_CEILING' using errcode = 'Q0012'; end if;
    select p.rubrics into v_limit
      from public.plans p where p.tier = public.effective_tier(new.user_id);
    if v_limit is not null and v_count >= v_limit then
      raise exception 'RUBRIC_PLAN_LIMIT' using errcode = 'Q0011';
    end if;
  else
    perform pg_advisory_xact_lock(
      hashtextextended('albus:rubric_items:' || new.rubric_id::text, 0));
    if (select count(*) from public.rubric_items i
         where i.rubric_id = new.rubric_id) >= 40 then
      raise exception 'rubric criterion limit reached' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.assert_rubric_limits()
  from public, anon, authenticated, service_role;

create or replace function public.assert_subtask_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(
    hashtextextended('albus:subtasks:' || new.assignment_id::text, 0));
  if not exists (
    select 1 from public.assignments a
     where a.id = new.assignment_id and a.user_id = new.user_id
  ) then
    raise exception 'ASSIGNMENT_NOT_YOURS' using errcode = '42501';
  end if;
  if (select count(*) from public.subtasks s
       where s.assignment_id = new.assignment_id) >= 64 then
    raise exception 'TOO_MANY_SUBTASKS' using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function public.assert_subtask_limit()
  from public, anon, authenticated, service_role;

-- Current clients use these tables through the RPCs above. SELECT and the two
-- explicit owner-scoped DELETE paths remain where the app actually uses them.
revoke insert, update on public.assignments from authenticated;
revoke insert, update, delete on public.subtasks from authenticated;
revoke insert, update, delete on public.courses from authenticated;
revoke insert, update on public.rubrics from authenticated;
revoke insert, update, delete on public.rubric_items from authenticated;
revoke all on public.plan_sessions from authenticated;
revoke all on public.completion_logs from authenticated;

-- Historical SECURITY DEFINER helpers used `public, pg_temp`. Their relation
-- names were already qualified and API roles cannot create in `public`, so
-- this was not an active lookup hijack. It is nevertheless unnecessary: an
-- empty path leaves only pg_catalog implicit and makes the invariant uniform
-- across every privileged function.
alter function public.assert_rubric_owned() set search_path = '';
alter function public.grading_spend_count(uuid, interval) set search_path = '';
alter function public.grading_window_resets_at(uuid, interval) set search_path = '';

-- Superseded privileged entry points are removed, not merely hidden. This also
-- makes a stale deployed function fail closed after the migration lands.
drop function public.check_and_record_ai_usage(text, text);
drop function public.record_ai_usage_tokens(uuid, integer, integer);
drop function public.apply_subscription_state(
  text, uuid, text, text, text, timestamptz, timestamptz, timestamptz);

-- Keep compact rate windows only as long as they can affect a decision.
create or replace function public.prune_security_data(
  p_link_days integer default 90,
  p_event_days integer default 180
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_links integer;
  v_events integer;
  v_attempts integer;
  v_windows integer;
begin
  delete from public.identity_links
   where last_seen_at < now() - make_interval(days => greatest(30, p_link_days));
  get diagnostics v_links = row_count;
  delete from public.security_events
   where at < now() - make_interval(days => greatest(30, p_event_days));
  get diagnostics v_events = row_count;
  delete from public.ai_usage
   where attempt_state in ('failed', 'reserved')
     and created_at < now() - interval '30 days';
  get diagnostics v_attempts = row_count;
  delete from private.api_rate_windows
   where window_start < now() - interval '2 hours';
  get diagnostics v_windows = row_count;
  return v_links + v_events + v_attempts + v_windows;
end;
$$;
revoke all on function public.prune_security_data(integer, integer)
  from public, anon, authenticated;

-- Future public objects are private until a migration deliberately exposes
-- them. Supabase's historical defaults auto-grant tables/functions to API
-- roles; relying on every future author to remember a REVOKE creates the next
-- accidental endpoint. Existing app objects keep their current explicit
-- grants, so this changes no shipping client path.
alter default privileges for role postgres in schema public
  revoke select, insert, update, delete, truncate, references, trigger
  on tables from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke usage, select, update on sequences from anon, authenticated, service_role;
-- Function EXECUTE is granted to PUBLIC by PostgreSQL's built-in *global*
-- default. A schema-local revoke cannot override a global grant, so this one
-- deliberately has no `in schema` clause.
alter default privileges for role postgres
  revoke execute on functions from public;
alter default privileges for role postgres in schema public
  revoke execute on functions from anon, authenticated, service_role;
