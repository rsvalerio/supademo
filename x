#!/usr/bin/env bash
# Task runner. Deliberately not npm: the backend needs no Node toolchain, and
# requiring one to run `db reset` would be a prerequisite in search of a reason.
#
#   ./x setup      first run: start, migrate, seed, generate types
#   ./x verify     everything CI runs
#   ./x            list the tasks
#
# Anything not listed here is just the CLI: ./supa <command>

source "$(dirname "${BASH_SOURCE[0]}")/scripts/_cli.sh"

TASK="${1:-help}"
shift || true

case "$TASK" in
  setup)      exec bash scripts/bootstrap.sh "$@" ;;
  verify)     exec bash scripts/verify.sh "$@" ;;
  types)      exec bash scripts/gen-types.sh "$@" ;;
  serve)      exec bash scripts/serve-functions.sh "$@" ;;
  secrets)    exec bash scripts/bootstrap-secrets.sh "$@" ;;
  deploy)     exec bash scripts/deploy-functions.sh "$@" ;;

  start)      exec "$SUPABASE" start "$@" ;;
  stop)       exec "$SUPABASE" stop "$@" ;;
  status)     exec "$SUPABASE" status "$@" ;;
  reset)      exec "$SUPABASE" db reset "$@" ;;
  test)       require_stack; exec "$SUPABASE" test db --local "$@" ;;
  lint)       require_stack; exec "$SUPABASE" db lint --local --level warning "$@" ;;
  advisors)   require_stack; exec "$SUPABASE" db advisors --local --level warn "$@" ;;
  query)      require_stack; exec "$SUPABASE" db query --local "$@" ;;
  new)        exec "$SUPABASE" migration new "$@" ;;

  # `./x fmt` rewrites, `./x fmt --check` only reports — so the extra args have
  # to reach deno rather than being dropped on the floor.
  fmt)        deno_run fmt "$@" supabase/functions; exit $? ;;
  check)      deno_run lint supabase/functions \
                && deno_run check supabase/functions/*/index.ts; exit $? ;;

  cli)        exec "$SUPABASE" "$@" ;;

  help|--help|-h)
    cat <<'USAGE'
Supademo tasks — Docker is the only prerequisite.

  ./x setup       first run: start the stack, migrate, seed, generate types
  ./x verify      everything CI runs

  ./x start       boot the local Supabase stack
  ./x stop        shut it down
  ./x status      URLs and keys
  ./x reset       replay every migration from empty, then seed
  ./x new <name>  create a migration

  ./x test        pgTAP suite
  ./x lint        schema lint
  ./x advisors    security + performance advisors
  ./x query <sql> run SQL against the local database

  ./x types       regenerate packages/db-types
  ./x serve       serve edge functions
  ./x fmt         format edge functions (--check to verify only)
  ./x check       lint + typecheck edge functions

  ./x deploy      deploy edge functions to the linked project
  ./x secrets     seed Vault secrets for scheduled jobs

Anything else is the CLI itself:  ./supa <command>   (or ./x cli <command>)
USAGE
    ;;
  *)
    warn "Unknown task: $TASK"
    exec "$0" help
    ;;
esac
