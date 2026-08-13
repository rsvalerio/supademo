#!/usr/bin/env bash
# Fetching pinned tool binaries without installing anything.
#
# Both tools this project vendors — the Supabase CLI and Bun — are published as
# per-platform npm packages containing a single executable. So the download,
# checksum and cache logic is identical, and lives here once; cli.sh and bun.sh
# only supply the naming.
#
# curl, tar and a shell are the whole toolchain: no Node, no npm client, no
# global install.

TOOLCHAIN_LOCK="$ROOT/scripts/toolchain.lock"
VENDOR_DIR="$ROOT/.toolchain"

# The lock file is data: `tool.key=value`, one per line. Read with sed because
# macOS's bash 3.2 has no associative arrays.
lock_value() { sed -n "s/^$1\.$2=//p" "$TOOLCHAIN_LOCK" | head -1; }

sha512_of() {
  if command -v sha512sum >/dev/null 2>&1; then
    sha512sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 512 "$1" | cut -d' ' -f1
  else
    fail "Neither sha512sum nor shasum is available; cannot verify the download."
  fi
}

# True on musl systems (Alpine), which need a different build.
is_musl() { ls /lib/ld-musl-* >/dev/null 2>&1; }

# Echoes the path to `cmd` when it is already installed AT EXACTLY the pinned
# version, and fails otherwise. That is the whole rule: provenance does not
# matter — mise, asdf, Homebrew, a manual install — but the version does. It is
# what lets .tool-versions save a download without letting a stray 1.3.11 stand
# in for a pinned 1.3.14.
path_tool_matching() {
  local cmd="$1" want="$2" found version
  found="$(command -v "$cmd" 2>/dev/null)" || return 1
  [[ -n "$found" ]] || return 1
  version="$("$found" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [[ "$version" == "$want" ]] || return 1
  echo "$found"
}

_vendor_tmp=""
_vendor_cleanup() { [[ -n "$_vendor_tmp" ]] && rm -rf "$_vendor_tmp"; }

# vendor_fetch <tool> <platform> <npm-package> <path-inside-archive> <destination>
#
# Downloads the pinned tarball, verifies it against the lock, and moves the one
# executable we want into place. Refuses to install anything it cannot verify.
vendor_fetch() {
  local tool="$1" platform="$2" package="$3" inner_path="$4" dest="$5"
  local version expected actual url

  version="$(lock_value "$tool" version)"
  expected="$(lock_value "$tool" "$platform")"
  [[ -n "$version" ]]  || fail "scripts/toolchain.lock has no version for '$tool'."
  [[ -n "$expected" ]] || fail "scripts/toolchain.lock has no $tool checksum for platform '$platform'."

  require_cmd curl "to fetch $tool"
  require_cmd tar  "to unpack $tool"

  url="https://registry.npmjs.org/${package}/-/$(basename "$package")-${version}.tgz"
  bold "Fetching ${tool} ${version} (${platform}) — one time, into .toolchain/"

  # An EXIT trap, not RETURN: a RETURN trap would fire after the local it needs
  # has already gone out of scope.
  _vendor_tmp="$(mktemp -d)"
  trap _vendor_cleanup EXIT

  curl -fsSL "$url" -o "$_vendor_tmp/pkg.tgz" \
    || fail "Could not download $tool from the npm registry. Are you online?"

  actual="$(sha512_of "$_vendor_tmp/pkg.tgz")"
  [[ "$actual" == "$expected" ]] || fail "Checksum mismatch for ${tool} (${platform}).
  expected $expected
  actual   $actual
Refusing to run an unverified binary."

  tar -xzf "$_vendor_tmp/pkg.tgz" -C "$_vendor_tmp"
  [[ -f "$_vendor_tmp/$inner_path" ]] \
    || fail "Downloaded $tool archive has no $inner_path."

  mkdir -p "$(dirname "$dest")"
  mv "$_vendor_tmp/$inner_path" "$dest"
  chmod +x "$dest"

  _vendor_cleanup; _vendor_tmp=""
  trap - EXIT
}
