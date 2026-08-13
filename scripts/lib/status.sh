#!/usr/bin/env bash
# Reading state out of the running local stack.

stack_running() { supa status >/dev/null 2>&1; }

# One value out of `supabase status -o env`, which is already shell-shaped —
# so no JSON parser, and therefore no Node, is needed.
status_value() {
  supa status -o env 2>/dev/null \
    | sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" \
    | head -1
}

api_url()     { local v; v="$(status_value API_URL)"; echo "${v:-http://127.0.0.1:54321}"; }
anon_key()    { local v; v="$(status_value ANON_KEY)"; [[ -z "$v" ]] && v="$(status_value PUBLISHABLE_KEY)"; echo "$v"; }
service_key() { local v; v="$(status_value SERVICE_ROLE_KEY)"; [[ -z "$v" ]] && v="$(status_value SECRET_KEY)"; echo "$v"; }

STUDIO_URL="http://127.0.0.1:54323"
INBUCKET_URL="http://127.0.0.1:54324"
DB_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres"

# The ports the stack claims, as "port:label" pairs, for doctor and for
# conflict messages.
stack_ports() { echo "54321:API 54322:Postgres 54323:Studio 54324:Inbucket 54329:Pooler"; }
