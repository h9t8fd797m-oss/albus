begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;
select plan(2);
select ok(exists (
  select 1 from public.knowledge_sections part
  join public.knowledge_sections original
    on original.corpus = part.corpus and original.section = '4.2'
  where part.corpus = 'IB_DP' and part.section = '4.2p2'
    and part.keywords = original.keywords and part.keywords <> ''
), 'the command-term continuation retains the glossary retrieval hints');
select ok(exists (
  select 1 from public.search_knowledge('IB_DP', 'What do analyse and evaluate require?', 4)
  where section = '4.2p2'
), 'a question about evaluate retrieves the continuation containing its definition');
select * from finish();
rollback;
