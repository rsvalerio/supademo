#!/usr/bin/env bash
# The single entry point for every script in scripts/.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"
#
# Order matters: log has no dependencies, env defines ROOT, vendor needs both,
# and cli/bun build on vendor.

set -euo pipefail

# Sourcing twice is harmless but wasteful — it would re-resolve the CLI.
[[ -n "${SUPADEMO_LIB_LOADED:-}" ]] && return 0
SUPADEMO_LIB_LOADED=1

_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$_lib/log.sh"
source "$_lib/env.sh"
source "$_lib/guard.sh"
source "$_lib/vendor.sh"
source "$_lib/cli.sh"
source "$_lib/bun.sh"
source "$_lib/status.sh"
source "$_lib/deno.sh"

load_dotenv
