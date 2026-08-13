#!/usr/bin/env bash
# Resolves the Supabase CLI, installing nothing on the machine.
#
# The CLI is a single self-contained binary published per platform on the npm
# registry. This fetches the pinned one over plain HTTPS, verifies its SHA-512
# against the checksums below, and caches it inside the repo. No Node, no npm,
# no global install — curl, tar and a shell are the whole toolchain.
#
# Why not run the CLI in a container, given Docker is already required?
# Because the CLI is the thing that *drives* Docker, and putting it inside a
# container costs three things at once: it needs the daemon socket mounted; it
# passes host paths to that daemon, so the project must be bind-mounted at its
# own absolute path; and after `start` it connects to 127.0.0.1:54322, which
# inside a container is the container's own loopback — so it needs host
# networking, which is reliable on Linux but opt-in on Docker Desktop. A pinned
# 30 MB binary buys the same reproducibility with none of that.
#
# Override with SUPABASE_CLI_BINARY_OVERRIDE (the same variable the official npm
# wrapper honours) to point at a CLI you already have.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn()  { printf '\033[33m%s\033[0m\n' "$*" >&2; }
fail()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# Pinned CLI version. Bumping it is a deliberate commit: change the version and
# the six checksums together (scripts/update-cli.sh regenerates them).
SUPABASE_CLI_VERSION="2.113.0"

cli_checksum() {
  case "$1" in
    darwin-arm64)      echo "438d3495ecd9af361fefe2d22413470947a080ce0d07e24e66bfd1cf21fdf87dd32ab2c233987db96a14ddf904b9571c84102b9986115c15aab02c2adc359dce" ;;
    darwin-x64)        echo "d2fe1dd664556f912de3e42376b651b47a6c3b57d189b1145c08a3d9335c06e327e04dd2ba364131b30ed163e938a244a63eb2b99185fa8e13f31e9db80d71d5" ;;
    linux-arm64)       echo "7323686133e3a8e81bd37be8e7c0f035a0771fd49623779af6b28a738d752fdde802ed96f6d6202cce576f68d25b70d3c7319c6d61d7c0e492671801642ae884" ;;
    linux-arm64-musl)  echo "cd2b1ae1c0105796c067ca5dfa74efaacfad0aeb0991958291403c9eefa4b825a827efb0a9e9e446abbd63d7bd098bbc15739e3c1331a5387173435c17d04c77" ;;
    linux-x64)         echo "706d3877d420480e27d1eb6f3db66600a383764845e34ac166b88b58238458d2f6ac81f54c2a69cf6419d1216b8763a5c068da490ee5605bf96519f0d275d2d4" ;;
    linux-x64-musl)    echo "f5ba3be708e24d59dd981a8deaea3112c9abd408527c72cb5ddd466f3c8a03a2bc37f1fbaf5c00787716070f7918af7caf21a0d20a545e8e2899d45488a96365" ;;
    *) echo "" ;;
  esac
}

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

CLI_CACHE="$ROOT/.supabase-cli/$SUPABASE_CLI_VERSION"
_CLI_TMP=""

download_cli() {
  local platform url expected actual
  platform="$(cli_platform)"
  expected="$(cli_checksum "$platform")"
  [[ -n "$expected" ]] || fail "No pinned checksum for platform '$platform'."

  url="https://registry.npmjs.org/@supabase/cli-${platform}/-/cli-${platform}-${SUPABASE_CLI_VERSION}.tgz"

  command -v curl >/dev/null 2>&1 || fail "curl is required to fetch the Supabase CLI."
  command -v tar  >/dev/null 2>&1 || fail "tar is required to unpack the Supabase CLI."

  bold "Fetching Supabase CLI ${SUPABASE_CLI_VERSION} (${platform}) — one time, into .supabase-cli/"
  # A RETURN trap cannot clean this up: the local would already be out of scope
  # by the time it fired. An EXIT trap on a shell-scoped variable can.
  _CLI_TMP="$(mktemp -d)"
  trap 'rm -rf "${_CLI_TMP:-}"' EXIT

  curl -fsSL "$url" -o "$_CLI_TMP/cli.tgz" \
    || fail "Could not download the CLI from the npm registry. Are you online?"

  actual="$(sha512_of "$_CLI_TMP/cli.tgz")"
  if [[ "$actual" != "$expected" ]]; then
    fail "Checksum mismatch for $platform.
  expected $expected
  actual   $actual
Refusing to run an unverified binary."
  fi

  tar -xzf "$_CLI_TMP/cli.tgz" -C "$_CLI_TMP"
  # `package/bin/supabase` is the CLI. `supabase-go` beside it is the legacy Go
  # binary and carries only a subset of the commands — not what we want.
  [[ -f "$_CLI_TMP/package/bin/supabase" ]] || fail "Downloaded archive has no bin/supabase."

  mkdir -p "$CLI_CACHE"
  mv "$_CLI_TMP/package/bin/supabase" "$CLI_CACHE/supabase"
  chmod +x "$CLI_CACHE/supabase"

  rm -rf "$_CLI_TMP"; _CLI_TMP=""
  trap - EXIT
}

resolve_cli() {
  # 1. An explicit override always wins.
  if [[ -n "${SUPABASE_CLI_BINARY_OVERRIDE:-}" ]]; then
    echo "$SUPABASE_CLI_BINARY_OVERRIDE"; return
  fi
  # 2. Already vendored at the pinned version.
  if [[ -x "$CLI_CACHE/supabase" ]]; then
    echo "$CLI_CACHE/supabase"; return
  fi
  # 3. Fetch and vendor it.
  download_cli >&2
  echo "$CLI_CACHE/supabase"
}

SUPABASE="$(resolve_cli)"

supa() { "$SUPABASE" "$@"; }

# Reads one key out of `supabase status -o env`, which is shell-shaped already,
# so no JSON parser (and therefore no Node) is needed.
status_value() {
  supa status -o env 2>/dev/null \
    | sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" \
    | head -1
}

# Every task that touches the stack needs a live daemon. Checking here means one
# clear message instead of whatever the CLI happens to say when it cannot reach
# the socket.
require_docker() {
  command -v docker >/dev/null 2>&1 || fail "Docker is not installed. It is the one prerequisite; see docs/local-development.md."
  docker info >/dev/null 2>&1 || fail "Docker is installed but not running. Start Docker Desktop (or dockerd) and retry."
}

require_stack() {
  require_docker
  if ! supa status >/dev/null 2>&1; then
    fail "The local stack is not running. Start it with: ./x start"
  fi
}

# Runs Deno without requiring it to be installed: use a local one if present,
# otherwise borrow the official image. This is where a container genuinely is
# the right answer — deno needs nothing from the host but the source tree.
deno_run() {
  if command -v deno >/dev/null 2>&1; then
    deno "$@"
  elif command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$ROOT":"$ROOT" -w "$ROOT" denoland/deno:2.1.4 "$@"
  else
    warn "Neither deno nor docker is available; skipping edge function checks."
    return 0
  fi
}
