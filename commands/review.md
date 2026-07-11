---
description: Review a Go change — a PR, a branch diff, a pasted diff, or specific files — against anvil's craft standard, standalone, without running the ship loop. Emits a severity-ranked findings table + verdict.
argument-hint: "<PR URL/number | branch | file path | diff | empty = current branch vs default>"
---

You are running a **standalone** code review. This does **not** run, arm, or change the `/anvil:ship`
loop — `/anvil:ship` still spawns `anvil:reviewer` at stage 7 exactly as before. Use this when you
want a review on its own: before you open a PR, on someone else's PR, or as a second opinion. It is
the `anvil:reviewer` rubric, runnable on demand.

**What to review:** $ARGUMENTS

## 0 · Resolve the scope

Figure out what changed from `$ARGUMENTS`, in this order:

- **empty** → the current branch vs the default branch **plus** the working tree:
  `git diff "$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"...HEAD`,
  then also inspect uncommitted changes. This is the same scope `anvil:reviewer` uses.
- **a PR URL or number** → pull it with `gh pr view <n> --json title,body,files,additions,deletions`
  and `gh pr diff <n>`; also read CI state with `gh pr checks <n> --json name,state` (treat
  IN_PROGRESS/PENDING/QUEUED as non-terminal). If the GitHub MCP server is connected, you may use it
  instead. Note the PR's stated intent — you'll check the diff actually delivers it.
- **a branch name** → `git diff <default-branch>...<branch>`.
- **one or more file paths / globs** → review those files' diff vs the default branch; if a file is
  untracked or you're asked to review it whole, review the whole file.
- **a pasted diff** → review it directly.

If the scope is genuinely ambiguous (no arguments **and** a clean working tree with no branch delta),
ask what to review rather than guessing. **Review only what changed** — do not audit the whole repo.

## 1 · Load the standard

Read `${CLAUDE_PLUGIN_ROOT}/ANVIL.md` and invoke `go-craft` + `go-testing`. For the surfaces the
diff touches, also invoke the matching skills: `go-api` (HTTP/gRPC), `go-observability`
(metrics/logs), and the `cc-skills-golang:*` specialists if installed (`golang-concurrency`,
`golang-database`, `golang-grpc`, `golang-performance`, `golang-error-handling`, `golang-security`).
You are reviewing against **the standard**, not against your own idea of the task. Be adversarial:
assume the code is junior until it proves otherwise. Approve when the change genuinely improves the
codebase and clears anvil's floor — not only when it's how you'd have written it. Don't rubber-stamp,
don't soften a real defect into a "minor concern", don't pad with nits.

## 2 · Run the mechanical gate first (it's not an opinion)

If you're reviewing the **local checkout** of a Go repo, run
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" quick`. If it's red, the change is not reviewable yet —
report that as the top finding and stop. If green, review the judgment calls the gate can't make.
(Reviewing a remote PR you haven't checked out? Skip the gate and say so, and lean on the PR's CI
state from step 0 instead.)

## 3 · Review workflow

1. **Understand context** — what is the change *for*? For a PR, does the diff actually deliver the
   stated intent, and nothing unrelated it snuck in?
2. **Examine the tests first** — before the implementation. Is each behavior and error path covered?
   Can each test actually fail? (See axis 2 — test theater is the most common lie.)
3. **Review the implementation** — apply the five axes below, in order.
4. **Categorize every finding** by severity (see §Output).
5. **Verify the verification** — did the author run the tests/build, and does the evidence hold up?

## 4 · The five axes (in priority order)

1. **Correctness & silent failure** — swallowed errors, ignored returns, wrong nil handling, races
   (is it `-race` clean?), off-by-one, unhandled edge/error cases. Handle errors once (return **or**
   log, not both); wrap with `%w` to preserve the chain.
2. **Test realism (anti-theater)** — do the tests assert observable behavior? Does an integration
   test hit a REAL dependency (testcontainers/real DB) or a mock in a tautology? Is each behavior
   and each error path covered, end to end? A test that can't fail is worse than none.
3. **Craft & architecture** — small consumer-side interfaces returning domain (not SDK) types; no
   premature abstraction; small composable functions; guard clauses over nesting; `%w` wrapping with
   context; `context.Context` first, never stored; naming (MixedCaps, consistent receivers, no
   `utils`/`helpers`/`common` packages); step-down ordering. Flag god-structs/fat functions the
   linter missed, a new conditional bolted onto an unrelated flow, a refactor that relocates
   complexity instead of removing it, and feature logic leaking into a shared module. **Repeated
   conditionals are a signal of a missing abstraction.** Flag **comment noise** — comments that
   restate the code, section-banner/narration comments, commented-out code, doc comments that echo
   a signature (fix by rename/extract/delete, not prose). A *missing* comment is not a finding;
   anvil's floor is minimal comments.
4. **Security** — input validated at the boundary; third-party/RPC responses treated as untrusted;
   SQL parameterized (no string-built queries); XSS/CSRF/SSRF/path-traversal guarded; authorization
   on the right permission (403 vs 401); no secrets in code/logs; honest status/gRPC codes; no
   internals leaked in error bodies; dependencies trusted.
5. **Performance** — N+1, O(n²) over inputs, needless hot-path allocation, unbounded input/loops,
   missing preallocation (`make([]T, 0, n)`), `SELECT *`, sync work that should be async, missing
   pagination.

Also check **observability** where it applies: does every error path increment a distinct metric,
and are logs error-only (no happy-path spam, no PII)? And **compatibility**: public API / proto /
migration changes that break consumers (reserve removed proto field numbers; additive migrations;
handle unknown enum values).

## 5 · Go review checklist (apply when the diff is Go)

A quick pass distilled for Go — flag any that the diff trips:

- **Errors** — never `_ =` a real error; add context with `fmt.Errorf("…: %w", err)`; `errors.Is`
  for sentinels, `errors.As` for typed errors; handle once (return or log, not both).
- **Goroutines** — every goroutine has an exit path (ctx / done channel); `WaitGroup.Add` before
  launch; senders close channels, never receivers; never send on nil (blocks) or closed (panics).
- **Context** — `ctx context.Context` is the first param, never stored in a struct; `defer cancel()`
  for every `WithTimeout`/`WithCancel`; propagate, don't re-root; distinguish `context.Canceled`
  vs `context.DeadlineExceeded`.
- **Interfaces** — accept interfaces, return concrete types; define the interface where it's
  consumed, keep it small (1–few methods); prefer generics over `interface{}` in hot paths.
- **Receivers** — pointer when mutating / holding a `sync.Mutex` / large; value when small &
  immutable; **all methods on a type use the same receiver kind**.
- **Common Go traps** — nil vs empty slice marshals `null` vs `[]`; assigning to a nil map panics
  (`make` it first); `defer` inside a loop runs at function end (extract the body); slice aliasing
  shares the backing array (`copy` for independence); a typed-nil pointer in an interface is **not**
  a nil interface; compare `time.Time` with `.Equal`, not `==`; watch variable shadowing and (Go
  < 1.22) loop-variable capture.
- **Organization** — packages named by function (`user`, `order`), not `common`/`utils`; export only
  what's needed; use `internal/` to restrict; break import cycles with a shared type or interface.
- **Comments** — minimal: none restate the code, no section-banner/narration comments, no
  commented-out code, no `// TODO` left sitting; a comment exists only for a non-obvious *why*.
  Doc comments only where the contract is non-obvious or the host lint requires them.
- **Tools the author should have run** — `gofmt`/`goimports`, `go vet ./...`, `go test -race ./...`,
  and for hot paths `go build -gcflags='-m'` (escape analysis) + a `Benchmark…` with `-benchmem`.

## 6 · Propose the move, not just the problem

When you flag a structural issue, name the remedy — replace a conditional chain with a typed
dispatcher, collapse duplicate branches, separate orchestration from logic, move feature logic to its
owning package, reuse the canonical helper, extract a small function, delete a pass-through wrapper.
A finding that only says "this is complex" leaves the author guessing.

## 7 · Sizing & review principles

- **Size** — ~100 changed lines reviews cleanly; ~300 is fine if logically unified; ~1000 is too big
  — say so and suggest a split. A single file creeping past ~1000 lines wants decomposing. Feature
  work and pure refactoring belong in **separate** changes.
- **Approve improvement, not perfection** — approve a change that clearly improves code health even
  if imperfect; but do **not** accept "I'll clean it up later" for a real defect — require the fix.
- **Lead with leverage** — one real structural or security issue outranks ten nits. If you have one
  structural problem and ten nits, the structural problem *is* the review. Never bury it under
  cosmetics.

## Output — a severity-ranked findings table, then a verdict

Lead with a one-line **Summary** of the change and its overall quality. Then render findings as a
table (most severe first), never prose paragraphs:

| # | severity | file:line | finding | fix |
|---|----------|-----------|---------|-----|

`severity` ∈ {critical, major, minor, nit}. Each finding is specific and actionable with the concrete
fix. Distinguish real defects from nits honestly. Follow the table with a short **What looks good**
list (genuine positives — don't invent them), then exactly one verdict line:

- `VERDICT: APPROVE` — no critical/major findings; nits are optional.
- `VERDICT: REQUEST_CHANGES` — at least one critical/major finding; list which must be fixed.

(Severity maps to the usual review labels: critical = blocks merge, major = must address, minor =
consider/optional, nit = optional/FYI.)

## If connectors are available

- **Source control** (`gh` CLI or the GitHub MCP server) — pull the PR diff and CI/check state
  automatically from a PR URL/number, and note failing checks as evidence.
- **Project tracker** (Atlassian/Jira MCP) — if the change references a ticket (or the branch/PR is
  Jira-prefixed per `go-git`), read it and verify the change actually addresses the stated
  requirements; link findings back to the ticket where useful.
- **Knowledge base** (`flinkpedia`) — check the change against team/service conventions when the
  surface is a known Flink service.

If none are connected, everything above still works on a pasted diff, a local branch, or files.

## Want the heavier pass?

For an adversarial, fresh-context review you can spawn the `anvil:reviewer` agent (and, if installed,
`pr-review-toolkit:silent-failure-hunter`, `pr-review-toolkit:pr-test-analyzer`,
`pr-review-toolkit:type-design-analyzer`) scoped to the same diff and merge their findings. This
command is the fast inline path; those agents are the same rubric run in isolation.

## Tips

1. **Give context** — "this is a hot path" or "this handles PII" focuses the review.
2. **Name concerns** — "focus on concurrency" or "just security" narrows it.
3. **Include the tests** — coverage and test realism are half the review.
