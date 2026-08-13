#!/usr/bin/env bash
# Project paths and the .env files the CLI expects to find.

# Resolved once, from this file's own location, so scripts work from any cwd.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

ENV_FILE="$ROOT/.env"
ENV_EXAMPLE="$ROOT/.env.example"
FUNCTIONS_ENV_FILE="$ROOT/supabase/functions/.env.local"

# The CLI resolves env() references in config.toml from the process
# environment, so .env has to be loaded before any command that reads config.
load_dotenv() {
  [[ -f "$ENV_FILE" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

# Creates a missing env file from the example. Returns 0 if it created one, so
# callers can report it, and 1 if the file was already there.
ensure_env_file() {
  local target="$1"
  [[ -f "$target" ]] && return 1
  mkdir -p "$(dirname "$target")"
  cp "$ENV_EXAMPLE" "$target"
  return 0
}
