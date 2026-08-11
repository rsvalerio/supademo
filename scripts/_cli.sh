#!/usr/bin/env bash
# Shared preamble: locates the Supabase CLI and fails helpfully if it is absent.
#
# The CLI is a pinned devDependency rather than a global install, so everyone —
# laptops and CI alike — runs the same version. `npm run <script>` puts
# node_modules/.bin on PATH automatically; running a script directly does not,
# which is what the fallback below is for.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -x "$ROOT/node_modules/.bin/supabase" ]]; then
  SUPABASE="$ROOT/node_modules/.bin/supabase"
elif command -v supabase >/dev/null 2>&1; then
  SUPABASE="$(command -v supabase)"
else
  cat >&2 <<'MSG'
The Supabase CLI was not found.

  npm install        installs the pinned version into node_modules

Everything in this repository goes through the CLI, so this is the only
prerequisite besides Docker.
MSG
  exit 1
fi

supa() { "$SUPABASE" "$@"; }

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn()  { printf '\033[33m%s\033[0m\n' "$*" >&2; }
fail()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# Reads one key out of `supabase status -o json` without needing jq.
status_value() {
  local key="$1"
  supa status -o json 2>/dev/null | node -e '
    let raw = "";
    process.stdin.on("data", (c) => (raw += c));
    process.stdin.on("end", () => {
      try {
        const status = JSON.parse(raw);
        process.stdout.write(String(status[process.argv[1]] ?? ""));
      } catch {
        process.stdout.write("");
      }
    });
  ' "$key"
}

require_stack() {
  if ! supa status >/dev/null 2>&1; then
    fail "The local stack is not running. Start it with: npm start"
  fi
}
