#!/usr/bin/env bash
# Re-pins the Supabase CLI in scripts/cli.lock.
#
#   bash scripts/update-cli.sh 2.114.0
#
# Fetches each platform package's SHA-512 straight from the npm registry, so a
# CLI upgrade is a reviewable diff of a data file rather than a silent "latest"
# that behaves differently on a laptop than in CI.

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"

VERSION="${1:-}"
[[ -n "$VERSION" ]] || fail "Usage: bash scripts/update-cli.sh <version>"

PLATFORMS=(darwin-arm64 darwin-x64 linux-arm64 linux-arm64-musl linux-x64 linux-x64-musl)

require_cmd curl "to reach the npm registry"

# The registry publishes integrity as base64; the lock file stores hex so the
# comparison against sha512sum output is a plain string match.
integrity_to_hex() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,base64,binascii; print(binascii.hexlify(base64.b64decode(sys.stdin.read().strip())).decode())'
  else
    base64 -d 2>/dev/null | od -An -tx1 | tr -d " \n"
  fi
}

fetch_checksum() {
  local platform="$1" integrity
  integrity="$(curl -fsSL "https://registry.npmjs.org/@supabase/cli-${platform}/${VERSION}" \
    | sed -n 's/.*"integrity":"sha512-\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "$integrity" ]] || fail "No sha512 integrity for @supabase/cli-${platform}@${VERSION}"
  printf '%s' "$integrity" | integrity_to_hex
}

main() {
  local tmp platform checksum
  tmp="$(mktemp)"
  {
    echo "# Pinned Supabase CLI. Regenerate with: bash scripts/update-cli.sh <version>"
    echo "# Checksums are the npm registry's own SHA-512 integrity hashes, hex-encoded."
    echo "version=$VERSION"
  } > "$tmp"

  for platform in "${PLATFORMS[@]}"; do
    dim "  fetching @supabase/cli-${platform}@${VERSION} ..."
    checksum="$(fetch_checksum "$platform")"
    echo "${platform}=${checksum}" >> "$tmp"
  done

  mv "$tmp" "$CLI_LOCK"
  bold "Pinned Supabase CLI $VERSION in scripts/cli.lock"
  dim  "Now run: rm -rf .supabase-cli && ./supa --version"
}

main "$@"
