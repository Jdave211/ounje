#!/usr/bin/env bash
# Apply pending migrations to the linked Supabase project (or explicit --db-url).
# Do not commit secrets. From repo root:
#
#   export SUPABASE_DB_PASSWORD='...'
#   ./scripts/push-supabase-migrations.sh
#
# Or use a full URL (e.g. dedicated pooler from the dashboard):
#
#   export DATABASE_URL='postgresql://postgres:PASSWORD@db.PROJECT.supabase.co:6543/postgres'
#   ./scripts/push-supabase-migrations.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "${DATABASE_URL:-}" ]]; then
  exec npx supabase@latest db push --yes --db-url "$DATABASE_URL"
fi
exec npx supabase@latest db push --yes
