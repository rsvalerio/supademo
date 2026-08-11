#!/usr/bin/env bash
# Regenerates packages/db-types/src/database.types.ts.
#
#   ./scripts/gen-types.sh                       # from the local stack
#   SUPABASE_PROJECT_REF=abc ./scripts/gen-types.sh   # from a hosted project
#
# Run this after every migration and commit the result; CI checks it is current.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/packages/db-types/src/database.types.ts"
SCHEMAS="public,api"

cd "$ROOT"

if [[ -n "${SUPABASE_PROJECT_REF:-}" ]]; then
  echo "Generating types from hosted project $SUPABASE_PROJECT_REF ..."
  npx supabase gen types typescript \
    --project-id "$SUPABASE_PROJECT_REF" \
    --schema "$SCHEMAS" > "$OUT.tmp"
else
  echo "Generating types from the local stack ..."
  if ! npx supabase status >/dev/null 2>&1; then
    echo "The local stack is not running. Start it with: npm run db:start" >&2
    exit 1
  fi
  npx supabase gen types typescript --local --schema "$SCHEMAS" > "$OUT.tmp"
fi

# Only replace the committed file once generation has actually succeeded, so a
# failed run cannot leave an empty types file behind.
if [[ ! -s "$OUT.tmp" ]]; then
  rm -f "$OUT.tmp"
  echo "Type generation produced no output; leaving $OUT untouched." >&2
  exit 1
fi

mv "$OUT.tmp" "$OUT"
echo "Wrote $OUT ($(wc -l < "$OUT") lines)"
