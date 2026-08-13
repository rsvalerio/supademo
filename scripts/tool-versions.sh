#!/usr/bin/env bash
# Generates or checks .tool-versions from scripts/toolchain.lock.
#
#   bash scripts/tool-versions.sh          # write .tool-versions
#   bash scripts/tool-versions.sh --check  # fail if it has drifted
#
# scripts/toolchain.lock is the source of truth, because it carries the
# checksums the no-installer path needs and .tool-versions has nowhere to put
# them. This keeps the two from disagreeing.

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"

TOOL_VERSIONS="$ROOT/.tool-versions"

render() {
  cat <<'HEADER'
# Generated from scripts/toolchain.lock — edit that, then run: make tool-versions
#
# For people who already use mise or asdf. It is a convenience, never a
# requirement: if a tool is absent, or present at the wrong version, the scripts
# fetch the pinned one themselves. Nothing here is load-bearing.
#
#   mise install     resolves all three (supabase comes from its aqua backend)
#   asdf install     has short names for bun and deno; supabase needs a plugin
#                    added by URL first, or just let the scripts vendor it
#
# Docker is deliberately absent: neither tool can install a daemon, and the
# stack's container images are pulled on the first `make setup`.
HEADER
  printf 'supabase %s\n' "$(cli_version)"
  printf 'bun %s\n'      "$(bun_version)"
  printf 'deno %s\n'     "$(deno_version)"
}

if [[ "${1:-}" == "--check" ]]; then
  if ! diff -q <(render) "$TOOL_VERSIONS" >/dev/null 2>&1; then
    diff <(render) "$TOOL_VERSIONS" || true
    fail ".tool-versions has drifted from scripts/toolchain.lock. Run: make tool-versions"
  fi
  pass ".tool-versions" "matches scripts/toolchain.lock"
else
  render > "$TOOL_VERSIONS"
  bold "Wrote .tool-versions"
  dim  "$(grep -v '^#' "$TOOL_VERSIONS" | grep -v '^$' | tr '\n' ' ')"
fi
