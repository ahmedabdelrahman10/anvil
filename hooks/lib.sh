#!/usr/bin/env bash
# Shared helpers for anvil's hooks. anvil acts ONLY on "armed" repos, so installing
# it globally never hijacks ad-hoc work in a repo you didn't opt in.
#
#   arm a repo   : /anvil:ship does it automatically, or `touch ~/.claude/anvil/armed/<hash>`
#   arm globally : touch ~/.claude/anvil/always-on
#   kill switch  : touch ~/.claude/anvil/off      (disables anvil everywhere)

anvil_home() { echo "${ANVIL_HOME:-$HOME/.claude/anvil}"; }
repo_root()  { git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null; }
repo_hash()  { printf '%s' "$1" | shasum 2>/dev/null | cut -c1-16; }
is_off()     { [ -f "$(anvil_home)/off" ]; }
is_armed() { # $1 = repo root
  [ -f "$(anvil_home)/always-on" ] && return 0
  [ -n "${1:-}" ] && [ -f "$(anvil_home)/armed/$(repo_hash "$1")" ]
}
arm_repo() { # $1 = repo root
  [ -z "${1:-}" ] && return 1
  mkdir -p "$(anvil_home)/armed" 2>/dev/null
  : > "$(anvil_home)/armed/$(repo_hash "$1")"
}
