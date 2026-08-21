-- scripts/verify-rls.sql
-- Paste into the Supabase SQL editor (or psql) after ANY schema change.
-- Part 1 audits the policy surface. Part 2 actually tries to breach it.

-- ── 1. every public table: RLS on, anon locked out, restrictive present ──
select
  c.relname                                            as table_name,
  c.relrowsecurity                                     as rls_on,
  count(p.polname) filter (where p.polpermissive)      as permissive,
  count(p.polname) filter (where not p.polpermissive)  as restrictive,
  has_table_privilege('anon', c.oid, 'SELECT')         as anon_can_select
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
left join pg_policy p on p.polrelid = c.oid
where n.nspname = 'public' and c.relkind = 'r'
group by c.relname, c.relrowsecurity, c.oid
order by c.relname;
-- Expect: rls_on = true and anon_can_select = false on EVERY row.
-- User-owned tables must show restrictive >= 1.

-- ── 2. live breach attempt ───────────────────────────────────────────────
create or replace function pg_temp.rls_probe()
returns table(check_name text, result text, expected text, pass boolean)
language plpgsql as $$
declare
  a uuid := '11111111-1111-4111-8111-111111111111';
  b uuid := '22222222-2222-4222-8222-222222222222';
  v int; l int; blocked boolean := false; upd int;
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          created_at, updated_at, is_anonymous)
  values (a,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',null,'',now(),now(),true),
         (b,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',null,'',now(),now(),true);

  select count(*) into v from public.profiles where id in (a,b);
  return query select 'profile trigger fired', v::text, '2', v = 2;

  insert into public.assignments (user_id,title,task_type,deadline,estimated_minutes)
  values (a,'A private essay','essay',now()+interval '3 days',120),
         (b,'B private essay','essay',now()+interval '3 days',120);

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub',a,'role','authenticated','is_anonymous',true)::text, true);

  select count(*) into v from public.assignments;
  return query select 'A sees only own assignments', v::text, '1', v = 1;
  select count(*) into l from public.assignments where user_id = b;
  return query select 'A cannot read B assignments', l::text, '0', l = 0;
  select count(*) into l from public.profiles where id = b;
  return query select 'A cannot read B profile', l::text, '0', l = 0;

  begin
    insert into public.assignments (user_id,title,task_type,deadline,estimated_minutes)
    values (b,'forged','essay',now()+interval '1 day',60);
  exception when others then blocked := true;
  end;
  return query select 'A cannot forge row owned by B', blocked::text, 'true', blocked;

  with u as (update public.assignments set title='hijacked' where user_id=b returning 1)
  select count(*) into upd from u;
  return query select 'A cannot update B rows', upd::text, '0', upd = 0;

  begin
    blocked := false;
    insert into public.entitlements (user_id, tier) values (a,'plus');
  exception when others then blocked := true;
  end;
  return query select 'A cannot grant self Plus', blocked::text, 'true', blocked;

  reset role;
  delete from auth.users where id in (a,b);
end $$;

select * from pg_temp.rls_probe();
-- Every row must show pass = true. One false is a data-leak bug; stop and fix.
