#!/usr/bin/env bash
# Edge function tasks.
#
#   bash scripts/functions.sh serve|fmt|check|new|list|deploy

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"

# `verify_jwt` is a per-function platform flag, not something read from
# config.toml at deploy time, so the public endpoints need --no-verify-jwt.
# These lists are the same decision as the [functions.*] blocks in config.toml,
# written twice — so they are checked against each other before anything ships.
PUBLIC_FUNCTIONS=(health stripe-webhook auth-email-hook public-demo api-v1)
PRIVATE_FUNCTIONS=(billing-portal embed-document queue-worker usage-rollup)

serve_functions() {
  # The CLI refuses to start when --env-file points at a missing file, and that
  # file is gitignored because it holds credentials.
  if ensure_env_file "$FUNCTIONS_ENV_FILE"; then
    warn "Created supabase/functions/.env.local from .env.example."
    warn "Provider keys are blank; email and billing paths will log instead of sending."
  fi
  require_stack
  supa functions serve --env-file "$FUNCTIONS_ENV_FILE" "$@"
}

format_functions() { deno_run fmt "$@" supabase/functions; }

check_functions() {
  deno_run lint supabase/functions

  # --config is required because deno discovers a config file from the working
  # directory, which is the repo root, while the import map lives in
  # supabase/functions/deno.json. Without it the bare specifiers
  # ("@supabase/supabase-js", "stripe") do not resolve and check fails before
  # type-checking anything.
  #
  # Deliberately not passed to fmt or lint above: they need no import map, and
  # the config also sets lineWidth 100 against deno's default 80, so applying it
  # there would reformat every function file as a side effect of a typecheck fix.
  deno_run check --config supabase/functions/deno.json supabase/functions/*/index.ts
}

assert_visibility_matches_config() {
  local fn
  for fn in "${PUBLIC_FUNCTIONS[@]}"; do
    grep -A1 "^\[functions\.$fn\]" supabase/config.toml | grep -q 'verify_jwt = false' \
      || fail "config.toml does not mark [functions.$fn] as verify_jwt = false"
  done
}

deploy_functions() {
  : "${SUPABASE_PROJECT_REF:?SUPABASE_PROJECT_REF must be set}"
  assert_visibility_matches_config

  local fn
  for fn in "${PUBLIC_FUNCTIONS[@]}"; do
    step "$fn (public)"
    supa functions deploy "$fn" --project-ref "$SUPABASE_PROJECT_REF" --no-verify-jwt
  done
  for fn in "${PRIVATE_FUNCTIONS[@]}"; do
    step "$fn (jwt required)"
    supa functions deploy "$fn" --project-ref "$SUPABASE_PROJECT_REF"
  done

  bold "Deployed ${#PUBLIC_FUNCTIONS[@]} public and ${#PRIVATE_FUNCTIONS[@]} authenticated functions."
}

case "${1:-}" in
  serve)  shift; serve_functions "$@" ;;
  fmt)    shift; format_functions "$@" ;;
  check)  shift; check_functions "$@" ;;
  new)    shift; supa functions new "$@" ;;
  list)   shift; supa functions list "$@" ;;
  deploy) shift; deploy_functions "$@" ;;
  *) fail "Unknown functions command: ${1:-} (serve|fmt|check|new|list|deploy)" ;;
esac
