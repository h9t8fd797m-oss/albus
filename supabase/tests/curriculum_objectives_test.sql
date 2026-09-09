begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;
select plan(7);
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
select is((select count(*) from public.assessment_objectives
           where btrim(code) = '' or btrim(name) = ''), 0::bigint,
          'objective codes and names cannot be blank in the seeded corpus');
select is((select count(*) from public.assessment_objectives
           where (weighting_min is null) <> (weighting_max is null)), 0::bigint,
          'objective weighting ranges have both bounds or neither');
select is((select count(*) from public.course_templates c
           where c.code in ('IB_DP_MATHS_AA', 'IB_DP_MATHS_AI')
           and (select count(*) from public.assessment_objectives o
                where o.course_template_id = c.id) = 6), 2::bigint,
          'both mathematics courses retain all six objectives');
select * from finish();
rollback;
