-- 0032 — never pay to mark the same work twice.
--
-- The single largest saving available on this endpoint, and it costs one
-- column. A student taps Grade, reads the result, backs out and taps it again;
-- or re-grades without having edited anything; or the request is retried after
-- a dropped connection. Today every one of those is a fresh Opus call over a
-- full essay.
--
-- The hash covers the work *and* what it was marked against — rubric identity
-- and the student's presentation preference — because the same essay marked
-- against a different rubric, or asked for on a different scale, is a
-- different answer and must not be served from a previous one.
--
-- Scoped to the owner. `gradings` is RLS-protected already, and the lookup
-- filters on user_id explicitly as well: a hash collision must never be able to
-- hand one student another student's marks.

alter table public.gradings
  add column if not exists work_hash text;

comment on column public.gradings.work_hash is
  'sha256 of normalised work + rubric identity + presentation. Used to return an existing grading instead of paying to produce the same one again.';

-- Partial: rows written before this column existed have no hash and should not
-- occupy space in the index or ever be matched.
create index if not exists gradings_reuse_idx
  on public.gradings (user_id, work_hash)
  where work_hash is not null;
