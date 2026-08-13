#!/usr/bin/env bash
# Running Deno without requiring it to be installed.
#
# This is the one place a container genuinely is the right answer: Deno needs
# nothing from the host but the source tree, so the official image is a drop-in
# for a local install.

DENO_IMAGE="denoland/deno:2.1.4"

deno_run() {
  if command -v deno >/dev/null 2>&1; then
    deno "$@"
  elif docker_available; then
    docker run --rm -v "$ROOT":"$ROOT" -w "$ROOT" "$DENO_IMAGE" "$@"
  else
    warn "Neither deno nor a running Docker is available; skipping edge function checks."
    return 0
  fi
}
