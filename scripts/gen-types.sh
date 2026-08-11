#!/usr/bin/env bash
# Regenerates packages/db-types/src/database.types.ts.
#
#   npm run gen:types                                  # from the local stack
#   SUPABASE_PROJECT_REF=abc npm run gen:types         # from a hosted project
#
# Run after every migration and commit the result; CI fails on a stale file.

source "$(dirname "${BASH_SOURCE[0]}")/_cli.sh"

OUT="packages/db-types/src/database.types.ts"
SCHEMAS="public,api"

if [[ -n "${SUPABASE_PROJECT_REF:-}" ]]; then
  echo "Generating from hosted project $SUPABASE_PROJECT_REF ..."
  supa gen types --project-id "$SUPABASE_PROJECT_REF" --schema "$SCHEMAS" > "$OUT.tmp"
else
  require_stack
  echo "Generating from the local stack ..."
  supa gen types --local --schema "$SCHEMAS" > "$OUT.tmp"
fi

# Swap in the new file only once generation has actually produced something, so
# a failed run cannot leave an empty types file behind.
if [[ ! -s "$OUT.tmp" ]]; then
  rm -f "$OUT.tmp"
  fail "Type generation produced no output; $OUT left untouched."
fi

mv "$OUT.tmp" "$OUT"
echo "Wrote $OUT ($(wc -l < "$OUT") lines)"
