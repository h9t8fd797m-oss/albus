#!/bin/bash
# Apply the generated curriculum seed to the linked Supabase project.
#
# Not a migration: migrations are append-only history, and this file is
# regenerated every time a subject is added. See gen.py for the reasoning.
#
# Idempotent — safe to run repeatedly, and it must be, because that is how the
# corpus grows.
set -euo pipefail
cd "$(dirname "$0")"

python3 gen.py --check
echo

if [ ! -f ../../supabase/.temp/project-ref ]; then
  echo "✗ no linked Supabase project (supabase/.temp/project-ref missing)"
  echo "  run: supabase link --project-ref <ref>"
  exit 1
fi
REF=$(cat ../../supabase/.temp/project-ref)

echo "▸ applying seed.sql to $REF"
if [ -z "${SUPABASE_DB_URL:-}" ]; then
  echo
  echo "  SUPABASE_DB_URL is not set."
  echo "  Either export it, or paste scripts/curriculum/seed.sql into the SQL editor:"
  echo "  https://supabase.com/dashboard/project/$REF/sql/new"
  exit 1
fi

psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f seed.sql
echo "✓ seeded"
