#!/usr/bin/env bash
# Output primitives. Everything user-facing goes through these, so colour
# handling and stream choice are decided in exactly one place.
#
# Colour is suppressed when stdout is not a terminal or NO_COLOR is set, which
# keeps CI logs and piped output readable.

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  _C_BOLD=$'\033[1m'; _C_DIM=$'\033[2m'; _C_RED=$'\033[31m'
  _C_GREEN=$'\033[32m'; _C_YELLOW=$'\033[33m'; _C_OFF=$'\033[0m'
else
  _C_BOLD=""; _C_DIM=""; _C_RED=""; _C_GREEN=""; _C_YELLOW=""; _C_OFF=""
fi

bold() { printf '%s%s%s\n' "$_C_BOLD" "$*" "$_C_OFF"; }
dim()  { printf '%s%s%s\n' "$_C_DIM" "$*" "$_C_OFF"; }
step() { printf '\n%s==> %s%s\n' "$_C_BOLD" "$*" "$_C_OFF"; }

# Status lines, aligned so a run reads as a column.
pass() { printf '  %s✓%s %-22s %s\n' "$_C_GREEN" "$_C_OFF" "$1" "${2:-}"; }
info() { printf '  %s•%s %-22s %s\n' "$_C_YELLOW" "$_C_OFF" "$1" "${2:-}"; }
miss() { printf '  %s✗%s %-22s %s\n' "$_C_RED" "$_C_OFF" "$1" "${2:-}"; }

# Diagnostics go to stderr so they survive `... | head` and never pollute a
# value being captured by a caller.
warn() { printf '%s%s%s\n' "$_C_YELLOW" "$*" "$_C_OFF" >&2; }
fail() { printf '%s%s%s\n' "$_C_RED" "$*" "$_C_OFF" >&2; exit 1; }
