#!/usr/bin/env python3
"""Prove deploy refusal and rollback in an already-restored disposable local DB."""

import hashlib
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = "supabase_db_ssvehwhblgqtvqkfbkbj"
DATABASE = "albus_deploy_rehearsal"
SCRIPT = (ROOT / "scripts/deploy-2026-09-05.sql").read_text()


def sql(query, expected=None):
    result = subprocess.run(
        ["docker", "exec", "-i", CONTAINER, "psql", "-X", "-U", "postgres",
         "-d", DATABASE, "-v", "ON_ERROR_STOP=1", "-Atq"],
        input=query, text=True, capture_output=True,
    )
    if expected:
        assert result.returncode != 0 and expected in result.stderr, result.stderr
        print(next(line for line in result.stderr.splitlines() if "ERROR:" in line))
    else:
        assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def fingerprint():
    dump = subprocess.run(
        ["docker", "exec", CONTAINER, "pg_dump", "-U", "postgres", "-d", DATABASE,
         "--no-owner", "--no-privileges", "-n", "public", "-n", "private",
         "-n", "auth", "-n", "supabase_migrations"],
        text=True, capture_output=True, check=True,
    ).stdout
    # pg_dump randomises its psql restriction token on each invocation.
    stable = "\n".join(line for line in dump.splitlines()
                       if not line.startswith(("\\restrict ", "\\unrestrict ")))
    return hashlib.sha256(stable.encode()).hexdigest()


def refuses(label, setup, restore, message, script=SCRIPT):
    sql(setup)
    before = fingerprint()
    try:
        sql(script, message)
        assert fingerprint() == before, f"{label}: failed transaction changed database"
        print(f"PASS {label}: full application/history dump unchanged after refusal")
    finally:
        sql(restore)


# Reconstruct the documented pending schema and wrongly stamped history without
# touching the working local stack. The disposable DB contains no student data.
repairs = re.findall(r"set version = '([^']+)' where version = '([^']+)' and name = '([^']+)'", SCRIPT)
assert len(repairs) == 11
sql("drop table if exists supabase_migrations.schema_migrations_backup_20260905")
for correct, wrong, name in repairs:
    sql(f"update supabase_migrations.schema_migrations set version='{wrong}' where version='{correct}' and name='{name}'")
sql("""
delete from supabase_migrations.schema_migrations where version in
 ('20260901200000','20260903204500','20260903223000','20260907120000');
alter table public.ai_usage drop column cache_read_tokens, drop column cache_write_tokens;
alter table public.ai_usage drop constraint ai_usage_user_id_fkey;
alter table public.ai_usage add constraint ai_usage_user_id_fkey
 foreign key(user_id) references auth.users(id) on delete cascade;
alter table public.ai_usage alter column user_id set not null;
alter table public.assignments drop constraint assignments_task_type_check;
alter table public.assignments add constraint assignments_task_type_check
 check(task_type in ('essay','problem_set','lab_report','reading','revision','project','presentation','other'));
""")
sql(SCRIPT)
assert sql("select count(*) from supabase_migrations.schema_migrations_backup_20260905 where version='20260901192220'") == "1"
print("PASS pending-schema rehearsal: history repaired, all three changes applied, backup retained original stamp")
before = fingerprint()
sql(SCRIPT)
assert fingerprint() == before, "rerun changed logical schema or data"
print("PASS second run: logical schema/data dump identical (DDL is re-executed)")

definition = sql("select pg_get_functiondef('public.set_ib_context(text,smallint,boolean,boolean)'::regprocedure)")
refuses("missing student-context RPC",
        "drop function public.set_ib_context(text,smallint,boolean,boolean)",
        definition, "ib_student_context schema is incomplete")
refuses("wrong migration name",
        "update supabase_migrations.schema_migrations set name='wrong_fixture' where version='0030'",
        "update supabase_migrations.schema_migrations set name='grading_free_quota' where version='0030'",
        "history missing expected version/name pairs")
refuses("surviving wrong stamp",
        "insert into supabase_migrations.schema_migrations(version,name) values('20260826172040','wrong_fixture')",
        "delete from supabase_migrations.schema_migrations where version='20260826172040'",
        "a wrongly-stamped version survived")
for column in ("cache_read_tokens", "cache_write_tokens"):
    refuses(f"{column} wrong type",
            f"alter table public.ai_usage alter column {column} type bigint",
            f"alter table public.ai_usage alter column {column} type integer",
            "cache token columns must both exist as integer")

# A pre-existing bad CHECK is repaired by the deploy. Mutate only this temporary
# script copy to prove verification also catches a future incomplete embedded DDL.
broken = SCRIPT.replace("'mock_exam', 'final_exam'", "'mock_exam'", 1)
assert broken != SCRIPT
refuses("missing final_exam", "select 1", "select 1",
        "does not include the IB types", broken)
print("PASS all violating fixtures removed; production was never addressed")
