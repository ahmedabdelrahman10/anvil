---
description: Take a Go task through anvil's four-stage loop — research → architecture & design → implement → review — with one human approval on the spec and a machine-checkable Definition-of-Done gate.
argument-hint: <free-text task | JIRA-KEY | GitHub issue> [--solo] [--draft]
---

You are shipping a change to the current Go repository. The pipeline is exactly four stages:

1. **Research** — `anvil:researcher` turns the ask into a numbered spec list; the human approves it once.
2. **Architecture & design** — `anvil:architect` writes `design.md`: the simplest structure that satisfies the specs.
3. **Implement** — you (the main loop) build to the design and loop against the gate until green.
4. **Review** — `anvil:reviewer` reviews the diff; any critical/major finding loops back to implement → re-gate → re-review, until `APPROVE`.

Each loop is bounded by progress, not patience: if a stage fails twice for the same reason, stop
and surface it to the human — that's a blocker, not a retry.

**The task:** $ARGUMENTS

## The one rule

You do not decide when you're done. **anvil's gate decides:**

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" quick     # fast: no Docker
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" full      # + integration suite
```

It runs: format · anvil's strict structure/complexity linter on your diff · the host repo's own
lint/test · build · vet · `-race` tests · a test-theater guard. The Stop hook won't let you stop
while it's red on Go changes. Never weaken a test, delete an assertion, add `//nolint`, or disable
anvil to pass it — fix the code.

**Keep the orchestration quiet.** The researcher, architect, and reviewer run as subagents and
return only their distilled artifact (spec list, design summary + path, findings table + verdict).
You hold artifacts and pass paths, never the material they read.

## 0 · Arm & load the standard

- Arm anvil for this repo: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/anvil-arm.sh" arm`
- Read `${CLAUDE_PLUGIN_ROOT}/ANVIL.md` and invoke the `go-craft` and `go-testing` skills.
- **`--solo`:** ignore the host repo's `CLAUDE.md`/`AGENTS.md`; build only to anvil's standard and
  run the gate with `ANVIL_SOLO=1`. Without it, honor the host conventions AND anvil's floor.
- Confirm you're on a feature branch off the default branch. If not, create one named
  `<JIRA>-<slug>` (e.g. `PRI-1212-add-rate-limiter`), or `PRI-1-1-<slug>` when no ticket was given.

## 1 · Research (subagent → approved specs)

Spawn `anvil:researcher` with the task. It returns the intent as a **numbered list of one-liner
specs** (`SPEC-N` — testable statements of the *what*, covering happy path and every
error/edge/auth path), the surface it touches, the invariants that must not break, and any
BLOCKING open question. Input modes: free text, a Jira key (Atlassian MCP), a GitHub issue (`gh`).

Present the spec list to the human with `AskUserQuestion` and get approval — **this is the only
approval anvil asks for.** On approve, the list is the frozen contract; on change, edit and
re-present. If a blocking question can't be resolved from code/docs/tickets, ask it here too.
Do not implement against unapproved specs.

## 2 · Architecture & design (subagent → design.md)

Spawn `anvil:architect` with the approved specs, the researcher's surface and invariants, and a
`DESIGN_PATH` (e.g. `~/.claude/anvil/design/<repo>-<branch>.md` — never committed into the target
repo). It returns only a compact summary + the path.

`design.md` picks the **simplest correct structure**: by default that means following the repo's
existing layout — plain packages by responsibility, concrete structs, a small interface only where
a dependency genuinely needs swapping. It reaches for heavier patterns (hexagonal/clean layers,
CQRS, event sourcing) **only when the specs are genuinely complex enough to force them**, and says
why. If the architect surfaces a blocking risk, resolve it (or raise it with the human) before
implementing.

## 3 · Implement (loop with the gate until green)

Build to `design.md`. Work test-first: for each `SPEC-N`, write the failing test (it must fail for
the right reason), then the smallest idiomatic code that passes — guard clauses, small
single-purpose functions, errors wrapped with `%w`, `context.Context` first and never stored.
**Write code, not comments** — a comment only for a non-obvious *why*. The PostToolUse hook
auto-formats your Go. Commit in small, focused steps (atomic, why-not-what messages).

Run `gate.sh quick` and fix every failure — loop implement ↔ gate until GREEN. Run `gate.sh full`
for any I/O, store, migration, or RPC change and get it green too. A red strict-lint finding means
the new code is too complex — refactor, don't suppress.

## 4 · Review (loop with implement until APPROVE)

Spawn `anvil:reviewer` scoped to your diff (`git diff <default-branch>...HEAD`). It returns a
severity-ranked findings table + verdict.

**The loop:** on `REQUEST_CHANGES`, fix every critical/major finding (step 3), re-run the gate,
and re-spawn the reviewer; repeat until it returns `APPROVE`. Treat findings adversarially — real
vs. noise — but never exit early because the build is green.

## Close out

Push the branch and open the PR: `gh pr create` with the title `<JIRA>: <summary>` (or
`PRI-1-1: <summary>`; never invent a real-looking ticket). Body: what & why, the approved specs as
a checklist, and the green `gate.sh` summary. Pass `--draft` through if given.

End with: the PR link; each approved spec marked ✅/⚠️ with how it's tested; the final gate result;
and anything that genuinely needs the human. Be honest about gaps.
