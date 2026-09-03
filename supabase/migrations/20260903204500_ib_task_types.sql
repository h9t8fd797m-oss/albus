-- The IB assessments a student actually spends their two years on.
--
-- `task_type` has been the eight generic shapes since 0004 — essay, problem
-- set, lab report, and so on. None of them is what an IB student is really
-- doing when they say "I'm working on my IA": an internal assessment is a
-- months-long, criteria-marked piece with a supervisor and a word count, and
-- calling it an "essay" throws away every one of those facts before the
-- planner ever sees the task.
--
-- These six are added because each one produces a genuinely different plan,
-- not because the list looked short:
--
--   internal_assessment  every subject has one; criteria-marked, multi-stage,
--                        and the single biggest non-exam thing a student does
--   extended_essay       4,000 words, a supervisor, formal checkpoints — the
--                        longest single task in the Diploma
--   tok_essay            one of six prescribed titles, externally marked
--   tok_exhibition       three objects and a commentary; internally marked.
--                        Separate from the essay because it is a different
--                        piece of work with different criteria, not a variant
--   mock_exam            revision and timed practice, not production of work
--   final_exam           the same shape as a mock, at higher stakes and with
--                        a longer runway
--
-- The generic eight stay. A student still sets homework, still does reading,
-- and a task that is genuinely just an essay should still be called one.
--
-- Widening a CHECK is safe for existing rows by construction: every value that
-- satisfied the old constraint satisfies this one. Nothing is rewritten.

alter table public.assignments
  drop constraint if exists assignments_task_type_check;

alter table public.assignments
  add constraint assignments_task_type_check
  check (task_type in (
    -- The original eight.
    'essay', 'problem_set', 'lab_report', 'reading',
    'revision', 'project', 'presentation', 'other',
    -- IB assessments.
    'internal_assessment', 'extended_essay',
    'tok_essay', 'tok_exhibition',
    'mock_exam', 'final_exam'
  ));

comment on column public.assignments.task_type is
  'What kind of work this is. The eight generic shapes plus the six IB assessments. Drives how the planner decomposes the task — an internal assessment and an essay are not the same job.';
