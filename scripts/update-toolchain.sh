#!/usr/bin/env bash
# Re-pins the vendored toolchain in scripts/toolchain.lock.
#
#   bash scripts/update-toolchain.sh supabase 2.114.0
#   bash scripts/update-toolchain.sh bun 1.3.15
#
# Checksums come from the npm registry's own integrity hashes, so an upgrade is
# a reviewable diff of a data file rather than a silent "latest" that behaves
# one way on a laptop and another in CI.

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"

TOOL="${1:-}"
VERSION="${2:-}"
[[ -n "$TOOL" && -n "$VERSION" ]] \
  || fail "Usage: bash scripts/update-toolchain.sh <supabase|bun|deno> <version>"

require_cmd curl "to reach the npm registry"

# Each tool names its platform packages differently.
tool_platforms() {
  case "$1" in
    supabase) echo "darwin-arm64 darwin-x64 linux-arm64 linux-arm64-musl linux-x64 linux-x64-musl" ;;
    bun)      echo "darwin-aarch64 darwin-x64 linux-aarch64 linux-aarch64-musl linux-x64 linux-x64-musl" ;;
    # Deno is never vendored — it runs from its official image or a matching
    # local install — so there is no tarball to checksum.
    deno)     echo "" ;;
    *) fail "Unknown tool: $1 (supabase|bun|deno)" ;;
  esac
}

tool_package() {
  case "$1" in
    supabase) echo "@supabase/cli-$2" ;;
    bun)      echo "@oven/bun-$2" ;;
  esac
}

# The registry publishes integrity as base64; the lock stores hex so comparing
# against sha512sum output is a plain string match.
integrity_to_hex() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,base64,binascii; print(binascii.hexlify(base64.b64decode(sys.stdin.read().strip())).decode())'
  else
    base64 -d 2>/dev/null | od -An -tx1 | tr -d " \n"
  fi
}

fetch_checksum() {
  local package="$1" integrity
  integrity="$(curl -fsSL "https://registry.npmjs.org/${package}/${VERSION}" \
    | sed -n 's/.*"integrity":"sha512-\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "$integrity" ]] || fail "No sha512 integrity for ${package}@${VERSION}"
  printf '%s' "$integrity" | integrity_to_hex
}

# Rewrites just this tool's block, leaving the other tool's pins untouched.
rewrite_lock() {
  local block="$1" tmp
  tmp="$(mktemp)"
  awk -v tool="$TOOL" -v block="$block" '
    $0 ~ "^" tool "\\." { if (!done) { printf "%s", block; done = 1 } ; next }
    { print }
    END { if (!done) printf "%s", block }
  ' "$TOOLCHAIN_LOCK" > "$tmp"
  mv "$tmp" "$TOOLCHAIN_LOCK"
}

main() {
  local block platform checksum
  block="${TOOL}.version=${VERSION}"$'\n'

  for platform in $(tool_platforms "$TOOL"); do
    dim "  fetching $(tool_package "$TOOL" "$platform")@${VERSION} ..."
    checksum="$(fetch_checksum "$(tool_package "$TOOL" "$platform")")"
    block+="${TOOL}.${platform}=${checksum}"$'\n'
  done

  rewrite_lock "$block"
  bold "Pinned ${TOOL} ${VERSION} in scripts/toolchain.lock"

  # .tool-versions is generated from the lock; regenerate it in the same commit.
  bash scripts/tool-versions.sh
  dim  "Now run: rm -rf .toolchain && make doctor"

}

main "$@"
