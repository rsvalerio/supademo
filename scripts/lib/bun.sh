#!/usr/bin/env bash
# Bun: the JavaScript toolchain for packages/ and apps/.
#
# NOT for supabase/functions. Those run on the Supabase Edge Runtime, which is a
# Deno fork, and they use Deno.serve, EdgeRuntime.waitUntil and Supabase.ai —
# none of which exist under Bun. Deno stays the toolchain there (see deno.sh);
# Bun owns everything else JavaScript.
#
# Vendored the same way as the CLI, so `make typecheck` works on a machine with
# no Node, no npm and no Bun installed.

bun_version()   { lock_value bun version; }
bun_binary()    { echo "$VENDOR_DIR/bun/$(bun_version)/bun"; }
bun_is_cached() { [[ -x "$(bun_binary)" ]]; }

# Bun's platform naming differs from the CLI's: aarch64 rather than arm64.
bun_platform() {
  local os arch
  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    *) fail "Unsupported OS for Bun: $(uname -s). On Windows, run this from WSL." ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch="aarch64" ;;
    x86_64|amd64)  arch="x64" ;;
    *) fail "Unsupported architecture for Bun: $(uname -m)" ;;
  esac
  if [[ "$os" == "linux" ]] && is_musl; then
    echo "${os}-${arch}-musl"
  else
    echo "${os}-${arch}"
  fi
}

bun_download() {
  local platform; platform="$(bun_platform)"
  vendor_fetch bun "$platform" "@oven/bun-${platform}" \
    "package/bin/bun" "$(bun_binary)"
}

# The pinned version wins, exactly as it does for the CLI. Preferring whatever
# bun happens to be on PATH would save a download and give up the only thing
# that makes a laptop, an agent and a CI runner agree — which is the whole point
# of vendoring. Set BUN_BINARY_OVERRIDE to use your own on purpose.
bun_resolve() {
  if [[ -n "${BUN_BINARY_OVERRIDE:-}" ]]; then
    echo "$BUN_BINARY_OVERRIDE"; return
  fi
  bun_is_cached || bun_download >&2
  bun_binary
}

# Resolved lazily: most tasks never touch JavaScript, and they should not pay
# for a 90 MB download to run a migration.
bun_run() { "$(bun_resolve)" "$@"; }
