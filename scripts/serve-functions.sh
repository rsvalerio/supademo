#!/usr/bin/env bash
# Serves every edge function locally.
#
# `supabase functions serve` fails outright if --env-file points at a file that
# does not exist, and that file is gitignored because it holds credentials — so
# a fresh clone would hit an error that says nothing useful. Create it first.

source "$(dirname "${BASH_SOURCE[0]}")/_cli.sh"

ENV_FILE="supabase/functions/.env.local"

if [[ ! -f "$ENV_FILE" ]]; then
  cp .env.example "$ENV_FILE"
  warn "Created $ENV_FILE from .env.example."
  warn "Provider keys are blank; the email and billing paths will log instead of sending."
fi

require_stack
exec "$SUPABASE" functions serve --env-file "$ENV_FILE" "$@"
