#!/usr/bin/env bash
# Regenerates packages/db-types/src/database.types.ts.
#
#   bash scripts/types.sh                              # from the local stack
#   SUPABASE_PROJECT_REF=abc bash scripts/types.sh     # from a hosted project
#
# Run after every migration and commit the result; CI fails on a stale file.

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"

TYPES_FILE="packages/db-types/src/database.types.ts"
TYPES_SCHEMAS="public,api"

generate_types() {
  if [[ -n "${SUPABASE_PROJECT_REF:-}" ]]; then
    dim "Generating from hosted project $SUPABASE_PROJECT_REF ..."
    supa gen types --project-id "$SUPABASE_PROJECT_REF" --schema "$TYPES_SCHEMAS"
  else
    require_stack
    dim "Generating from the local stack ..."
    supa gen types --local --schema "$TYPES_SCHEMAS"
  fi
}

# Write to a temp file first: a failed run must not leave an empty types file
# behind, which would type-check against a schema that does not exist.
main() {
  local tmp="$TYPES_FILE.tmp"
  generate_types > "$tmp"

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    fail "Type generation produced no output; $TYPES_FILE left untouched."
  fi

  mv "$tmp" "$TYPES_FILE"
  bold "Wrote $TYPES_FILE ($(wc -l < "$TYPES_FILE" | tr -d ' ') lines)"
}

main "$@"
