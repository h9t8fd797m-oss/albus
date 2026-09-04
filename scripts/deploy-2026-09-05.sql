-- One-shot production deploy: history repair + the two pending migrations.
--
-- WHY THIS IS ONE FILE. Applying a migration through the dashboard (or the
-- MCP apply_migration tool) stamps the *moment of application* as its version,
-- not the version in its filename. That is not a hypothesis: production records
-- `production_financial_safety` as 20260901192220 while its file is
-- 20260830104329, because that is exactly how it was applied. Repairing the
-- history and then hand-applying two more migrations the same way would fix
-- twelve rows and immediately create two more wrong ones.
--
-- So this repairs the history AND applies both migrations AND records them
-- under their real filename versions, in a single transaction. Afterwards the
-- recorded history matches supabase/migrations/ exactly, and `supabase db push`
-- becomes safe to use for the first time.
--
-- ALL OR NOTHING. Any failure rolls the whole thing back and production is
-- exactly as it was. The verification block at the end raises rather than
-- letting a partial state commit.
--
-- HOW TO RUN: paste the whole file into the Supabase SQL editor and execute.
--   https://supabase.com/dashboard/project/ssvehwhblgqtvqkfbkbj/sql/new

begin;

-- ---------------------------------------------------------------- 1. snapshot
create table if not exists supabase_migrations.schema_migrations_backup_20260905 as
  select * from supabase_migrations.schema_migrations;

-- ------------------------------------------------------- 2. repair the history
-- Bookkeeping only. No schema is touched by this section; every migration
-- below is already applied, it is only recorded under the wrong version.
update supabase_migrations.schema_migrations set version = '0030' where version = '20260826172040' and name = 'grading_free_quota';
update supabase_migrations.schema_migrations set version = '0031' where version = '20260826174458' and name = 'grading_basis_and_allowance';
update supabase_migrations.schema_migrations set version = '0032' where version = '20260826180120' and name = 'grading_reuse';
update supabase_migrations.schema_migrations set version = '0033' where version = '20260826194228' and name = 'final_grade_and_usage_truth';
update supabase_migrations.schema_migrations set version = '0034' where version = '20260827103738' and name = 'three_plans';
update supabase_migrations.schema_migrations set version = '0035' where version = '20260827103842' and name = 'account_risk';
update supabase_migrations.schema_migrations set version = '0036' where version = '20260827104719' and name = 'close_two_bypasses';
update supabase_migrations.schema_migrations set version = '0037' where version = '20260827210655' and name = 'chat_becomes_pro_only';

update supabase_migrations.schema_migrations set version = '20260830104329' where version = '20260901192220' and name = 'production_financial_safety';
update supabase_migrations.schema_migrations set version = '20260830114547' where version = '20260901192432' and name = 'close_direct_write_and_request_abuse';
update supabase_migrations.schema_migrations set version = '20260831174227' where version = '20260901225530' and name = 'drop_scaffold_course_templates';

-- Applied but never recorded at all. Its DDL is demonstrably live:
-- profiles.exam_session, courses.level, dp_year_for_session(), set_ib_context().
insert into supabase_migrations.schema_migrations (version, name)
  select '20260901200000', 'ib_student_context'
   where not exists (select 1 from supabase_migrations.schema_migrations where version = '20260901200000');

-- ------------------------------------------- 3. migration 20260903204500
-- IB task types. Widening a CHECK is safe for existing rows by construction:
-- every value that satisfied the old constraint satisfies this one.
alter table public.assignments
  drop constraint if exists assignments_task_type_check;

alter table public.assignments
  add constraint assignments_task_type_check
  check (task_type in (
    'essay', 'problem_set', 'lab_report', 'reading',
    'revision', 'project', 'presentation', 'other',
    'internal_assessment', 'extended_essay',
    'tok_essay', 'tok_exhibition',
    'mock_exam', 'final_exam'
  ));

comment on column public.assignments.task_type is
  'What kind of work this is. The eight generic shapes plus the six IB assessments. Drives how the planner decomposes the task — an internal assessment and an essay are not the same job.';

insert into supabase_migrations.schema_migrations (version, name)
  select '20260903204500', 'ib_task_types'
   where not exists (select 1 from supabase_migrations.schema_migrations where version = '20260903204500');

-- ------------------------------------------- 4. migration 20260903223000
-- Stop account deletion erasing what it cost. SET NULL anonymises the row
-- rather than deleting it; RLS still hides it, because both policies compare
-- auth.uid() = user_id and NULL = uid is NULL, not true.
alter table public.ai_usage
  alter column user_id drop not null;

alter table public.ai_usage
  drop constraint ai_usage_user_id_fkey;

alter table public.ai_usage
  add constraint ai_usage_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;

insert into supabase_migrations.schema_migrations (version, name)
  select '20260903223000', 'preserve_ai_cost_history'
   where not exists (select 1 from supabase_migrations.schema_migrations where version = '20260903223000');

-- ------------------------------------------------------------- 5. verify
-- Refuse to commit anything partial.
do $$
declare
  v_missing text[];
  v_rule    text;
  v_notnull boolean;
  v_types   boolean;
begin
  -- Every migration file must now be recorded under its filename version.
  select array_agg(v order by v) into v_missing
    from unnest(array[
      '0030','0031','0032','0033','0034','0035','0036','0037',
      '20260830104329','20260830114547','20260831174227','20260901200000',
      '20260903204500','20260903223000'
    ]) as v
   where not exists (select 1 from supabase_migrations.schema_migrations m where m.version = v);
  if v_missing is not null then
    raise exception 'history still missing: %', v_missing;
  end if;

  -- And none of the old, wrongly-stamped versions may survive.
  if exists (
    select 1 from supabase_migrations.schema_migrations
     where version in ('20260826172040','20260826174458','20260826180120','20260826194228',
                       '20260827103738','20260827103842','20260827104719','20260827210655',
                       '20260901192220','20260901192432','20260901225530')
  ) then
    raise exception 'a wrongly-stamped version survived the repair';
  end if;

  select pg_get_constraintdef(oid) like '%internal_assessment%' into v_types
    from pg_constraint where conname = 'assignments_task_type_check';
  if not coalesce(v_types, false) then
    raise exception 'assignments_task_type_check does not include the IB types';
  end if;

  select case con.confdeltype when 'n' then 'SET NULL' when 'c' then 'CASCADE' end
    into v_rule
    from pg_constraint con
   where con.conrelid = 'public.ai_usage'::regclass
     and con.contype = 'f' and con.conname = 'ai_usage_user_id_fkey';
  if v_rule is distinct from 'SET NULL' then
    raise exception 'ai_usage.user_id delete rule is %, expected SET NULL', v_rule;
  end if;

  select attnotnull into v_notnull
    from pg_attribute
   where attrelid = 'public.ai_usage'::regclass and attname = 'user_id';
  if v_notnull then
    raise exception 'ai_usage.user_id is still NOT NULL; SET NULL could never fire';
  end if;

  raise notice 'deploy verified: history matches supabase/migrations/, both migrations applied';
end $$;

commit;
