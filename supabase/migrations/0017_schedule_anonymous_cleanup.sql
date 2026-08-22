-- 0017_schedule_anonymous_cleanup
--
-- RECOVERED FROM THE LIVE DATABASE. Applied on 22 Aug 2026 as
-- `20260822000735_schedule_anonymous_cleanup` with no matching file. Written
-- back so the repo can rebuild the database.
--
-- Abandoned anonymous accounts accumulate forever otherwise: every first launch
-- that never comes back leaves a row, and Supabase does not reap them. The
-- function was written in 0007 but never scheduled.

create extension if not exists pg_cron with schema pg_catalog;

-- Idempotent: unschedule first so re-running does not stack duplicate jobs.
do $$
begin
  perform cron.unschedule('reap-abandoned-anonymous');
exception when others then null;
end $$;

select cron.schedule(
  'reap-abandoned-anonymous',
  '17 4 * * *',   -- 04:17 daily, off the hour to avoid contending with other jobs
  $$select public.reap_abandoned_anonymous_users(30)$$
);
