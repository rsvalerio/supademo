#!/usr/bin/env bash
# Lifecycle of the local Supabase stack.
#
#   bash scripts/stack.sh start|stop|restart|status|clean

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"

start_stack() {
  require_docker
  supa start "$@"
}

stop_stack() {
  require_docker
  supa stop "$@"
}

# Drops the data volume as well. Cheap by design: migrations and seeds rebuild
# everything that matters.
clean_stack() {
  require_docker
  supa stop --no-backup
  bold "Data volume removed. Run 'make setup' to rebuild from migrations + seed."
}

show_status() {
  require_docker
  supa status "$@"
}

case "${1:-status}" in
  start)   shift; start_stack "$@" ;;
  stop)    shift; stop_stack "$@" ;;
  restart) shift; stop_stack; start_stack "$@" ;;
  status)  shift; show_status "$@" ;;
  clean)   clean_stack ;;
  *) fail "Unknown stack command: $1 (start|stop|restart|status|clean)" ;;
esac
