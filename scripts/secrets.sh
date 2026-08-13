#!/usr/bin/env bash
# Seeds the two Vault secrets that database-side scheduled jobs need.
#
# pg_cron cannot call an edge function without a URL and a service key, and
# neither belongs in a migration: they differ per environment and one of them is
# a credential. Values are read from the CLI and written through
# `supabase db query`, so there is no psql dependency and no key on a command
# line where shell history would keep it.
#
#   bash scripts/secrets.sh            # local stack
#   bash scripts/secrets.sh --linked   # the linked project

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"

TARGET="${1:---local}"

resolve_local_credentials() {
  require_stack
  # host.docker.internal, not 127.0.0.1: the caller is Postgres inside a
  # container reaching back out to the edge runtime.
  FUNCTIONS_URL="http://host.docker.internal:54321/functions/v1"
  SERVICE_KEY="$(service_key)"
}

resolve_linked_credentials() {
  : "${SUPABASE_PROJECT_REF:?SUPABASE_PROJECT_REF must be set for --linked}"
  : "${SUPABASE_SERVICE_ROLE_KEY:?SUPABASE_SERVICE_ROLE_KEY must be set for --linked}"
  FUNCTIONS_URL="https://${SUPABASE_PROJECT_REF}.supabase.co/functions/v1"
  SERVICE_KEY="$SUPABASE_SERVICE_ROLE_KEY"
}

# Vault has no upsert, so replace rather than duplicate.
seed_sql() {
  cat <<SQL
do \$\$
begin
  if to_regprocedure('vault.create_secret(text,text,text)') is null then
    raise notice 'supabase_vault is not installed; nothing to seed';
    return;
  end if;

  delete from vault.secrets where name in ('edge_functions_url', 'service_role_key');

  perform vault.create_secret(
    '${FUNCTIONS_URL}', 'edge_functions_url',
    'Base URL used by pg_cron jobs to invoke edge functions');
  perform vault.create_secret(
    '${SERVICE_KEY}', 'service_role_key',
    'Service role key used by scheduled jobs');
end
\$\$;

select name, description from vault.secrets order by name;
SQL
}

main() {
  case "$TARGET" in
    --local)  resolve_local_credentials ;;
    --linked) resolve_linked_credentials ;;
    *) fail "Unknown target: $TARGET (--local|--linked)" ;;
  esac

  if [[ -z "$SERVICE_KEY" ]]; then
    warn "Could not read a service key; leaving Vault untouched."
    warn "Scheduled jobs that call edge functions will log a warning and no-op."
    exit 1
  fi

  supa db query "$TARGET" "$(seed_sql)"
}

main "$@"
