#!/usr/bin/env bash
# Everything CI runs, in one command.
#
#   make verify

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"

verify_migrations() {
  step "Replaying every migration against an empty database"
  supa db reset
}

verify_schema() {
  step "Schema lint"
  supa db lint --local --level warning --fail-on warning

  # Security findings block; performance findings are reported and left to
  # judgement, since the right fix is often "not yet".
  step "Security and performance advisors"
  supa db advisors --local --type security --level warn --fail-on error
  supa db advisors --local --type performance --level warn --fail-on none
}

verify_tests() {
  step "pgTAP suite"
  supa test db --local
}

verify_functions() {
  step "Edge functions"
  bash scripts/functions.sh fmt --check
  bash scripts/functions.sh check
}

verify_types_are_current() {
  step "Generated types are current"
  bash scripts/types.sh
  git diff --quiet -- packages/db-types/src/database.types.ts \
    || fail "packages/db-types is stale. Commit the regenerated file."
}

main() {
  require_stack
  verify_migrations
  verify_schema
  verify_tests
  verify_functions
  verify_types_are_current

  printf '\n%s%s%s\n' "$_C_GREEN" "All checks passed." "$_C_OFF"
}

main "$@"
