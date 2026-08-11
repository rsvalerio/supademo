#!/usr/bin/env bash
# Re-pins the Supabase CLI in scripts/_cli.sh.
#
#   bash scripts/update-cli.sh 2.114.0
#
# Fetches the SHA-512 of every platform package straight from the npm registry
# and rewrites the version and checksum table. Bumping the CLI is then a
# reviewable diff rather than a silent "latest".

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

VERSION="${1:?usage: update-cli.sh <version>}"
PLATFORMS=(darwin-arm64 darwin-x64 linux-arm64 linux-arm64-musl linux-x64 linux-x64-musl)

command -v python3 >/dev/null 2>&1 \
  || { echo "python3 is needed to decode the registry's base64 integrity hashes" >&2; exit 1; }

TABLE=""
for plat in "${PLATFORMS[@]}"; do
  echo "  fetching @supabase/cli-$plat@$VERSION ..." >&2
  hash="$(curl -fsSL "https://registry.npmjs.org/@supabase/cli-${plat}/${VERSION}" \
    | python3 -c '
import sys, json, base64, binascii
d = json.load(sys.stdin)
algo, b64 = d["dist"]["integrity"].split("-", 1)
assert algo == "sha512", algo
print(binascii.hexlify(base64.b64decode(b64)).decode())
')"
  TABLE+="$(printf '    %-18s echo "%s" ;;\n' "${plat})" "$hash")"$'\n'
done

python3 - "$VERSION" "$TABLE" <<'PY'
import sys, re, pathlib
version, table = sys.argv[1], sys.argv[2]
p = pathlib.Path("scripts/_cli.sh"); s = p.read_text()
s = re.sub(r'SUPABASE_CLI_VERSION="[^"]+"', f'SUPABASE_CLI_VERSION="{version}"', s)
s = re.sub(r'(cli_checksum\(\) \{\n  case "\$1" in\n).*?(    \*\) echo "" ;;)',
           lambda m: m.group(1) + table + m.group(2), s, flags=re.S)
p.write_text(s)
print(f"Pinned Supabase CLI {version}")
PY

echo "Now run: rm -rf .supabase-cli && ./supa --version"
