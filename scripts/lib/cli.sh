#!/usr/bin/env bash
# The Supabase CLI: pinned, vendored, unmodified.
#
# Why not run it in a container, given Docker is required anyway? Because the
# CLI is the thing that *drives* Docker: it would need the daemon socket
# mounted, the project bind-mounted at its own absolute path (it passes host
# paths to the daemon), and host networking to reach 127.0.0.1:54322 after
# `start`. A pinned binary buys the same reproducibility with none of that.

cli_version()  { lock_value supabase version; }
cli_binary()   { echo "$VENDOR_DIR/supabase/$(cli_version)/supabase"; }
cli_is_cached() { [[ -x "$(cli_binary)" ]]; }

# Maps this machine onto one of the published platform packages.
cli_platform() {
  local os arch
  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    *) fail "Unsupported OS: $(uname -s). On Windows, run this from WSL." ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64)  arch="x64" ;;
    *) fail "Unsupported architecture: $(uname -m)" ;;
  esac
  if [[ "$os" == "linux" ]] && is_musl; then
    echo "${os}-${arch}-musl"
  else
    echo "${os}-${arch}"
  fi
}

cli_download() {
  local platform; platform="$(cli_platform)"
  # `package/bin/supabase` is the CLI. `supabase-go` beside it is the legacy Go
  # binary, which carries only a subset of the commands.
  vendor_fetch supabase "$platform" "@supabase/cli-${platform}" \
    "package/bin/supabase" "$(cli_binary)"
}

# Override > already installed at the pinned version (mise, asdf, Homebrew…) >
# cached > fetch. SUPABASE_CLI_BINARY_OVERRIDE is the same variable the official
# npm wrapper honours.
cli_resolve() {
  local on_path
  if [[ -n "${SUPABASE_CLI_BINARY_OVERRIDE:-}" ]]; then
    echo "$SUPABASE_CLI_BINARY_OVERRIDE"; return
  fi
  if on_path="$(path_tool_matching supabase "$(cli_version)")"; then
    echo "$on_path"; return
  fi
  cli_is_cached || cli_download >&2
  cli_binary
}

SUPABASE="$(cli_resolve)"

# The CLI, for every script that needs it.
supa() { "$SUPABASE" "$@"; }
