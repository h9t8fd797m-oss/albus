-- 0011_usage_tokens
-- Backfills token counts onto a usage row already reserved by
-- check_and_record_ai_usage. Ownership is re-checked here rather than trusted:
-- a caller must not be able to scribble on another user's usage record.

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

  update public.ai_usage
     set input_tokens  = greatest(0, coalesce(p_input_tokens, 0)),
         output_tokens = greatest(0, coalesce(p_output_tokens, 0))
   where id = p_usage_id
     and user_id = v_uid;
end;
$$;

revoke all on function public.record_ai_usage_tokens(uuid, integer, integer) from public, anon;
grant execute on function public.record_ai_usage_tokens(uuid, integer, integer) to authenticated;
