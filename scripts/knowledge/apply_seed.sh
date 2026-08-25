#!/bin/bash
# Load the generated knowledge corpus into the linked Supabase project.
#
# Not a migration: migrations are append-only history, and this file is
# regenerated every time the source document is revised. Replacing the corpus
# wholesale is the point — a section deleted upstream must not survive here
# still answering questions.
#
# Goes through `supabase db query --linked`, which reaches the database over the
# Management API using the CLI's own login. That matters: the project's database
# password is not part of the repo, and `.env`'s SUPABASE_SECRET_KEY is a
# placeholder, so neither psql nor PostgREST is available to a fresh checkout.
set -euo pipefail
cd "$(dirname "$0")"

DOC="${1:-$HOME/Desktop/Albus AI/albus_ib_knowledge_base.md}"

if [ ! -f "$DOC" ]; then
  echo "✗ no source document at: $DOC"
  echo "  usage: $0 [path/to/knowledge_base.md]"
  exit 1
fi

python3 ingest.py "$DOC"
echo
echo "▸ loading seed.sql"
(cd ../.. && supabase db query --linked -f scripts/knowledge/seed.sql >/dev/null)

(cd ../.. && supabase db query --linked \
  "select corpus, count(*) as sections, sum(length(body)) as chars,
          count(*) filter (where always_include) as always
     from public.knowledge_sections group by corpus order by corpus;")
echo "✓ loaded"
