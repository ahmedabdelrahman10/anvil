#!/usr/bin/env bash
# Arm / disarm / status for the current repo. Arming enables anvil's hooks for this
# repo only (state lives in ~/.claude/anvil — zero footprint in the repo itself).
#   anvil-arm.sh arm       # /anvil:ship runs this automatically
#   anvil-arm.sh disarm
#   anvil-arm.sh status
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/lib.sh"

root="$(repo_root "$PWD")"
[ -z "$root" ] && { echo "not inside a git repo"; exit 1; }
case "${1:-status}" in
  arm)     arm_repo "$root"; echo "✓ anvil armed for: $root";;
  disarm)  rm -f "$(anvil_home)/armed/$(repo_hash "$root")" 2>/dev/null; echo "✓ anvil disarmed for: $root";;
  status)  is_armed "$root" && echo "ARMED: $root" || echo "not armed: $root";;
  *) echo "usage: anvil-arm.sh arm|disarm|status" >&2; exit 2;;
esac
