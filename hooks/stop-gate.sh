#!/usr/bin/env bash
# Stop hook: in an ARMED repo, an agent may not declare "done" while anvil's
# Definition-of-Done gate is red on Go changes. It hands the failures back and the
# agent keeps working. Bounded (allows stop after MAX_BLOCKS so nothing is trapped);
# global kill-switch `touch ~/.claude/anvil/off`. Unarmed repos are never gated.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
MAX_BLOCKS=6

allow() { [ -n "${1:-}" ] && jq -n --arg m "$1" '{systemMessage:$m}' || printf '{}\n'; exit 0; }

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"; [ -z "$cwd" ] && cwd="$PWD"
root="$(repo_root "$cwd")"; [ -z "$root" ] && allow
is_off && allow
is_armed "$root" || allow
cd "$root" || allow

gate="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/gate.sh"
[ -x "$gate" ] || allow

# default branch for detecting Go changes + scoping the strict lint
base="${GATE_BASE:-}"
if [ -z "$base" ]; then
  base="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  [ -z "$base" ] && for b in origin/main origin/master main master; do
    git rev-parse --verify --quiet "$b" >/dev/null && { base="$b"; break; }; done
fi
[ -z "$base" ] && base="HEAD~1"

changed="$({ git diff --name-only --diff-filter=ACMR "$base"...HEAD 2>/dev/null
             git diff --name-only --diff-filter=ACMR HEAD 2>/dev/null
             git diff --name-only --cached --diff-filter=ACMR 2>/dev/null
           } | grep '\.go$' | grep -vE '\.(gen|pb)\.go$|\.sql\.go$' | sort -u)"

state="$(anvil_home)/state"; mkdir -p "$state" 2>/dev/null
counter="$state/$(repo_hash "$root").n"

[ -z "$changed" ] && { rm -f "$counter" 2>/dev/null; allow; }

n=0; [ -f "$counter" ] && n="$(cat "$counter" 2>/dev/null || echo 0)"
if [ "$n" -ge "$MAX_BLOCKS" ]; then
  rm -f "$counter" 2>/dev/null
  allow "⚠️ anvil gate still RED after $MAX_BLOCKS attempts — allowing stop so you're not trapped. This change is NOT done: run the gate to see failures, or 'touch $(anvil_home)/off' to disable anvil."
fi

out="$(NO_COLOR=1 GATE_BASE="$base" bash "$gate" quick 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then rm -f "$counter" 2>/dev/null; allow "✅ anvil gate GREEN — safe to stop."; fi

echo $((n+1)) > "$counter"
reason="$(printf '%s' "$out" | awk 'f{print} /gate summary/{f=1}')"
[ -z "$reason" ] && reason="$(printf '%s' "$out" | tail -n 40)"
full="$(printf 'anvil'"'"'s Definition-of-Done gate is RED — you are NOT done. Fix these, then stop again (I re-check every time):\n\n%s\n\nDo not weaken tests, delete assertions, or disable the gate to pass — fix the code.' "$reason")"
jq -n --arg r "$full" '{decision:"block", reason:$r}'
exit 0
