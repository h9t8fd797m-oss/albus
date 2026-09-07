begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;
select plan(4);
select is((select count(*) from public.assessment_objectives
           where weighting_min > weighting_max), 0::bigint,
          'assessment objective weighting ranges are not reversed');
select is((select count(*) from public.assessment_objectives o
           join public.course_templates c on c.id = o.course_template_id
           where c.code in ('IB_DP_BIOLOGY', 'IB_DP_CHEMISTRY', 'IB_DP_PHYSICS')),
          12::bigint, 'the three science objective sets are seeded');
select throws_ok($$
  insert into public.assessment_objectives
    (course_template_id, code, name, weighting_min, weighting_max, ordinal)
  select id, 'AO_GUARD_PROBE', 'Guard fixture', 50, 20, 999
  from public.course_templates limit 1
$$, '23514', null, 'a reversed weighting insert fails with check_violation (23514)');
select is((select count(*) from public.assessment_objectives where code = 'AO_GUARD_PROBE'),
          0::bigint, 'the rejected fixture did not persist');
select * from finish();
rollback;
