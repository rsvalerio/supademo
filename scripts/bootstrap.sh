#!/usr/bin/env bash
# One command from a fresh clone to a running, seeded, typed local project.
#
#   npm run setup
#
# Every step is a Supabase CLI call. Nothing here talks to Postgres directly,
# installs a database, or manages a container by hand — that is all the CLI's
# job, and watching it happen is rather the point.

source "$(dirname "${BASH_SOURCE[0]}")/_cli.sh"

step "Checking prerequisites"
if ! docker info >/dev/null 2>&1; then
  fail "Docker is not running. The CLI needs it to boot the local stack."
fi
echo "Docker           ok"
echo "Supabase CLI     $(supa --version 2>/dev/null || echo unknown)  ($SUPABASE)"

# The CLI reads env() references in config.toml from the process environment,
# so .env has to exist before `supabase start`.
if [[ ! -f .env ]]; then
  cp .env.example .env
  echo ".env             created from .env.example"
else
  echo ".env             already present"
fi
set -a; source .env; set +a

if [[ ! -f supabase/functions/.env.local ]]; then
  cp .env.example supabase/functions/.env.local
  echo "functions/.env   created from .env.example"
fi

step "Starting the local stack"
# Idempotent: if it is already up, `start` prints the status and exits 0.
supa start

step "Applying migrations and seed data"
# `db reset` drops the database and replays every migration from empty, then
# runs seed.sql. Always from empty — that is what catches a migration which
# only works against a database that has already seen its predecessors.
supa db reset

step "Seeding Vault secrets for scheduled jobs"
bash scripts/bootstrap-secrets.sh || warn "Vault seeding skipped (see message above)"

step "Generating database types"
bash scripts/gen-types.sh

step "Ready"
API_URL="$(status_value API_URL)"
ANON_KEY="$(status_value ANON_KEY)"
[[ -z "$ANON_KEY" ]] && ANON_KEY="$(status_value PUBLISHABLE_KEY)"

cat <<EOF

  Studio         http://127.0.0.1:54323
  API            ${API_URL:-http://127.0.0.1:54321}
  Postgres       postgresql://postgres:postgres@127.0.0.1:54322/postgres
  Inbucket       http://127.0.0.1:54324   (every auth email lands here)

  Seeded logins  ada@supademo.test      owner of Acme Inc (Pro)
                 grace@supademo.test    member of Acme Inc
                 alan@supademo.test     owner of Globex Corp
                 outsider@supademo.test belongs to nothing, on purpose
                 password: supademo123!

  Try it:
    npm run test:db                     pgTAP suite
    npm run db:advisors                 security + performance lints
    npm run db:query "select * from api.plans"
    curl "${API_URL:-http://127.0.0.1:54321}/rest/v1/plans?select=id,name,price_cents" \\
      -H "apikey: \$ANON_KEY"

  Full command tour: docs/supabase-cli.md
EOF
