#!/usr/bin/env bash
# PostToolUse(Edit|Write|MultiEdit): auto-format the Go file just written — but only
# in an armed repo. Formatting is deterministic and judgement-free, so we fix it here
# rather than spend a gate failure on it. Never blocks.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

input="$(cat)"
fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
case "$fp" in *.go) ;; *) exit 0 ;; esac
[ -f "$fp" ] || exit 0

is_off && exit 0
is_armed "$(repo_root "$(dirname "$fp")")" || exit 0

gofmt -w "$fp" 2>/dev/null
command -v goimports >/dev/null 2>&1 && goimports -w "$fp" 2>/dev/null
exit 0
