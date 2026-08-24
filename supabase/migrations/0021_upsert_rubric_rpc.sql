-- 0021_upsert_rubric_rpc
--
-- Save a rubric and its criteria in one atomic call.
--
-- Why an RPC rather than two PostgREST writes: replacing the criteria of an
-- existing rubric is a delete plus an insert, and doing that over two requests
-- means a dropped connection can leave a student with a rubric that has a name
-- and no criteria. One transaction, or nothing.
--
-- The client passes the id it already generated locally, which makes a retry
-- idempotent rather than a duplicate.

create or replace function public.upsert_rubric(
  p_id          uuid,
  p_name        text,
  p_source      text default 'custom',
  p_body        text default null,
  p_total_marks integer default null,
  p_items       jsonb default '[]'::jsonb
)
returns uuid
language plpgsql
security invoker
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

  if coalesce(btrim(p_name), '') = '' then
    raise exception 'RUBRIC_NAME_REQUIRED' using errcode = '22023';
  end if;

  if jsonb_typeof(p_items) <> 'array' then
    raise exception 'ITEMS_MUST_BE_ARRAY' using errcode = '22023';
  end if;

  -- Matches the rubric_items_limit trigger. Checked here too so the caller gets
  -- a named error rather than a trigger message from partway through a loop.
  if jsonb_array_length(p_items) > 40 then
    raise exception 'TOO_MANY_CRITERIA' using errcode = '22023';
  end if;

  v_source := case when p_source in ('custom','template') then p_source else 'custom' end;

  -- Explicit ownership check. Without it a forged id would still be refused —
  -- by an RLS violation on the update — but as an opaque failure rather than
  -- something the client can report honestly.
  select user_id into v_owner from public.rubrics where id = p_id;
  if v_owner is not null and v_owner <> v_uid then
    raise exception 'RUBRIC_NOT_YOURS' using errcode = '42501';
  end if;

  insert into public.rubrics (id, user_id, name, source, body, total_marks)
  values (p_id, v_uid, btrim(p_name), v_source, nullif(btrim(coalesce(p_body,'')), ''), p_total_marks)
  on conflict (id) do update
    set name        = excluded.name,
        source      = excluded.source,
        body        = excluded.body,
        total_marks = excluded.total_marks;

  -- Replace wholesale. Diffing criteria would be more code for no gain: a
  -- rubric is a handful of rows and the whole thing is being saved anyway.
  delete from public.rubric_items where rubric_id = p_id;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    insert into public.rubric_items (user_id, rubric_id, code, name, marks, guidance, ordinal)
    values (
      v_uid,
      p_id,
      nullif(btrim(coalesce(v_item->>'code','')), ''),
      left(btrim(coalesce(v_item->>'name','Criterion')), 200),
      nullif(v_item->>'marks','')::integer,
      nullif(btrim(coalesce(v_item->>'guidance','')), ''),
      v_ordinal
    );
    v_ordinal := v_ordinal + 1;
  end loop;

  return p_id;
end;
$$;

revoke all on function public.upsert_rubric(uuid, text, text, text, integer, jsonb)
  from public, anon;
grant execute on function public.upsert_rubric(uuid, text, text, text, integer, jsonb)
  to authenticated;
