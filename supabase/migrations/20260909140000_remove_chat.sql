-- 20260909140000_remove_chat
--
-- Albus is no longer an IB chatbot. The product is a study-hour planner that
-- runs locally, a rubric library, and AI that breaks work down and marks it.
-- Ask Albus is withdrawn, so the retrieval corpus it grounded itself in has no
-- reader left.
--
-- WHAT THIS DROPS. `knowledge_sections` and `search_knowledge` are
-- self-contained: nothing references the table, and the only two callers of the
-- function -- `_shared/knowledge.ts` and one pgTAP test -- are deleted in this
-- same change. Dropping them removes the whole IB reference corpus from the
-- database. The source document is not lost; it lives outside the repo and the
-- generated seed remains in Git history.
--
-- WHAT THIS DELIBERATELY DOES NOT DROP. `plans.chat_per_month`,
-- `chat_per_hour` and `chat_per_day` stay. They are read inside
-- `check_and_record_ai_usage` and its callers in 0035 and 0036 -- the quota
-- functions the concurrency suite attacks. Rewriting those to remove three
-- columns would be surgery on the most safety-critical code in the schema to
-- delete fields that cost nothing to leave. Setting every tier to zero makes
-- them inert: any future caller asking for chat quota is refused by the same
-- path that already refuses Free.
--
-- `ai_usage` rows with kind = 'chat' are history and stay. Deleting them would
-- rewrite what students were actually charged.

begin;

drop function if exists public.search_knowledge(text, text, integer);
drop table if exists public.knowledge_sections;

update public.plans
   set chat_per_month = 0,
       chat_per_hour  = 0,
       chat_per_day   = 0;

do $$
begin
  if to_regclass('public.knowledge_sections') is not null then
    raise exception 'knowledge_sections survived the drop';
  end if;
  if to_regprocedure('public.search_knowledge(text,text,integer)') is not null then
    raise exception 'search_knowledge survived the drop';
  end if;
  if exists (select 1 from public.plans
              where coalesce(chat_per_month, 0) > 0
                 or coalesce(chat_per_hour, 0) > 0
                 or coalesce(chat_per_day, 0) > 0) then
    raise exception 'a plan still grants chat quota';
  end if;
end $$;

commit;
