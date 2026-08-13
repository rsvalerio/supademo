#!/usr/bin/env bash
# Database tasks. Every one of them is a Supabase CLI call with a guard in
# front, so failures read as "the stack is not running" rather than a socket
# error from somewhere deep in the CLI.
#
#   bash scripts/db.sh reset|new|test|lint|advisors|query|list|dump

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"

# Replays every migration from empty, then the seed files. Always from empty:
# that is the only thing that catches a migration which works against your
# database but not a fresh one.
db_reset() { require_stack; supa db reset "$@"; }

db_new() {
  [[ $# -gt 0 ]] || fail "Usage: make new name=add_widget_table"
  supa migration new "$@"
}

db_test()     { require_stack; supa test db --local "$@"; }
db_lint()     { require_stack; supa db lint --local --level warning "$@"; }
db_list()     { require_docker; supa migration list "$@"; }
db_dump()     { require_stack; supa db dump --local -f supabase/schema.sql "$@"; }

# The same checks as the dashboard's Security and Performance advisors.
db_advisors() {
  require_stack
  supa db advisors --local --type security --level warn "$@"
  supa db advisors --local --type performance --level warn "$@"
}

db_query() {
  [[ $# -gt 0 ]] || fail 'Usage: make query sql="select 1"'
  require_stack
  supa db query --local "$@"
}

case "${1:-}" in
  reset)    shift; db_reset "$@" ;;
  new)      shift; db_new "$@" ;;
  test)     shift; db_test "$@" ;;
  lint)     shift; db_lint "$@" ;;
  advisors) shift; db_advisors "$@" ;;
  query)    shift; db_query "$@" ;;
  list)     shift; db_list "$@" ;;
  dump)     shift; db_dump "$@" ;;
  *) fail "Unknown db command: ${1:-} (reset|new|test|lint|advisors|query|list|dump)" ;;
esac
