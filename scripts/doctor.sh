#!/usr/bin/env bash
# Reports what this machine has, what the project needs, and what is running.
#
#   ./x doctor
#
# Exits non-zero if a hard requirement is missing, so it doubles as a
# preflight check in a script or a CI step.

source "$(dirname "${BASH_SOURCE[0]}")/_cli.sh"

PROBLEMS=0

ok()      { printf '  \033[32m✓\033[0m %-22s %s\n' "$1" "${2:-}"; }
missing() { printf '  \033[31m✗\033[0m %-22s %s\n' "$1" "${2:-}"; PROBLEMS=$((PROBLEMS + 1)); }
note()    { printf '  \033[33m•\033[0m %-22s %s\n' "$1" "${2:-}"; }

step "Required"

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ok "docker" "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo running)"
  else
    missing "docker" "installed but the daemon is not running"
  fi
else
  missing "docker" "not installed — this is the one hard prerequisite"
fi

for tool in curl tar; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool"; else missing "$tool" "needed to fetch the pinned CLI"; fi
done

if command -v sha512sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
  ok "sha512" "$(command -v sha512sum || command -v shasum)"
else
  missing "sha512" "no sha512sum or shasum; the CLI download cannot be verified"
fi

ok "bash" "${BASH_VERSION%%(*}"
ok "platform" "$(cli_platform)"

step "Toolchain"

if [[ -x "$CLI_CACHE/supabase" ]]; then
  ok "supabase cli" "$SUPABASE_CLI_VERSION (vendored)"
else
  note "supabase cli" "$SUPABASE_CLI_VERSION — will be fetched on first use"
fi

# Optional: nothing breaks without these, they just change which code path runs.
if command -v deno >/dev/null 2>&1; then
  note "deno" "$(deno --version 2>/dev/null | head -1) (local)"
else
  note "deno" "absent — ./x fmt and ./x check will use the Docker image"
fi
if command -v node >/dev/null 2>&1; then
  note "node" "$(node --version) — only needed for future apps/ frontends"
else
  note "node" "absent — not needed for backend work"
fi

step "Project"

[[ -f .env ]] && ok ".env" || note ".env" "missing — ./x setup creates it from .env.example"
[[ -f supabase/functions/.env.local ]] \
  && ok "functions/.env.local" \
  || note "functions/.env.local" "missing — ./x serve creates it"

migrations=$(find supabase/migrations -name '*.sql' 2>/dev/null | wc -l | tr -d ' ')
seeds=$(find supabase/seeds -name '*.sql' 2>/dev/null | wc -l | tr -d ' ')
tests=$(find supabase/tests -name '*.sql' 2>/dev/null | wc -l | tr -d ' ')
ok "migrations" "$migrations"
ok "seed files" "$seeds"
ok "test files" "$tests"

step "Ports"

# bash's /dev/tcp needs no netstat, lsof or nc.
port_busy() { (echo >"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }
for entry in "54321:API" "54322:Postgres" "54323:Studio" "54324:Inbucket" "54329:Pooler"; do
  port="${entry%%:*}"; label="${entry##*:}"
  if port_busy "$port"; then
    note "$port ($label)" "in use — by this stack if it is running, otherwise a conflict"
  else
    ok "$port ($label)" "free"
  fi
done

step "Stack"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if supa status >/dev/null 2>&1; then
    ok "status" "running"
    api="$(status_value API_URL)"
    [[ -n "$api" ]] && note "api" "$api"
    note "studio" "http://127.0.0.1:54323"
  else
    note "status" "not running — start it with ./x start (or ./x setup for a first run)"
  fi
else
  note "status" "skipped; Docker is unavailable"
fi

echo
if [[ "$PROBLEMS" -gt 0 ]]; then
  fail "$PROBLEMS requirement(s) missing. See docs/local-development.md."
fi
bold "Everything required is present."
