#!/usr/bin/env bash
# Everything CI runs, in one command, all of it through the Supabase CLI.
#
#   npm run verify

source "$(dirname "${BASH_SOURCE[0]}")/_cli.sh"

require_stack

step "Replaying every migration against an empty database"
supa db reset

step "Schema lint"
supa db lint --local --level warning --fail-on warning

# The same checks the dashboard's Security and Performance Advisors run:
# tables without RLS, SECURITY DEFINER views, functions with a mutable
# search_path, unindexed foreign keys. Cheaper to hear about here than in a
# review.
step "Security and performance advisors"
supa db advisors --local --type security --level warn --fail-on error
supa db advisors --local --type performance --level warn --fail-on none

step "pgTAP suite"
supa test db --local

# deno_run uses a local deno if there is one and the official image otherwise,
# so this needs no toolchain either.
step "Edge functions"
deno_run fmt --check supabase/functions
deno_run lint supabase/functions
deno_run check supabase/functions/*/index.ts

step "Generated types are current"
bash scripts/gen-types.sh
if ! git diff --quiet -- packages/db-types/src/database.types.ts; then
  fail "packages/db-types is stale. Commit the regenerated file."
fi

printf '\n\033[32mAll checks passed.\033[0m\n'
