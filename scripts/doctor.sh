#!/usr/bin/env bash
# Reports what this machine has, what the project needs, and what is running.
#
#   make doctor
#
# Exits non-zero when a hard requirement is missing, so it doubles as a
# preflight check inside another script or a CI step.

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"

PROBLEMS=0
require() { miss "$1" "${2:-}"; PROBLEMS=$((PROBLEMS + 1)); }

check_required_tools() {
  step "Required"

  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      pass "docker" "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo running)"
    else
      require "docker" "installed but the daemon is not running"
    fi
  else
    require "docker" "not installed — this is the one hard prerequisite"
  fi

  local tool
  for tool in curl tar; do
    command -v "$tool" >/dev/null 2>&1 \
      && pass "$tool" \
      || require "$tool" "needed to fetch the pinned CLI"
  done

  if command -v sha512sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
    pass "sha512" "$(command -v sha512sum || command -v shasum)"
  else
    require "sha512" "no sha512sum or shasum; the CLI download cannot be verified"
  fi

  pass "bash" "${BASH_VERSION%%(*}"
  pass "platform" "$(cli_platform)"
}

check_toolchain() {
  step "Toolchain"

  cli_is_cached \
    && pass "supabase cli" "$(cli_version) (vendored)" \
    || info "supabase cli" "$(cli_version) — will be fetched on first use"

  bun_is_cached \
    && pass "bun" "$(bun_version) (vendored) — packages/ and apps/" \
    || info "bun" "$(bun_version) — will be fetched when JavaScript is touched"

  # Optional: their absence only changes which code path runs.
  command -v deno >/dev/null 2>&1 \
    && info "deno" "$(deno --version 2>/dev/null | head -1) (local)" \
    || info "deno" "absent — edge function fmt/check will use $(deno_image)"

  command -v node >/dev/null 2>&1 \
    && info "node" "$(node --version) — not used; Bun is the JS toolchain" \
    || info "node" "absent — not needed"

  command -v make >/dev/null 2>&1 \
    && pass "make" "$(make --version 2>/dev/null | head -1 | cut -d' ' -f1-3)" \
    || info "make" "absent — call the scripts directly: bash scripts/<name>.sh"
}

# .tool-versions is optional. This reports whether a version manager is
# satisfying the pins, purely so the "why did it download again?" question
# answers itself.
check_version_manager() {
  step "Version manager (optional)"

  local manager=""
  command -v mise >/dev/null 2>&1 && manager="mise $(mise --version 2>/dev/null | head -1)"
  [[ -z "$manager" ]] && command -v asdf >/dev/null 2>&1 && manager="asdf $(asdf --version 2>/dev/null | head -1)"

  if [[ -n "$manager" ]]; then
    pass "detected" "$manager"
  else
    info "detected" "none — the scripts vendor the pinned tools themselves"
  fi

  local entry name want
  for entry in "supabase:$(cli_version)" "bun:$(bun_version)" "deno:$(deno_version)"; do
    name="${entry%%:*}"; want="${entry##*:}"
    if path_tool_matching "$name" "$want" >/dev/null; then
      pass "$name on PATH" "$want — used directly, nothing to download"
    elif command -v "$name" >/dev/null 2>&1; then
      info "$name on PATH" "wrong version; the pinned $want is used instead"
    else
      info "$name on PATH" "absent; the pinned $want is used"
    fi
  done
}

check_project() {
  step "Project"

  [[ -f "$ENV_FILE" ]] && pass ".env" || info ".env" "missing — make setup creates it"
  [[ -f "$FUNCTIONS_ENV_FILE" ]] \
    && pass "functions/.env.local" \
    || info "functions/.env.local" "missing — make serve creates it"

  pass "migrations" "$(count_sql supabase/migrations)"
  pass "seed files" "$(count_sql supabase/seeds)"
  pass "test files" "$(count_sql supabase/tests)"
}

count_sql() { find "$1" -name '*.sql' 2>/dev/null | wc -l | tr -d ' '; }

check_ports() {
  step "Ports"
  local entry port label
  for entry in $(stack_ports); do
    port="${entry%%:*}"; label="${entry##*:}"
    if port_in_use "$port"; then
      info "$port ($label)" "in use — by this stack if it is running, else a conflict"
    else
      pass "$port ($label)" "free"
    fi
  done
}

check_stack() {
  step "Stack"
  if ! docker_available; then
    info "status" "skipped; Docker is unavailable"
    return
  fi
  if stack_running; then
    pass "status" "running"
    info "api" "$(api_url)"
    info "studio" "$STUDIO_URL"
  else
    info "status" "not running — make start (or make setup for a first run)"
  fi
}

main() {
  check_required_tools
  check_toolchain
  check_version_manager
  check_project
  check_ports
  check_stack

  echo
  [[ "$PROBLEMS" -eq 0 ]] || fail "$PROBLEMS requirement(s) missing. See docs/local-development.md."
  bold "Everything required is present."
}

main "$@"
