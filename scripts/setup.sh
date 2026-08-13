#!/usr/bin/env bash
# One command from a fresh clone to a running, seeded, typed local project.
#
#   make setup
#
# Every step is a Supabase CLI call. Nothing here talks to Postgres directly,
# installs a database, or manages a container by hand — that is all the CLI's
# job, and watching it happen is rather the point. Re-running is safe.

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"

check_prerequisites() {
  step "Checking prerequisites"
  # Docker is the only thing that must exist beforehand, and it is
  # unavoidable: the local stack IS containers, and something has to run them.
  require_docker
  pass "docker" "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo running)"
  pass "supabase cli" "$(cli_version) (pinned, vendored)"
}

prepare_env_files() {
  # The CLI resolves env() references in config.toml from the process
  # environment, so .env must exist before `supabase start`.
  if ensure_env_file "$ENV_FILE"; then
    pass ".env" "created from .env.example"
    load_dotenv
  else
    pass ".env" "already present"
  fi
  ensure_env_file "$FUNCTIONS_ENV_FILE" \
    && pass "functions/.env.local" "created from .env.example" \
    || pass "functions/.env.local" "already present"
}

print_summary() {
  step "Ready"
  cat <<SUMMARY

  Studio         $STUDIO_URL
  API            $(api_url)
  Postgres       $DB_URL
  Inbucket       $INBUCKET_URL   (every auth email lands here)

  Seeded logins  ada@supademo.test      owner of Acme Inc (Pro)
                 grace@supademo.test    member of Acme Inc
                 alan@supademo.test     owner of Globex Corp
                 outsider@supademo.test belongs to nothing, on purpose
                 password: supademo123!

  Try it:
    make test                      pgTAP suite
    make advisors                  security + performance lints
    make query sql="select * from api.plans"

  All tasks: make help     ·     Raw CLI: ./supa <command>
  Command tour: docs/supabase-cli.md
SUMMARY
}

main() {
  check_prerequisites
  prepare_env_files

  step "Starting the local stack"
  # Idempotent: if it is already up, `start` prints the status and exits 0.
  supa start

  step "Applying migrations and seed data"
  supa db reset

  step "Seeding Vault secrets for scheduled jobs"
  bash scripts/secrets.sh --local || warn "Vault seeding skipped (see message above)"

  step "Generating database types"
  bash scripts/types.sh

  print_summary
}

main "$@"
