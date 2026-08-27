-- verify-entitlements.sql
--
-- Attacks the entitlement, quota and abuse-detection layers with real accounts
-- and real refusals. Run it after any change to plans, limits, risk scoring or
-- the tables any of them read. Every row must come back `pass = true`.
--
--   psql "$DATABASE_URL" -f scripts/verify-entitlements.sql
--
-- Companion to `verify-rls.sql`, which audits the policy surface. This one
-- assumes the policies are right and tries to get past them anyway.
--
-- ── What it cannot do ───────────────────────────────────────────────────────
--
-- **Concurrency.** Everything here runs on one connection, so it cannot
-- demonstrate a race — and worse, it will report a race-prone gate as clean.
-- That is not hypothetical: this exact suite reported "one winner, all good"
-- against a gate that was handing out two reservations for one slot, because
-- the harness was serialising the requests it thought it was parallelising.
--
-- The concurrency check has to go over HTTP with real sockets:
--
--   for i in $(seq 1 16); do
--     curl -s -X POST "$URL/rest/v1/rpc/check_and_record_ai_usage" \
--       -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN" \
--       -H "Content-Type: application/json" \
--       -d '{"p_kind":"grade","p_model":"claude-opus-5"}' &
--   done; wait
--
-- Count the responses that are a uuid. It must equal the allowance exactly —
-- not "at most", exactly, since a lock that admits too few is also a bug.

\set ON_ERROR_STOP on
\timing off

begin;

create temporary table verify_results (
  n serial primary key, area text, test text, expected text, actual text, pass boolean
) on commit drop;

-- ── Four throwaway accounts ─────────────────────────────────────────────────
--   A  attacker, free            C  a paying Pro account
--   B  victim, free              D  a paying Plus account
--
-- All four are 40 days old so account age contributes nothing to their risk
-- score. A fresh account is scored differently and that is tested separately.
delete from auth.users where email like 'verify+%@albus.test';

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at, is_anonymous,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('00000000-0000-0000-0000-000000000000','aaaaaaaa-0000-4000-8000-000000000001','authenticated','authenticated','verify+a@albus.test','x',now(),now()-interval '40 days',now(),false,'{"provider":"email"}','{}'),
  ('00000000-0000-0000-0000-000000000000','bbbbbbbb-0000-4000-8000-000000000002','authenticated','authenticated','verify+b@albus.test','x',now(),now()-interval '40 days',now(),false,'{"provider":"email"}','{}'),
  ('00000000-0000-0000-0000-000000000000','cccccccc-0000-4000-8000-000000000003','authenticated','authenticated','verify+c@albus.test','x',now(),now()-interval '40 days',now(),false,'{"provider":"email"}','{}'),
  ('00000000-0000-0000-0000-000000000000','dddddddd-0000-4000-8000-000000000004','authenticated','authenticated','verify+d@albus.test','x',now(),now()-interval '40 days',now(),false,'{"provider":"email"}','{}');

insert into public.entitlements (user_id, tier, expires_at) values
  ('cccccccc-0000-4000-8000-000000000003','pro',  now() + interval '30 days'),
  ('dddddddd-0000-4000-8000-000000000004','plus', now() + interval '30 days')
on conflict (user_id) do update set tier = excluded.tier, expires_at = excluded.expires_at;

-- ═══════════════════════════════════════════════════════════════════════════
--  1. Can a client give itself a plan it did not buy?
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare
  A uuid := 'aaaaaaaa-0000-4000-8000-000000000001';
  r text; n integer;
begin
  insert into public.entitlements (user_id, tier) values (A,'free')
    on conflict (user_id) do update set tier = 'free';

  perform set_config('request.jwt.claims', json_build_object('sub',A,'role','authenticated')::text, true);
  execute 'set local role authenticated';

  begin insert into public.entitlements (user_id,tier) values (A,'pro'); r := 'INSERTED';
  exception when others then r := sqlstate; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('spoof','grant self Pro by insert','denied',r,r <> 'INSERTED');
  execute 'set local role authenticated';

  begin
    update public.entitlements set tier='pro' where user_id=A;
    get diagnostics n = row_count; r := 'UPDATED '||n;
  exception when others then r := sqlstate; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('spoof','grant self Pro by update','denied',r,
            r <> 'UPDATED 1' and public.effective_tier(A) = 'free');
  execute 'set local role authenticated';

  begin
    update public.plans set grade_per_week=99, active_tasks=999 where tier='free';
    get diagnostics n = row_count; r := 'UPDATED '||n;
  exception when others then r := sqlstate; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('spoof','rewrite the Free limits in public.plans','denied',r,
            r <> 'UPDATED 1' and (select grade_per_week from public.plans where tier='free') = 0);
  execute 'set local role authenticated';

  begin
    insert into public.plans (tier,rank,price_cents,display_name) values ('godmode',9,0,'God');
    r := 'INSERTED';
  exception when others then r := sqlstate; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('spoof','invent a new tier','denied',r,r <> 'INSERTED');

  begin update public.entitlements set tier='godmode' where user_id=A; r := 'ACCEPTED';
  exception when others then r := sqlstate; end;
  insert into verify_results (area,test,expected,actual,pass)
    values ('spoof','service role writes an unknown tier','rejected by constraint',r,r <> 'ACCEPTED');
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
--  2. Can a client reach another account's anything?
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare
  A uuid := 'aaaaaaaa-0000-4000-8000-000000000001';
  B uuid := 'bbbbbbbb-0000-4000-8000-000000000002';
  C uuid := 'cccccccc-0000-4000-8000-000000000003';
  r text; n integer;
begin
  insert into public.rubrics (id,user_id,name,source)
    values ('dddddddd-0000-4000-8000-00000000000b', B,'B private rubric','custom')
    on conflict (id) do nothing;
  insert into public.ai_usage (user_id,kind,model,input_tokens,output_tokens)
    values (B,'grade','claude-opus-5',100,100);

  perform set_config('request.jwt.claims', json_build_object('sub',A,'role','authenticated')::text, true);
  execute 'set local role authenticated';

  select count(*) into n from public.entitlements where user_id=C;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('isolation','read a stranger''s subscription row','0 rows',n::text,n=0);
  execute 'set local role authenticated';

  select count(*) into n from public.ai_usage where user_id=B;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('isolation','read a stranger''s usage history','0 rows',n::text,n=0);
  execute 'set local role authenticated';

  select count(*) into n from public.rubrics where user_id=B;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('isolation','read a stranger''s rubrics','0 rows',n::text,n=0);
  execute 'set local role authenticated';

  select count(*) into n from public.gradings where user_id=B;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('isolation','read a stranger''s gradings','0 rows',n::text,n=0);
  execute 'set local role authenticated';

  -- The functions that take a uid must be unreachable. Any one of them, made
  -- callable, turns "cannot read another user's data" into "can, one row at a
  -- time".
  begin select public.effective_tier(C) into r;
  exception when others then r := sqlstate; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('isolation','call effective_tier(other)','denied',r,r='42501');
  execute 'set local role authenticated';

  begin select band into r from public.account_risk(C);
  exception when others then r := sqlstate; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('isolation','call account_risk(other)','denied',r,r='42501');
  execute 'set local role authenticated';

  begin select public.ai_spend_count(B,'grade',interval '7 days')::text into r;
  exception when others then r := sqlstate; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('isolation','call ai_spend_count(other)','denied',r,r='42501');
  execute 'set local role authenticated';

  -- my_plan() takes no argument, which is what makes asking about someone else
  -- impossible rather than merely forbidden.
  select tier into r from public.my_plan();
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('isolation','my_plan() answers only about the caller','free',r,r='free');
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
--  3. Can a client rewrite its own usage?
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare A uuid := 'aaaaaaaa-0000-4000-8000-000000000001'; r text; n integer;
begin
  perform set_config('request.jwt.claims', json_build_object('sub',A,'role','authenticated')::text, true);
  execute 'set local role authenticated';

  begin
    delete from public.ai_usage where user_id=A;
    get diagnostics n = row_count; r := 'DELETED '||n;
  exception when others then r := sqlstate; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('tamper','delete own usage rows to reset the meter','denied',r,r not like 'DELETED%');
  execute 'set local role authenticated';

  begin insert into public.ai_usage (user_id,kind,model) values (A,'grade','x'); r := 'INSERTED';
  exception when others then r := sqlstate; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('tamper','forge a usage row','denied',r,r <> 'INSERTED');
  execute 'set local role authenticated';

  begin
    insert into public.gradings (user_id,basis,overall_marks,total_marks,grade_label,feedback,model)
      values (A,'personal',100,100,'7','perfect','x');
    r := 'INSERTED';
  exception when others then r := sqlstate; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('tamper','forge a grading awarding itself full marks','denied',r,r <> 'INSERTED');
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
--  4. Does each plan get exactly what it bought?
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare
  A uuid := 'aaaaaaaa-0000-4000-8000-000000000001';
  C uuid := 'cccccccc-0000-4000-8000-000000000003';
  D uuid := 'dddddddd-0000-4000-8000-000000000004';
  r text;
begin
  -- Free: the planner works, the paid features say so in their own words.
  perform set_config('request.jwt.claims', json_build_object('sub',A,'role','authenticated')::text, true);
  execute 'set local role authenticated';

  begin perform public.check_and_record_ai_usage('chat','claude-haiku-4-5'); r := 'ALLOWED';
  exception when others then r := sqlerrm; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('gate','Free asks Albus a question','PLAN_UPGRADE_REQUIRED',r,r='PLAN_UPGRADE_REQUIRED');
  execute 'set local role authenticated';

  begin perform public.check_and_record_ai_usage('grade','claude-opus-5'); r := 'ALLOWED';
  exception when others then r := sqlerrm; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('gate','Free sends work to the Grader','PLAN_UPGRADE_REQUIRED',r,r='PLAN_UPGRADE_REQUIRED');
  execute 'set local role authenticated';

  begin perform public.check_and_record_ai_usage('breakdown','claude-sonnet-5'); r := 'ALLOWED';
  exception when others then r := sqlerrm; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('gate','Free generates a plan (the core product)','ALLOWED',r,r='ALLOWED');

  -- Plus: two gradings a week, twenty-five messages a month.
  -- Backdated so the hourly burst cap is not what answers.
  insert into public.ai_usage (user_id,kind,model,input_tokens,output_tokens,created_at)
  values (D,'grade','claude-opus-5',10,10, now()-interval '3 days'),
         (D,'grade','claude-opus-5',10,10, now()-interval '2 days');

  perform set_config('request.jwt.claims', json_build_object('sub',D,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin perform public.check_and_record_ai_usage('grade','claude-opus-5'); r := 'ALLOWED';
  exception when others then r := sqlerrm; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('gate','Plus asks for a third grading this week','ALLOWANCE_WEEKLY',r,r='ALLOWANCE_WEEKLY');

  insert into public.ai_usage (user_id,kind,model,input_tokens,output_tokens,created_at)
  select D,'chat','claude-sonnet-5',10,10, now()-interval '10 days' from generate_series(1,25);

  perform set_config('request.jwt.claims', json_build_object('sub',D,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin perform public.check_and_record_ai_usage('chat','claude-sonnet-5'); r := 'ALLOWED';
  exception when others then r := sqlerrm; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('gate','Plus asks a 26th question this month','ALLOWANCE_MONTHLY',r,r='ALLOWANCE_MONTHLY');

  -- Pro: five gradings a week, and chat with no ceiling at all.
  insert into public.ai_usage (user_id,kind,model,input_tokens,output_tokens,created_at)
  select C,'grade','claude-opus-5',10,10, now()-interval '1 day'*g from generate_series(1,5) g;
  insert into public.ai_usage (user_id,kind,model,input_tokens,output_tokens,created_at)
  select C,'chat','claude-sonnet-5',10,10, now()-interval '10 days' from generate_series(1,200);

  perform set_config('request.jwt.claims', json_build_object('sub',C,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin perform public.check_and_record_ai_usage('grade','claude-opus-5'); r := 'ALLOWED';
  exception when others then r := sqlerrm; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('gate','Pro asks for a sixth grading this week','ALLOWANCE_WEEKLY',r,r='ALLOWANCE_WEEKLY');
  execute 'set local role authenticated';

  begin perform public.check_and_record_ai_usage('chat','claude-sonnet-5'); r := 'ALLOWED';
  exception when others then r := sqlerrm; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('gate','Pro asks a 201st question this month (unlimited)','ALLOWED',r,r='ALLOWED');

  -- An expiry in the past is Free, whatever the row says.
  update public.entitlements set expires_at = now()-interval '1 day' where user_id=C;
  insert into verify_results (area,test,expected,actual,pass)
    values ('gate','a Pro subscription that lapsed yesterday','free',public.effective_tier(C),
            public.effective_tier(C)='free');

  perform set_config('request.jwt.claims', json_build_object('sub',C,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin perform public.check_and_record_ai_usage('grade','claude-opus-5'); r := 'ALLOWED';
  exception when others then r := sqlerrm; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('gate','lapsed Pro sends work to the Grader','PLAN_UPGRADE_REQUIRED',r,r='PLAN_UPGRADE_REQUIRED');
  update public.entitlements set expires_at = now()+interval '30 days' where user_id=C;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
--  5. Do the resource caps hold on paths that skip the RPC?
--
--  `authenticated` holds INSERT on assignments, subtasks and rubrics — it has
--  to, RLS is what scopes them. So any limit that lives only inside an RPC is
--  bypassed by a client that simply does not call it. Every one of these was a
--  live bypass before migration 0036.
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare
  A uuid := 'aaaaaaaa-0000-4000-8000-000000000001';
  C uuid := 'cccccccc-0000-4000-8000-000000000003';
  r text; n integer; aid uuid;
begin
  delete from public.assignments where user_id in (A,C);
  delete from public.rubrics where user_id=A;

  perform set_config('request.jwt.claims', json_build_object('sub',A,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  for i in 1..5 loop
    perform public.create_assignment_with_plan('Task '||i,'essay',now()+interval '7 days',60,
      '[{"title":"step","estimated_minutes":30}]'::jsonb);
  end loop;

  begin
    perform public.create_assignment_with_plan('Task 6','essay',now()+interval '7 days',60,
      '[{"title":"step","estimated_minutes":30}]'::jsonb);
    r := 'ALLOWED';
  exception when others then r := sqlerrm; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('caps','Free creates a 6th task through the RPC','PLAN_TASK_LIMIT_REACHED',r,
            r='PLAN_TASK_LIMIT_REACHED');
  execute 'set local role authenticated';

  begin
    insert into public.assignments (user_id,title,task_type,deadline,estimated_minutes,status)
    values (A,'Bypass','essay',now()+interval '7 days',60,'active');
    r := 'INSERTED';
  exception when others then r := sqlerrm; end;
  execute 'reset role';
  select count(*) into n from public.assignments where user_id=A and status='active';
  insert into verify_results (area,test,expected,actual,pass)
    values ('caps','Free inserts a 6th task straight into the table','PLAN_TASK_LIMIT_REACHED',
            r||' / '||n||' active', r='PLAN_TASK_LIMIT_REACHED' and n=5);
  execute 'set local role authenticated';

  -- Reopening finished work is the other way to exceed the cap.
  update public.assignments set status='completed'
   where id = (select id from public.assignments where user_id=A and status='active' limit 1);
  insert into public.assignments (user_id,title,task_type,deadline,estimated_minutes,status)
  values (A,'Fifth again','essay',now()+interval '7 days',60,'active');
  select id into aid from public.assignments where user_id=A and status='completed' limit 1;
  begin update public.assignments set status='active' where id=aid; r := 'REOPENED';
  exception when others then r := sqlerrm; end;
  execute 'reset role';
  select count(*) into n from public.assignments where user_id=A and status='active';
  insert into verify_results (area,test,expected,actual,pass)
    values ('caps','Free reopens finished work to get a 6th active task','PLAN_TASK_LIMIT_REACHED',
            r||' / '||n||' active', r='PLAN_TASK_LIMIT_REACHED' and n=5);
  execute 'set local role authenticated';

  -- The cap must not become a wall around ordinary editing.
  begin
    update public.assignments set title='Renamed'
     where id = (select id from public.assignments where user_id=A and status='active' limit 1);
    r := 'EDITED';
  exception when others then r := sqlerrm; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('caps','rename a task while at the limit','EDITED',r,r='EDITED');
  execute 'set local role authenticated';

  begin
    update public.assignments set status='completed'
     where id = (select id from public.assignments where user_id=A and status='active' limit 1);
    insert into public.assignments (user_id,title,task_type,deadline,estimated_minutes,status)
    values (A,'Next one','essay',now()+interval '7 days',60,'active');
    r := 'CREATED';
  exception when others then r := sqlerrm; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('caps','finishing a task frees a slot','CREATED',r,r='CREATED');

  -- Pro's null limit must mean unlimited, not "limit of zero".
  perform set_config('request.jwt.claims', json_build_object('sub',C,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    for i in 1..25 loop
      insert into public.assignments (user_id,title,task_type,deadline,estimated_minutes,status)
      values (C,'Pro task '||i,'essay',now()+interval '7 days',60,'active');
    end loop;
    r := 'ALL 25 CREATED';
  exception when others then r := sqlerrm; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('caps','Pro creates 25 active tasks (unlimited)','ALL 25 CREATED',r,r='ALL 25 CREATED');

  -- Rubrics: three inserts, then the fourth. Separate statements on purpose —
  -- a loop inside one exception block rolls the first three back with the
  -- fourth, and the count then reads 0 for reasons that have nothing to do
  -- with the limit.
  perform set_config('request.jwt.claims', json_build_object('sub',A,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  insert into public.rubrics (user_id,name,source) values (A,'Rubric 1','custom');
  insert into public.rubrics (user_id,name,source) values (A,'Rubric 2','custom');
  insert into public.rubrics (user_id,name,source) values (A,'Rubric 3','custom');
  begin insert into public.rubrics (user_id,name,source) values (A,'Rubric 4','custom'); r := 'INSERTED';
  exception when others then r := sqlerrm; end;
  execute 'reset role';
  select count(*) into n from public.rubrics where user_id=A;
  insert into verify_results (area,test,expected,actual,pass)
    values ('caps','Free saves a 4th rubric (limit 3)','RUBRIC_PLAN_LIMIT',
            r||' / '||n||' held', r='RUBRIC_PLAN_LIMIT' and n=3);

  execute 'set local role authenticated';
  select id into aid from public.assignments where user_id=A and status='active' limit 1;
  begin
    for i in 1..70 loop
      insert into public.subtasks (user_id,assignment_id,title,ordinal,estimated_minutes)
      values (A,aid,'step '||i,i,30);
    end loop;
    r := 'ALL 70 CREATED';
  exception when others then r := sqlerrm; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('caps','flood one plan with 70 steps','TOO_MANY_SUBTASKS',r,r='TOO_MANY_SUBTASKS');
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
--  6. Does risk catch a farm without catching a school?
--
--  This is the section to read first when tuning anything in `account_risk`.
--  The farm test failing means abuse gets through. The school test failing
--  means a computer room full of students gets refused, which is worse.
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare
  A uuid := 'aaaaaaaa-0000-4000-8000-000000000001';
  u uuid; ip text := repeat('5c',32); dev text := repeat('fa',32); farmip text := repeat('fb',32);
  b text; sc integer; rs jsonb; r text; i integer; allowed integer := 0;
begin
  delete from auth.users where email like 'school+%@albus.test' or email like 'farm+%@albus.test';

  -- Thirty students, one school network, thirty devices, all new this morning.
  for i in 1..30 loop
    u := ('55555555-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid;
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
                            created_at,updated_at,is_anonymous,raw_app_meta_data,raw_user_meta_data)
    values ('00000000-0000-0000-0000-000000000000',u,'authenticated','authenticated',
            'school+'||i||'@albus.test','x',now(),now()-interval '20 minutes',now(),true,'{}','{}');
    perform public.record_identity_link(u,'ip_prefix', ip);
    perform public.record_identity_link(u,'device', md5(u::text)||md5(u::text));
  end loop;

  select score, band, reasons into sc, b, rs
    from public.account_risk('55555555-0000-4000-8000-000000000001');
  insert into verify_results (area,test,expected,actual,pass)
    values ('risk','30 students on one school network, all new today','not blocked',
            'score '||sc||' band '||b||' families '||(rs->>'families'), b in ('normal','elevated'));

  -- Six accounts, one device, one afternoon.
  for i in 1..6 loop
    u := ('66666666-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid;
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
                            created_at,updated_at,is_anonymous,raw_app_meta_data,raw_user_meta_data)
    values ('00000000-0000-0000-0000-000000000000',u,'authenticated','authenticated',
            'farm+'||i||'@albus.test','x',now(),now()-interval '5 minutes',now(),true,'{}','{}');
    perform public.record_identity_link(u,'device', dev);
    perform public.record_identity_link(u,'ip_prefix', farmip);
  end loop;

  select score, band, reasons into sc, b, rs
    from public.account_risk('66666666-0000-4000-8000-000000000001');
  insert into verify_results (area,test,expected,actual,pass)
    values ('risk','6 accounts from one device in one afternoon','severe',
            'score '||sc||' band '||b||' families '||(rs->>'families'), b='severe');

  perform set_config('request.jwt.claims','{"sub":"66666666-0000-4000-8000-000000000001","role":"authenticated"}',true);
  execute 'set local role authenticated';
  begin perform public.check_and_record_ai_usage('breakdown','claude-sonnet-5'); r := 'ALLOWED';
  exception when others then r := sqlerrm; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('risk','a severe-risk account generates a plan','ABUSE_SUSPECTED',r,r='ABUSE_SUSPECTED');

  -- The same signals, on an account that paid. Payment is the strongest
  -- identity check in this system and it caps the band at elevated.
  insert into public.entitlements (user_id,tier,expires_at)
  values ('66666666-0000-4000-8000-000000000001','pro',now()+interval '30 days')
  on conflict (user_id) do update set tier='pro', expires_at=excluded.expires_at;

  select band into b from public.account_risk('66666666-0000-4000-8000-000000000001');
  insert into verify_results (area,test,expected,actual,pass)
    values ('risk','the same farm signals on a paying account','elevated, never blocked',b,b='elevated');

  perform set_config('request.jwt.claims','{"sub":"66666666-0000-4000-8000-000000000001","role":"authenticated"}',true);
  execute 'set local role authenticated';
  begin perform public.check_and_record_ai_usage('breakdown','claude-sonnet-5'); r := 'ALLOWED';
  exception when others then r := sqlerrm; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('risk','that paying account generates a plan','ALLOWED',r,r='ALLOWED');
  delete from public.entitlements where user_id='66666666-0000-4000-8000-000000000001';

  -- Elevated buys friction, not a door: Free's 6 breakdowns an hour become 3.
  delete from public.ai_usage where user_id='55555555-0000-4000-8000-000000000001';
  perform set_config('request.jwt.claims','{"sub":"55555555-0000-4000-8000-000000000001","role":"authenticated"}',true);
  execute 'set local role authenticated';
  for i in 1..8 loop
    begin perform public.check_and_record_ai_usage('breakdown','claude-sonnet-5');
      allowed := allowed + 1;
    exception when others then null; end;
  end loop;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('risk','elevated halves the hourly burst (Free is 6/hour)','3',allowed::text,allowed=3);

  allowed := 0;
  delete from public.ai_usage where user_id=A;
  perform set_config('request.jwt.claims', json_build_object('sub',A,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  for i in 1..8 loop
    begin perform public.check_and_record_ai_usage('breakdown','claude-sonnet-5');
      allowed := allowed + 1;
    exception when others then null; end;
  end loop;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('risk','a normal account gets the full hourly burst','6',allowed::text,allowed=6);

  -- Every band recovers without us. The signals age out of their own windows,
  -- so there is no list to be on and nothing to appeal to.
  update auth.users set created_at = created_at - interval '25 hours'
   where email like 'farm+%@albus.test';
  select score, band into sc, b from public.account_risk('66666666-0000-4000-8000-000000000001');
  insert into verify_results (area,test,expected,actual,pass)
    values ('risk','the same farm, 25 hours later','no longer severe',
            'score '||sc||' band '||b, b <> 'severe');
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
--  7. Is the risk machinery itself out of reach?
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare A uuid := 'aaaaaaaa-0000-4000-8000-000000000001'; r text; n integer;
begin
  perform set_config('request.jwt.claims', json_build_object('sub',A,'role','authenticated')::text, true);
  execute 'set local role authenticated';

  begin select count(*) into n from public.identity_links; r := 'READ '||n;
  exception when others then r := sqlstate; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('risk','read identity_links','denied',r,r not like 'READ%');
  execute 'set local role authenticated';

  begin insert into public.identity_links (user_id,kind,hash) values (A,'device',repeat('0',64));
    r := 'INSERTED';
  exception when others then r := sqlstate; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('risk','write an identity_links row','denied',r,r <> 'INSERTED');
  execute 'set local role authenticated';

  begin select count(*) into n from public.security_events; r := 'READ '||n;
  exception when others then r := sqlstate; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('risk','read the security log','denied',r,r not like 'READ%');
  execute 'set local role authenticated';

  begin perform public.log_security_event(A,'fake','info'); r := 'CALLED';
  exception when others then r := sqlstate; end;
  execute 'reset role';
  insert into verify_results (area,test,expected,actual,pass)
    values ('risk','write to the security log','denied',r,r='42501');
end $$;

-- No raw identifier may ever reach a column. This is a property of the whole
-- table rather than of one write path, so it is asserted as one.
insert into verify_results (area,test,expected,actual,pass)
select 'privacy','every identity_links row is a digest, not a value','0 raw',
       count(*) filter (where hash !~ '^[0-9a-f]{64}$')::text || ' raw-looking',
       count(*) filter (where hash !~ '^[0-9a-f]{64}$') = 0
  from public.identity_links;

-- ═══════════════════════════════════════════════════════════════════════════
select area, test, expected, actual,
       case when pass then 'pass' else '*** FAIL ***' end as result
  from verify_results order by n;

select count(*) filter (where not pass) as failures,
       count(*) as total,
       case when count(*) filter (where not pass) = 0
            then 'all green'
            else '*** ' || count(*) filter (where not pass) || ' FAILED ***' end as verdict
  from verify_results;

-- ── Clean up ────────────────────────────────────────────────────────────────
delete from auth.users
 where email like 'verify+%@albus.test'
    or email like 'school+%@albus.test'
    or email like 'farm+%@albus.test';

commit;
