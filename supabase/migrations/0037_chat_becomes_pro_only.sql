-- 0037 — Ask Albus stops being a tab and becomes a Pro feature inside a task.
--
-- Applied by hand and verified. The CI deploy workflow has no secrets and never
-- runs, so this repo is not the source of truth for this database.
--
-- Three things change, and the reasoning is the same for all of them: the value
-- was never the chat box, it was the grounding. A conversation that already
-- knows which assignment you mean, what its rubric says and when it is due is
-- worth paying for. A general chatbot competes with the free frontier products
-- every student already has, and loses.
--
--   * Free and Plus get none. Plus buys planning and marking, which is a
--     legible ladder — "how much work do you need marked" — in a way that
--     "25 messages" never was.
--   * Pro gets 300 a month, not "unlimited". Measured, a grounded message costs
--     about €0.0088; 300 is €2.64 against €10.53 of net revenue, and it is ten
--     a day for questions about your own assignments. Unlimited bounded only by
--     a 300/day rate limit was a €79/month ceiling on a €10.53 subscription.
--   * The hourly rate limit comes down with it. Per-assignment questions arrive
--     at human pace; 20/hour was sized for a chat tab nobody is going to open.
update public.plans set
  chat_per_month = 0,
  chat_per_hour  = 0,
  chat_per_day   = 0,
  updated_at     = now()
where tier in ('free', 'plus');

update public.plans set
  chat_per_month = 300,
  chat_per_hour  = 12,
  chat_per_day   = 40,
  updated_at     = now()
where tier = 'pro';

comment on column public.plans.chat_per_month is
  'Ask Albus, asked from inside an assignment. Pro only — NULL would be unlimited, and unlimited is what this migration exists to remove.';
