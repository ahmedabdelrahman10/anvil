#!/usr/bin/env bash
#
# gate.sh — anvil's portable, machine-checkable DEFINITION OF DONE.
#
# Runs against ANY Go repo. It imposes anvil's craftsmanship floor on the code a
# change introduces, and — unless ANVIL_SOLO=1 — also runs the host repo's own
# lint/test so the change still satisfies that repo's CI. It is what the Stop hook
# enforces (an agent can't declare done while this is red) and what /anvil:ship
# loops against.
#
#   MODES   quick (default): format · anvil-strict-lint(diff) · host-lint · build ·
#                            vet · tests(-race) · test-theater guard.  No Docker.
#           full           : quick + integration (testcontainers/tagged), Docker-gated.
#
#   ENV     GATE_BASE       diff base (default: auto-detected origin default branch)
#           ANVIL_SOLO=1    ignore the host repo's own lint/test; anvil floor only
#           ANVIL_GOLANGCI  path to a golangci-lint binary to use
#           GATE_SKIP       space-separated step names to skip
#
# EXIT 0 iff every step that ran passed.

set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SELF/.." && pwd)"
STRICT_CFG="$PLUGIN_DIR/golangci.strict.yml"
MODE="${1:-quick}"
FAILS=0
SUMMARY=""

REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO" ] && { echo "anvil gate: not inside a git repo — nothing to gate."; exit 0; }
cd "$REPO"
if [ ! -f go.mod ]; then
  echo "anvil gate: no go.mod at $REPO — anvil's gate is Go-only, skipping."; exit 0
fi

# colors only on a real terminal
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_0=$'\033[0m'
else c_red=''; c_grn=''; c_yel=''; c_dim=''; c_0=''; fi
step()  { printf '%s┌─ %s%s\n' "$c_dim" "$1" "$c_0"; }
ok()    { printf '%s└─ PASS%s %s\n' "$c_grn" "$c_0" "$1"; SUMMARY="${SUMMARY}  ${c_grn}✓${c_0} $1\n"; }
warn()  { printf '%s└─ WARN%s %s\n' "$c_yel" "$c_0" "$1"; SUMMARY="${SUMMARY}  ${c_yel}!${c_0} $1\n"; }
fail()  { printf '%s└─ FAIL%s %s\n' "$c_red" "$c_0" "$1"; SUMMARY="${SUMMARY}  ${c_red}✗${c_0} $1\n"; FAILS=$((FAILS+1)); }
skip()  { printf '%s└─ skip%s %s\n' "$c_dim" "$c_0" "$1"; }
skipped() { case " ${GATE_SKIP:-} " in *" $1 "*) return 0;; *) return 1;; esac; }

# --- default branch for diff-scoping -----------------------------------------
BASE="${GATE_BASE:-}"
if [ -z "$BASE" ]; then
  BASE="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -z "$BASE" ]; then
    for b in origin/main origin/master main master; do
      git rev-parse --verify --quiet "$b" >/dev/null && { BASE="$b"; break; }
    done
  fi
fi
[ -z "$BASE" ] && BASE="HEAD~1"   # last resort: only the latest commit is "new"

# --- resolve a golangci-lint binary ------------------------------------------
GOLANGCI=""
resolve_golangci() {
  [ -n "${ANVIL_GOLANGCI:-}" ] && { GOLANGCI="$ANVIL_GOLANGCI"; return 0; }
  command -v golangci-lint >/dev/null 2>&1 && { GOLANGCI="golangci-lint"; return 0; }
  local cache="$HOME/.cache/anvil/bin"
  [ -x "$cache/golangci-lint" ] && { GOLANGCI="$cache/golangci-lint"; return 0; }
  echo "  (installing golangci-lint v2.12.2 into $cache — one time)…"
  mkdir -p "$cache"
  if GOBIN="$cache" go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.12.2 >/dev/null 2>&1 \
     && [ -x "$cache/golangci-lint" ]; then
    GOLANGCI="$cache/golangci-lint"; return 0
  fi
  return 1
}

changed_go() {
  { git diff --name-only --diff-filter=ACMR "$BASE"...HEAD 2>/dev/null
    git diff --name-only --diff-filter=ACMR HEAD 2>/dev/null
    git diff --name-only --cached --diff-filter=ACMR 2>/dev/null
  } | sort -u | grep '\.go$' | grep -vE '\.(gen|pb)\.go$|\.sql\.go$' || true
}
has_make_target() { [ -f Makefile ] && make -n "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ 1. FORMAT --
run_format() {
  skipped format && { skip format; return; }
  step "format (gofmt + goimports, auto-fix)"
  local files fixed=""; files="$(changed_go)"
  [ -z "$files" ] && { ok "format — no changed Go files"; return; }
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if [ -n "$(gofmt -l "$f" 2>/dev/null)" ]; then
      gofmt -w "$f"; command -v goimports >/dev/null 2>&1 && goimports -w "$f"; fixed="$fixed $f"
    fi
  done <<< "$files"
  [ -n "$fixed" ] && warn "format — auto-formatted:$fixed" || ok "format — changed files clean"
}

# --------------------------------------------------- 2. ANVIL STRICT LINT (diff) --
run_anvil_lint() {
  skipped anvil-lint && { skip anvil-lint; return; }
  step "anvil strict lint — structure/complexity, new code vs $BASE"
  if ! resolve_golangci; then
    fail "anvil-lint — no golangci-lint and couldn't install one (offline?). Set ANVIL_GOLANGCI or install golangci-lint."; return
  fi
  if "$GOLANGCI" run -c "$STRICT_CFG" --new-from-merge-base="$BASE" ./... ; then
    ok "anvil-lint — new code within the complexity budget"
  else
    fail "anvil-lint — new code exceeds the budget (funlen/gocognit/gocyclo/nestif/globals/perf). Flatten with guard clauses; extract small funcs. reproduce: $GOLANGCI run -c $STRICT_CFG --new-from-merge-base=$BASE ./..."
  fi
}

# ------------------------------------------------------- 3. HOST LINT (if any) --
run_host_lint() {
  skipped host-lint && { skip host-lint; return; }
  [ "${ANVIL_SOLO:-0}" = "1" ] && { skip "host-lint (--solo)"; return; }
  if has_make_target lint-ci; then step "host lint (make lint-ci)"; make lint-ci && ok "host-lint (make lint-ci)" || fail "host-lint — reproduce: make lint-ci"; return; fi
  if has_make_target lint; then step "host lint (make lint)"; make lint && ok "host-lint (make lint)" || fail "host-lint — reproduce: make lint"; return; fi
  if ls .golangci.y*ml >/dev/null 2>&1; then
    step "host lint (repo .golangci config)"
    resolve_golangci || { warn "host-lint — repo has .golangci config but no golangci-lint available"; return; }
    "$GOLANGCI" run ./... && ok "host-lint (repo config)" || fail "host-lint — reproduce: $GOLANGCI run ./..."
    return
  fi
  skip "host-lint (repo defines none)"
}

# ------------------------------------------------------------------- 4. BUILD --
run_build() { skipped build && { skip build; return; }; step "build (go build ./...)"; go build ./... && ok build || fail "build — reproduce: go build ./..."; }
run_vet()   { skipped vet && { skip vet; return; }; step "vet (go vet ./...)"; go vet ./... && ok vet || fail "vet — reproduce: go vet ./..."; }

# -------------------------------------------------------------------- 5. TESTS --
run_tests() {
  skipped tests && { skip tests; return; }
  if [ "${ANVIL_SOLO:-0}" != "1" ] && has_make_target test; then
    step "tests (make test)"; make test && ok "tests (make test)" || fail "tests — reproduce: make test"; return
  fi
  step "tests (go test -race ./...)"
  go test -race ./... && ok "tests (-race)" || fail "tests — reproduce: go test -race ./..."
}

# ------------------------------------------------------- 6. TEST-THEATER GUARD --
run_theater() {
  skipped theater && { skip theater; return; }
  step "test-theater guard"
  local tests srcs msgs="" hard=0
  tests="$(changed_go | grep '_test\.go$' || true)"
  srcs="$(changed_go | grep -v '_test\.go$' || true)"
  if [ -n "$tests" ]; then
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      if grep -qE '\bfunc (Test|Benchmark|Fuzz)[A-Z]' "$f" 2>/dev/null \
         && ! grep -qE '(assert|require)\.[A-Za-z]+\(|\.(Error|Fatal|Errorf|Fatalf)\(|t\.(Error|Fatal)|InitializeScenario|godog' "$f" 2>/dev/null; then
        msgs="$msgs\n    - $f defines tests but makes no assertions"; hard=1
      fi
    done <<< "$tests"
  fi
  if [ -n "$srcs" ]; then
    local untested=""
    while IFS= read -r f; do
      grep -qE '^func ' "$f" 2>/dev/null || continue
      local dir; dir="$(dirname "$f")"
      printf '%s\n' "$tests" | grep -q "^$dir/" || untested="$untested $f"
    done <<< "$srcs"
    [ -n "$untested" ] && msgs="$msgs\n    - source changed with no test in the same package:$untested"
  fi
  if [ "$hard" -eq 1 ]; then fail "test-theater — assertion-free test(s):$(printf '%b' "$msgs")"
  elif [ -n "$msgs" ]; then warn "test-theater — review these (not blocking):$(printf '%b' "$msgs")"
  else ok "test-theater — changed tests assert; touched packages carry tests"; fi
}

# ------------------------------------------------------------- 7. INTEGRATION --
run_integration() {
  skipped integration && { skip integration; return; }
  step "integration"
  if ! grep -q 'testcontainers' go.mod 2>/dev/null && ! has_make_target integration-test \
     && ! grep -rlq '//go:build integration' --include='*.go' . 2>/dev/null; then
    skip "integration (repo defines none)"; return
  fi
  if ! docker info >/dev/null 2>&1; then fail "integration — Docker not running (needed for testcontainers). Start Docker, then re-run."; return; fi
  if has_make_target integration-test; then make integration-test && ok "integration (make)" || fail "integration — reproduce: make integration-test"
  else go test -tags=integration -count=1 ./... && ok "integration (-tags=integration)" || fail "integration — reproduce: go test -tags=integration ./..."; fi
}

printf '%s══ anvil gate (%s) · %s · base=%s%s ══%s\n' "$c_dim" "$MODE" "${REPO##*/}" "$BASE" "$([ "${ANVIL_SOLO:-0}" = 1 ] && echo ' · solo')" "$c_0"
run_format
run_anvil_lint
run_host_lint
run_build
run_vet
run_tests
run_theater
[ "$MODE" = "full" ] && run_integration

printf '\n%s══ gate summary (%s) ══%s\n' "$c_dim" "$MODE" "$c_0"
printf '%b' "$SUMMARY"
if [ "$FAILS" -gt 0 ]; then printf '\n%sGATE RED — %d step(s) failed. Not done.%s\n' "$c_red" "$FAILS" "$c_0"; exit 1; fi
printf '\n%sGATE GREEN — definition of done met (%s).%s\n' "$c_grn" "$MODE" "$c_0"; exit 0
