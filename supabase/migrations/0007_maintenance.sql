-- 0007_maintenance
-- Anonymous users are real rows in auth.users and Supabase does not clean them
-- up. Every abandoned first-launch leaves one behind. This reaps the ones that
-- never produced any work.
--
-- NOT scheduled by this migration. Enable pg_cron and schedule it once you
-- have real traffic:
--   select cron.schedule('reap-anon', '0 4 * * *',
--                        $$select public.reap_abandoned_anonymous_users(30)$$);

create or replace function public.reap_abandoned_anonymous_users(older_than_days integer default 30)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  removed integer;
begin
  with doomed as (
    select u.id
    from auth.users u
    where u.is_anonymous is true
      and u.created_at < now() - make_interval(days => older_than_days)
      and not exists (select 1 from public.assignments a where a.user_id = u.id)
      and not exists (select 1 from public.completion_logs c where c.user_id = u.id)
  )
  delete from auth.users where id in (select id from doomed);
  get diagnostics removed = row_count;
  return removed;
end;
$$;

revoke all on function public.reap_abandoned_anonymous_users(integer) from public, anon, authenticated;
