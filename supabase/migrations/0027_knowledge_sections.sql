-- 0027_knowledge_sections
--
-- The reference corpus Ask Albus answers from, one row per subsection.
--
-- Why sections rather than one document: the IB knowledge base is ~40k tokens.
-- Attaching it to every message would cost more per question than the answer,
-- and would bury the two paragraphs that matter under thirteen sections that do
-- not. The document is already written as a lookup structure — numbered,
-- cross-referenced, one topic per subsection — so the retrieval unit is the
-- subsection it was authored as, not an arbitrary chunk.
--
-- Retrieval is Postgres full-text search rather than embeddings. No extension,
-- no embedding pipeline to keep in step with the text, one query per question,
-- and the reason an answer cited a section is inspectable. Titles and curated
-- keywords are weighted above body text so a question phrased in a student's
-- words ("how many words for my IA") still reaches the section written in the
-- IB's ("word-count thresholds").
--
-- Read-only reference data. Every signed-in student reads the same rows; there
-- is nothing per-user here, so there is nothing here to leak between users.

create table public.knowledge_sections (
  id            uuid primary key default gen_random_uuid(),
  -- Bound to a curriculum, so a typo cannot create a corpus nothing can reach.
  corpus        text not null references public.curricula(code) on delete cascade,
  -- '5.3', '7.2'. The document's own numbering, so an answer can be traced back
  -- to the paragraph it came from.
  section       text not null check (char_length(section) between 1 and 16),
  title         text not null check (char_length(title) between 1 and 300),
  -- The '## 5. ACADEMIC INTEGRITY' this sits under. Cheap context for the model
  -- and the difference between "5.3" meaning something and meaning nothing.
  parent_title  text check (char_length(parent_title) <= 300),
  body          text not null check (char_length(body) between 1 and 20000),
  -- Our own retrieval hints, not part of the answer. Weighted with the title.
  keywords      text not null default '',
  -- The handful of sections that must reach the model on every question in this
  -- corpus: the rules that stop it inventing an IB rule or quoting a copyrighted
  -- descriptor. Small enough to always afford, and what keeps the rest honest.
  always_include boolean not null default false,
  ordinal       integer not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (corpus, section),

  search tsvector generated always as (
    setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
    setweight(to_tsvector('english', coalesce(keywords, '')), 'A') ||
    setweight(to_tsvector('english', coalesce(body, '')), 'D')
  ) stored
);

create index knowledge_sections_search_idx on public.knowledge_sections using gin (search);
create index knowledge_sections_corpus_idx on public.knowledge_sections (corpus, ordinal);
-- Partial: the always-included set is tiny and read on every question.
create index knowledge_sections_always_idx on public.knowledge_sections (corpus)
  where always_include;

create trigger knowledge_sections_touch
  before update on public.knowledge_sections
  for each row execute function public.set_updated_at();

alter table public.knowledge_sections enable row level security;

-- Revoke before granting: Supabase's default privileges hand every new public
-- table all four CRUD verbs to `authenticated`, so a narrower grant on its own
-- adds nothing.
revoke all on public.knowledge_sections from anon, public;
revoke all on public.knowledge_sections from authenticated;
grant select on public.knowledge_sections to authenticated;

create policy knowledge_sections_read_all on public.knowledge_sections
  for select to authenticated using (true);

-- Retrieval, as a function rather than a client-built query.
--
-- `websearch_to_tsquery` is the one parser that never raises on arbitrary text —
-- `to_tsquery` throws on a stray operator, which would turn a student's question
-- mark into a 500. The student's message is a parameter here, never concatenated,
-- so the only thing a hostile question can do is match the wrong sections.
--
-- Its output is then re-joined with `|` instead of `&`. Every tsquery parser in
-- Postgres ANDs the terms, which for a question is close to useless: "how many
-- words can my biology IA be" required one section to contain *word* and
-- *biology* and *IA*, and nothing did — the corpus returned nothing but the
-- always-included rules for almost every real question. Matching any term and
-- ranking by how many hit is what a question needs. The substitution is done on
-- a parsed tsquery rather than on the student's text, so it stays an operator
-- swap and never becomes an injection point.
--
-- `security invoker`, so the caller's RLS decides what is readable. Nothing in
-- this table is private, but a reference-data reader has no business running as
-- its definer either.
create function public.search_knowledge(
  p_corpus text,
  p_query  text,
  p_limit  integer default 4
)
returns table (section text, title text, parent_title text, body text)
language sql
stable
security invoker
set search_path = public
as $$
  with q as (
    select nullif(
      replace(
        websearch_to_tsquery('english', left(coalesce(p_query, ''), 1000))::text,
        ' & ', ' | '
      ),
      ''
    )::tsquery as tsq
  ),
  -- The always-included rules do not compete with the question for slots.
  -- Folding them into one ranked list meant two of every four sections were
  -- spent on text the student did not ask about.
  matched as (
    select k.section, k.title, k.parent_title, k.body,
           ts_rank(k.search, q.tsq) as rank
    from public.knowledge_sections k, q
    where k.corpus = p_corpus
      and not k.always_include
      and k.search @@ q.tsq
    order by rank desc, k.ordinal
    -- Bounded here rather than trusted from the caller: this is the only thing
    -- standing between one question and a prompt with the whole corpus in it.
    limit greatest(1, least(coalesce(p_limit, 4), 8))
  )
  -- Best match first, not document order.
  --
  -- The caller also enforces a character budget, and it spends it in the order
  -- these arrive. Returning them by section number meant the budget went to
  -- whichever section happened to come earliest in the document: a question
  -- about the History IA retrieved the sciences and mathematics sections, ran
  -- out of room, and dropped the History one — which was ranked first. Albus
  -- then said, honestly and wrongly, that it did not have History's criteria.
  select t.section, t.title, t.parent_title, t.body
  from (
    select k.section, k.title, k.parent_title, k.body, 0 as tier, 0::real as rank
    from public.knowledge_sections k
    where k.corpus = p_corpus and k.always_include
    union all
    select m.section, m.title, m.parent_title, m.body, 1 as tier, m.rank
    from matched m
  ) t
  order by t.tier, t.rank desc, t.section;
$$;

revoke all on function public.search_knowledge(text, text, integer) from public, anon;
grant execute on function public.search_knowledge(text, text, integer) to authenticated;

do $$
begin
  if has_table_privilege('authenticated', 'public.knowledge_sections', 'INSERT')
     or has_table_privilege('authenticated', 'public.knowledge_sections', 'UPDATE')
     or has_table_privilege('authenticated', 'public.knowledge_sections', 'DELETE') then
    raise exception 'knowledge_sections must be read-only to authenticated';
  end if;
  if has_table_privilege('anon', 'public.knowledge_sections', 'SELECT') then
    raise exception 'anon must not read knowledge_sections';
  end if;
  if has_function_privilege('anon', 'public.search_knowledge(text, text, integer)', 'EXECUTE') then
    raise exception 'anon must not execute search_knowledge';
  end if;
end $$;
