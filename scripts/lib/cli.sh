#!/usr/bin/env bash
# Resolving the Supabase CLI without installing anything.
#
# The CLI is a self-contained binary published per platform on the npm registry.
# We fetch the pinned one over plain HTTPS, verify its SHA-512 against
# scripts/cli.lock, and cache it in the repo. curl, tar and a shell are the
# whole toolchain — no Node, no npm, no global install.
#
# Why not run the CLI in a container, given Docker is required anyway? Because
# the CLI is the thing that *drives* Docker: it would need the daemon socket
# mounted, the project bind-mounted at its own absolute path (it passes host
# paths to the daemon), and host networking to reach 127.0.0.1:54322 after
# `start`. A pinned binary buys the same reproducibility with none of that.

CLI_LOCK="$ROOT/scripts/cli.lock"

# The lock file is data: `key=value`, one per line. Reading it with sed avoids
# associative arrays, which macOS's bash 3.2 does not have.
cli_lock() { sed -n "s/^$1=//p" "$CLI_LOCK" | head -1; }

cli_version()  { cli_lock version; }
cli_checksum() { cli_lock "$1"; }
cli_cache_dir() { echo "$ROOT/.supabase-cli/$(cli_version)"; }
cli_binary()    { echo "$(cli_cache_dir)/supabase"; }

# Maps this machine onto one of the published platform packages.
cli_platform() {
  local os arch libc=""
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
  # Alpine and friends need the musl build; glibc systems must not use it.
  if [[ "$os" == "linux" ]] && ls /lib/ld-musl-* >/dev/null 2>&1; then
    libc="-musl"
  fi
  echo "${os}-${arch}${libc}"
}

sha512_of() {
  if command -v sha512sum >/dev/null 2>&1; then
    sha512sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 512 "$1" | cut -d' ' -f1
  else
    fail "Neither sha512sum nor shasum is available; cannot verify the download."
  fi
}

_cli_download_tmp=""
_cli_cleanup() { [[ -n "$_cli_download_tmp" ]] && rm -rf "$_cli_download_tmp"; }

cli_download() {
  local platform version url expected actual
  platform="$(cli_platform)"
  version="$(cli_version)"
  expected="$(cli_checksum "$platform")"
  [[ -n "$expected" ]] || fail "scripts/cli.lock has no checksum for platform '$platform'."

  require_cmd curl "to fetch the Supabase CLI"
  require_cmd tar  "to unpack the Supabase CLI"

  url="https://registry.npmjs.org/@supabase/cli-${platform}/-/cli-${platform}-${version}.tgz"
  bold "Fetching Supabase CLI ${version} (${platform}) — one time, into .supabase-cli/"

  # An EXIT trap, not RETURN: a RETURN trap would fire after the local it needs
  # has already gone out of scope.
  _cli_download_tmp="$(mktemp -d)"
  trap _cli_cleanup EXIT

  curl -fsSL "$url" -o "$_cli_download_tmp/cli.tgz" \
    || fail "Could not download the CLI from the npm registry. Are you online?"

  actual="$(sha512_of "$_cli_download_tmp/cli.tgz")"
  [[ "$actual" == "$expected" ]] || fail "Checksum mismatch for $platform.
  expected $expected
  actual   $actual
Refusing to run an unverified binary."

  tar -xzf "$_cli_download_tmp/cli.tgz" -C "$_cli_download_tmp"
  # `package/bin/supabase` is the CLI. `supabase-go` beside it is the legacy Go
  # binary, which carries only a subset of the commands.
  [[ -f "$_cli_download_tmp/package/bin/supabase" ]] \
    || fail "Downloaded archive has no bin/supabase."

  mkdir -p "$(cli_cache_dir)"
  mv "$_cli_download_tmp/package/bin/supabase" "$(cli_binary)"
  chmod +x "$(cli_binary)"

  _cli_cleanup; _cli_download_tmp=""
  trap - EXIT
}

# Override > cached > fetch. SUPABASE_CLI_BINARY_OVERRIDE is the same variable
# the official npm wrapper honours.
cli_resolve() {
  if [[ -n "${SUPABASE_CLI_BINARY_OVERRIDE:-}" ]]; then
    echo "$SUPABASE_CLI_BINARY_OVERRIDE"; return
  fi
  if [[ ! -x "$(cli_binary)" ]]; then
    cli_download >&2
  fi
  cli_binary
}

cli_is_cached() { [[ -x "$(cli_binary)" ]]; }

SUPABASE="$(cli_resolve)"

# The CLI, for every script that needs it.
supa() { "$SUPABASE" "$@"; }
