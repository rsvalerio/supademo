#!/usr/bin/env bash
# Deploys every edge function.
#
# `verify_jwt` is NOT taken from config.toml on deploy — it is a per-function
# flag on the platform — so the public endpoints pass --no-verify-jwt here. The
# two lists must agree with supabase/config.toml; they are the same decision
# expressed twice, and a mismatch is either a locked-out webhook or an open one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${SUPABASE_PROJECT_REF:?SUPABASE_PROJECT_REF must be set}"

PUBLIC_FUNCTIONS=(health stripe-webhook auth-email-hook public-demo)
PRIVATE_FUNCTIONS=(billing-portal embed-document queue-worker usage-rollup)

for fn in "${PUBLIC_FUNCTIONS[@]}"; do
  echo "→ $fn (public)"
  npx supabase functions deploy "$fn" --project-ref "$SUPABASE_PROJECT_REF" --no-verify-jwt
done

for fn in "${PRIVATE_FUNCTIONS[@]}"; do
  echo "→ $fn (jwt required)"
  npx supabase functions deploy "$fn" --project-ref "$SUPABASE_PROJECT_REF"
done

echo "Deployed ${#PUBLIC_FUNCTIONS[@]} public and ${#PRIVATE_FUNCTIONS[@]} authenticated functions."
