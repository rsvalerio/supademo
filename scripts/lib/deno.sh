#!/usr/bin/env bash
# Deno: formatting, linting and typechecking supabase/functions.
#
# Deno is the deployment target there, not a preference — the Supabase Edge
# Runtime is a Deno fork, and the functions use Deno.serve, EdgeRuntime.waitUntil
# and Supabase.ai. `deno check` is also the only type checker that resolves
# `npm:` specifiers the way that runtime does.
#
# Unlike the CLI and Bun, Deno is not vendored: it is only ever a dev-time
# checker, and its official image is a drop-in that needs nothing from the host
# but the source tree. This is the one place a container genuinely is the right
# answer.

deno_version() { lock_value deno version; }
deno_image()   { echo "denoland/deno:$(deno_version)"; }

# A local deno is used only at the pinned version. `deno fmt` output changes
# between releases, so `make fmt --check` would otherwise pass on one machine
# and fail on another.
deno_run() {
  local on_path
  if on_path="$(path_tool_matching deno "$(deno_version)")"; then
    "$on_path" "$@"
  elif docker_available; then
    docker run --rm -v "$ROOT":"$ROOT" -w "$ROOT" "$(deno_image)" "$@"
  else
    warn "No deno $(deno_version) and no running Docker; skipping edge function checks."
    return 0
  fi
}
