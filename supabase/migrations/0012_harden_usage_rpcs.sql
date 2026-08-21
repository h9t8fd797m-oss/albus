-- 0012_harden_usage_rpcs
--
-- Both usage RPCs are SECURITY DEFINER and callable by `authenticated`, which
-- they have to be: the role holds no INSERT or UPDATE grant on ai_usage. The
-- database advisor correctly flags that as worth scrutinising, so this
-- migration closes the two gaps it exposes.
--
-- Neither is an access-control hole — a caller can only ever affect their own
-- rows and can only ever *consume* quota. Both are data-integrity and
-- storage-abuse issues: reachable directly over /rest/v1/rpc/... by anyone
-- with a session, and previously unbounded.
--
--   1. p_model was written to the table verbatim. A megabyte-long "model
--      name" was a free write-amplification primitive.
--   2. Token counts had a floor of zero but no ceiling, so cost analytics
--      could be poisoned with absurd values.

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
  v_uid        uuid := (select auth.uid());
  v_tier       text;
  v_expires    timestamptz;
  v_is_plus    boolean;
  v_hour_limit integer;
  v_day_limit  integer;
  v_hour       integer;
  v_day        integer;
  v_model      text;
  v_id         uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  if p_kind not in ('breakdown', 'chat') then
    raise exception 'INVALID_KIND' using errcode = '22023';
  end if;

  -- Bound what a caller can persist. Model ids are short, known-shaped
  -- strings; anything else is either a bug or an abuse attempt.
  v_model := left(coalesce(p_model, 'unknown'), 64);
  if v_model !~ '^[A-Za-z0-9._-]+$' then
    v_model := 'unknown';
  end if;

  select e.tier, e.expires_at into v_tier, v_expires
    from public.entitlements e where e.user_id = v_uid;

  v_is_plus := coalesce(v_tier = 'plus', false)
               and (v_expires is null or v_expires > now());

  if p_kind = 'chat' then
    v_hour_limit := case when v_is_plus then 120 else 20  end;
    v_day_limit  := case when v_is_plus then 600 else 60  end;
  else
    v_hour_limit := case when v_is_plus then  30 else  8  end;
    v_day_limit  := case when v_is_plus then 150 else 25  end;
  end if;

  select count(*) into v_hour from public.ai_usage u
   where u.user_id = v_uid and u.kind = p_kind
     and u.created_at > now() - interval '1 hour';
  if v_hour >= v_hour_limit then
    raise exception 'RATE_LIMIT_HOURLY' using errcode = 'P0002';
  end if;

  select count(*) into v_day from public.ai_usage u
   where u.user_id = v_uid and u.kind = p_kind
     and u.created_at > now() - interval '1 day';
  if v_day >= v_day_limit then
    raise exception 'RATE_LIMIT_DAILY' using errcode = 'P0003';
  end if;

  insert into public.ai_usage (user_id, kind, model)
  values (v_uid, p_kind, v_model)
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.record_ai_usage_tokens(
  p_usage_id      uuid,
  p_input_tokens  integer,
  p_output_tokens integer
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;

  -- Clamp both ends. No single request can legitimately exceed this, and an
  -- unbounded value only serves to poison cost reporting.
  update public.ai_usage
     set input_tokens  = least(2000000, greatest(0, coalesce(p_input_tokens, 0))),
         output_tokens = least(2000000, greatest(0, coalesce(p_output_tokens, 0)))
   where id = p_usage_id
     and user_id = v_uid;
end;
$$;
