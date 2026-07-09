---
description: Take a Go task from a one-line ask to a reviewed, staging-verified PR — end to end, in a loop that exits only when anvil's Definition-of-Done gate is green.
argument-hint: <free-text task | JIRA-KEY | GitHub issue> [--solo] [--no-staging] [--draft] [--ticket]
---

You are shipping a change to the current Go repository, end to end. The human's
involvement should be, at most, approving the final PR. Work the loop below **in
order**; within it, `implement → gate → review` loops until the gate is green and
reviewers are clean.

**The task:** $ARGUMENTS

## The one rule that makes this different

You do not decide when you're done. **anvil's gate decides.** Run it with:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" quick     # fast: no Docker
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" full      # + testcontainers integration
```

It runs: format · **anvil's strict structure/complexity linter on your diff** (functions
>60 lines, cognitive complexity >20, deep nesting, mutable globals, dead-perf all FAIL) ·
the host repo's own lint/test (so your PR passes their CI) · build · vet · `-race` tests ·
a **test-theater guard**. The Stop hook will not let you stop while it's red on Go changes.
Do not weaken a test, delete an assertion, add `//nolint`, or disable anvil to pass it —
**fix the code.** A strict finding you truly believe is wrong is the rare thing to raise
with the human, not to silence.

## 0 · Arm & isolate

- Arm anvil for this repo (enables the gate hooks here, zero repo footprint):
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/anvil-arm.sh" arm`
- Load anvil's craft standard: read `${CLAUDE_PLUGIN_ROOT}/ANVIL.md` and invoke the
  `anvil` skills (`go-craft`, `go-testing`). If the deeper `cc-skills-golang:*`
  specialists are installed, use them for the surfaces you touch (grpc, database,
  concurrency, performance, security, error-handling).
- **`--solo` mode:** ignore the host repo's `CLAUDE.md`/`AGENTS.md` and any project-level
  skills entirely — build ONLY to anvil's standard (ANVIL.md + anvil skills), and run the
  gate with `ANVIL_SOLO=1` so it skips the host's lint/test too. Without `--solo`, honor
  the host repo's conventions AND anvil's floor (anvil is additive).
- Confirm you're on a feature branch off the default branch (not the default branch
  itself). If not, create one: `<KEY>-<slug>` if the task has/gets a ticket, else `anvil-<slug>`.

## 1 · Understand the real ask (research — do not skip)

Most junior output comes from solving the *stated* task instead of the *intended* one.
Before any code, produce a short **Understanding** (write it to a scratch note; do not
commit it):

- **What does the user actually want, and why?** Restate it. Identify the input mode:
  - **Free text (default):** the description above IS the brief — there's nothing to read,
    so *you* author the acceptance criteria. Highest risk of building the wrong thing:
    spend the most care here.
  - **A Jira key** (e.g. `PROJ-123`): read it and its links via the Atlassian MCP.
  - **A GitHub issue/PR** (`#123` or URL): read it with `gh`.
  - If an MCP/tool isn't authorized, say so and fall back to `gh`/web/repo docs — don't
    silently skip research.
- **Acceptance criteria** — a list of *testable* statements. This is the contract for the
  rest of the run (your tests in step 3, your staging assertions in step 8). Make them concrete.
- **The surface** — which packages/files/ports/RPCs/tables this touches. Name the files.
- **Invariants you must not break** — read the repo (unless `--solo`) to learn them: public
  API/proto compatibility, determinism, migration safety, concurrency assumptions.
- **Open questions.** If any is genuinely blocking and unresolvable from code/docs/tickets,
  **ask the user now** (AskUserQuestion) — before building the wrong thing. Otherwise state
  your assumption and proceed.

Spawn `anvil:researcher` (or an `Explore` agent) when the surface is unfamiliar — get the
conclusion, not a file dump. If `--ticket` was passed, file a Jira ticket from this
Understanding (title = the ask, body = the criteria) via the `atlassian:jira` skill,
confirm it with the user first, and use its key for the branch/PR.

## 2 · Plan the idiomatic design

Decide *how*, judged against ANVIL.md's craft bar (small composable functions, small
consumer-side interfaces, guard clauses over nesting, no premature abstraction, no mutable
globals, performance considered on hot paths). Write the plan:

- Files to change/add; new types and interfaces (≤~5 methods, declared where consumed);
  the dependency direction (inner layers import nothing outward).
- Performance: name any N+1 / O(n²) / hot-path allocation risk and how you avoid it.
- **Test strategy up front:** which table-driven unit tests, which BDD scenarios (if the
  repo uses godog/cucumber), and — for any I/O or store change — which **integration** test
  (testcontainers or the repo's harness) hitting the real dependency.
- Reject the over-engineered option. Three simple lines beat a premature abstraction.

For a non-trivial design, spawn a `Plan` agent to adversarially check it: *is this the
simplest correct design that fits the codebase?*

## 3 · TDD — write the failing test first

For each acceptance criterion, write the test **before** the implementation: table-driven
unit tests (`t.Parallel()`, testify), a BDD scenario if the repo has that layer, and a real
**integration** test for I/O/store changes. Run them; confirm they **fail for the right
reason** (an assertion, not a compile error). A test that can't fail is theater.

## 4 · Implement to green

Write the smallest idiomatic code that passes the tests. Guard clauses, small single-
purpose functions, small interfaces, errors wrapped with `%w`, `context.Context` first and
never stored, structured logging with `ctx`, injected clocks. The PostToolUse hook
auto-formats your Go. Commit in small, focused steps.

## 5 · Gate (the hard Definition of Done)

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" quick` (prefix `ANVIL_SOLO=1` if `--solo`).
Fix every failure — loop `4 ↔ 5` until GREEN. Then run `... gate.sh full` for any I/O,
store, migration, or RPC change (boots the integration suite) and get it green too. A red
strict-lint finding means your new code is too complex/nested/global — refactor, don't suppress.

## 6 · Adversarial review (parallel, then fix, then re-gate)

Spawn reviewers **concurrently**, scoped to your diff (`git diff <default-branch>...HEAD`):

- `anvil:reviewer` — craft + idiomatic-Go adherence + smell hunt.
- If installed: `pr-review-toolkit:silent-failure-hunter` (swallowed errors),
  `pr-review-toolkit:pr-test-analyzer` (coverage **and test realism** — do integration tests
  hit a real dependency, or are they mocked into meaninglessness?),
  `pr-review-toolkit:type-design-analyzer` (interface/abstraction quality).

Treat findings adversarially: real vs. noise, **fix the real ones** (back to step 4), re-gate.
Repeat until reviewers return only justifiable nits. Do not exit early because the build is green.

## 7 · Open the PR

Push. `gh pr create` with title `<KEY>: <summary>` if there's a ticket, else a plain imperative
`<summary>` (never invent a fake ticket number). Body: **what & why** (from step 1), the
**acceptance criteria as a checklist**, **test evidence** (paste the green `gate.sh full`
summary), **risk/rollback**. `--draft` if the flag was passed; fill the repo's PR template if any.

## 8 · Verify on staging (unless `--no-staging`)

A green gate proves the code; staging proves the system. After the change deploys to staging,
use `${CLAUDE_PLUGIN_ROOT}/scripts/verify-staging.sh` to port-forward the real service and run a
real request against it (it exports `$ANVIL_PORT`):

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-staging.sh" --service <name> --remote-port <port> \
  [--cluster <c> --project <p> --region <r>] -- <grpcurl|curl … localhost:$ANVIL_PORT …>
```

Poll the deploy first (`gh run list`/`gh run view`; treat IN_PROGRESS/QUEUED as non-terminal).
Assert **each acceptance criterion** against the running service, and **re-run the critical
assertion** — once-green-once-red is a FAIL. Report exactly what you asserted and the actual
responses; never claim verified work you didn't observe. If you couldn't verify on staging, say so.

## 9 · Learn (self-improve, across repos)

If you hit a repo trap, a pattern that worked, or a durable convention, append a lesson:

- **Cross-cutting** (any Go repo) → `${CLAUDE_PLUGIN_ROOT}/lessons/global.md` (follow
  `${CLAUDE_PLUGIN_ROOT}/lessons/CODEC.md`). Commit it to the anvil repo so it travels.
- **Repo-specific** → `~/.claude/anvil/lessons/<repo>.md` (created on demand; never touches
  the target repo).

## Close out

End with: the PR link; each acceptance criterion marked ✅/⚠️ with how it was verified (unit /
BDD / integration / staging); the final `gate.sh full` result; and anything that genuinely needs
the human (a real ambiguity, a risky migration, the PR approval). Be honest about gaps — a truthful
"staging not verified because X" beats a confident false "verified."
