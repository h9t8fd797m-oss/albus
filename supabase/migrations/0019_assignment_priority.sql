-- 0019_assignment_priority
--
-- Priority, which the add flow asks for and the scheduler reads.
--
-- Deliberately three values, not a number. A 1-10 slider invites a student to
-- mark everything an 8, and a scheduler cannot act on a distinction the student
-- did not really make.
--
-- The scheduling rule this feeds is in `Scheduler.priorityOrder`: priority
-- orders work *within* a deadline and never across one. Marking a maths problem
-- set "high" must not be able to make an essay due tomorrow miss its date.

alter table public.assignments
  add column priority text not null default 'normal'
    check (priority in ('low','normal','high'));

-- Deadline stays the leading key; priority only breaks ties among work that is
-- already competing for the same window, which is exactly what the index shape
-- below supports.
create index assignments_user_deadline_priority_idx
  on public.assignments(user_id, deadline, priority);
