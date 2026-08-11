#!/usr/bin/env bash
# Everything CI runs, runnable locally in one command.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

step "Applying migrations to a clean database"
npx supabase db reset

step "Linting the schema"
npx supabase db lint --level warning

step "Running pgTAP tests"
npx supabase test db

step "Checking edge functions"
if command -v deno >/dev/null 2>&1; then
  deno fmt --check supabase/functions
  deno lint supabase/functions
  deno check supabase/functions/*/index.ts
else
  echo "deno not installed; skipping function checks"
fi

step "Checking generated types are current"
./scripts/gen-types.sh
if ! git diff --quiet -- packages/db-types/src/database.types.ts; then
  echo "packages/db-types is stale. Commit the regenerated file." >&2
  exit 1
fi

printf '\n\033[32mAll checks passed.\033[0m\n'
