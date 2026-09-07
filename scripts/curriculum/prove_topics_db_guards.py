"""A passing corpus assertion needs evidence that bad rows would turn it red.

Each fixture runs inside the test's rollback-only transaction. The final clean
run proves that neither fixture survived. Only the local Supabase CLI is used.
"""
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
TEST = ROOT / 'supabase/tests/curriculum_topics_test.sql'
fixtures = {
    'duplicate ordinals': (2, """
insert into public.syllabus_topics (course_template_id, name, ordinal)
select course_template_id, 'Guard fixture', 100000
from public.syllabus_topics limit 1;
insert into public.syllabus_topics (course_template_id, name, ordinal)
select course_template_id, 'Guard fixture', 100000
from public.syllabus_topics where ordinal = 100000 limit 1;
"""),
    'one-topic outline': (3, """
insert into public.course_templates (curriculum_code, code, name)
values ('IB_DP', 'ALBUS_GUARD_PROBE', 'Guard fixture');
insert into public.syllabus_topics (course_template_id, name, ordinal)
select id, 'Guard fixture', 0 from public.course_templates where code = 'ALBUS_GUARD_PROBE';
"""),
}
for name, (assertion, sql) in fixtures.items():
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory) / 'guard_test.sql'
        path.write_text(TEST.read_text().replace('select plan(3);', sql + '\nselect plan(3);'))
        result = subprocess.run(['supabase', 'test', 'db', str(path), '--local'],
                                cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=60)
        print(f'Expected failure: {name}\n{result.stdout}', flush=True)
        if result.returncode == 0 or not re.search(rf'(?:not ok\s+{assertion}\b|Failed test\s+{assertion}:)', result.stdout):
            raise SystemExit(f'{name}: expected assertion failure was not observed')
subprocess.run(['supabase', 'test', 'db', str(TEST), '--local'], cwd=ROOT, check=True, timeout=60)
print('Both violating transactions rolled back; clean corpus passes.')
