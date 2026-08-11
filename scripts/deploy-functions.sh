#!/usr/bin/env bash
# Deploys every edge function to the linked project.
#
# `verify_jwt` is a per-function platform flag, not something read from
# config.toml at deploy time, so the public endpoints pass --no-verify-jwt here.
# These two lists must agree with the [functions.*] blocks in config.toml: the
# same decision written twice, and a mismatch is either a locked-out webhook or
# an open endpoint.

source "$(dirname "${BASH_SOURCE[0]}")/_cli.sh"

: "${SUPABASE_PROJECT_REF:?SUPABASE_PROJECT_REF must be set}"

PUBLIC_FUNCTIONS=(health stripe-webhook auth-email-hook public-demo)
PRIVATE_FUNCTIONS=(billing-portal embed-document queue-worker usage-rollup)

# Guard against the lists drifting out of sync with config.toml.
for fn in "${PUBLIC_FUNCTIONS[@]}"; do
  if ! grep -A1 "^\[functions\.$fn\]" supabase/config.toml | grep -q 'verify_jwt = false'; then
    fail "config.toml does not mark [functions.$fn] as verify_jwt = false"
  fi
done

for fn in "${PUBLIC_FUNCTIONS[@]}"; do
  step "$fn (public)"
  supa functions deploy "$fn" --project-ref "$SUPABASE_PROJECT_REF" --no-verify-jwt
done

for fn in "${PRIVATE_FUNCTIONS[@]}"; do
  step "$fn (jwt required)"
  supa functions deploy "$fn" --project-ref "$SUPABASE_PROJECT_REF"
done

echo "Deployed ${#PUBLIC_FUNCTIONS[@]} public and ${#PRIVATE_FUNCTIONS[@]} authenticated functions."
