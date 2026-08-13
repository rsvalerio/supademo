#!/usr/bin/env bash
# Preconditions. Each returns cleanly or fails with a message a human can act
# on — never a raw socket error or a missing-command trace.

require_cmd() {
  local cmd="$1" reason="${2:-}"
  command -v "$cmd" >/dev/null 2>&1 \
    || fail "\`$cmd\` is required${reason:+ $reason}, but was not found on PATH."
}

require_docker() {
  command -v docker >/dev/null 2>&1 \
    || fail "Docker is not installed. It is the one prerequisite; see docs/local-development.md."
  docker info >/dev/null 2>&1 \
    || fail "Docker is installed but not running. Start Docker Desktop (or dockerd) and retry."
}

docker_available() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

require_stack() {
  require_docker
  stack_running || fail "The local stack is not running. Start it with: make start"
}

# True when something is listening. Uses bash's own /dev/tcp, so it needs
# neither lsof nor netstat nor nc.
port_in_use() { (echo >"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }
