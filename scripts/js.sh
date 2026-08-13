#!/usr/bin/env bash
# JavaScript workspace tasks, run through Bun.
#
#   bash scripts/js.sh install|typecheck|test|run
#
# Scope: packages/ and apps/ — the shared domain layer and the frontends that
# will live there. NOT supabase/functions, which is Deno's (see functions.sh);
# the Edge Runtime is a Deno fork and those files use APIs Bun does not have.

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"

js_install() {
  bun_run install "$@"
}

# Bun executes TypeScript without checking it, so typechecking is still tsc's
# job — run through Bun rather than Node.
js_typecheck() {
  [[ -d node_modules ]] || js_install
  local pkg
  for pkg in packages/*/; do
    [[ -f "$pkg/tsconfig.json" ]] || continue
    step "typecheck ${pkg%/}"
    bun_run x tsc --noEmit --project "$pkg"
  done
}

js_test() {
  [[ -d node_modules ]] || js_install
  # No test files yet; bun test exits non-zero on an empty run, which would be a
  # confusing failure rather than an honest "nothing to do".
  if ! find packages apps -name '*.test.ts' -o -name '*.spec.ts' 2>/dev/null | grep -q .; then
    warn "No JavaScript tests yet. The database suite is: make test"
    return 0
  fi
  bun_run test "$@"
}

case "${1:-}" in
  install)   shift; js_install "$@" ;;
  typecheck) shift; js_typecheck "$@" ;;
  test)      shift; js_test "$@" ;;
  run)       shift; bun_run "$@" ;;
  *) fail "Unknown js command: ${1:-} (install|typecheck|test|run)" ;;
esac
