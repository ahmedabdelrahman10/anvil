# ANVIL.md — anvil's engineering standard

This is the contract anvil holds a change to. With `--solo`, this file plus anvil's skills
(`go-craft`, `go-testing`, `architecture`) are the *only* standard — the host repo's docs are
ignored. Without `--solo`, this is additive: honor the host repo's conventions **and** this floor.

The Go idioms live in the `go-craft` and `go-testing` skills — invoke them. This file is the
process: what "done" means, and why it's a machine check rather than a feeling.

## Why anvil exists

Agents write junior Go and fake tests not because they don't know better — the guidance is
usually right there — but because guidance is *advice*, and advice loses to generation
pressure. anvil makes the standard **mechanical**: a gate a machine runs, and a Stop hook that
won't let an agent stop while it's red. Good work becomes required; fake work becomes
impossible to pass off as done.

## Definition of Done — the gate

`bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" quick|full` is the only answer to "is this done?":

- **format** — gofmt + goimports (auto-fixed).
- **anvil strict lint (diff-scoped)** — the complexity budget below, on new code only.
- **host lint/test** — the repo's own `make lint`/`make test` (or golangci with its config),
  so your PR passes their CI too. Skipped under `--solo`.
- **build · vet · `-race` tests · test-theater guard.**
- **integration** (`full`) — testcontainers / the repo's real-dependency suite.

The Stop hook enforces this in an **armed** repo (`/anvil:ship` arms it): you can't stop while
it's red on Go changes. Bounded (6 blocks, then it lets you go with a warning). Kill-switch:
`touch ~/.claude/anvil/off`. Never weaken a test, delete an assertion, `//nolint`, or disable
anvil to pass — fix the code.

## The complexity budget (enforced on your diff)

The reference-repo numbers (wtf/bolt/groupcache/memberlist/upspin), as linter thresholds on
**new code only**:

| Smell | Limit | Linter |
|---|---|---|
| Function too long | 60 lines / 40 statements | `funlen` |
| Does too much | cognitive complexity ≤ 20 | `gocognit` |
| Too many branches/loops | cyclomatic ≤ 15 | `gocyclo` |
| Nested if/else | depth budget (min 4) | `nestif` |
| Mutable global state | none | `gochecknoglobals` |
| Hidden init | no `init()` | `gochecknoinits` |
| Copy-paste | ≤ 150 tokens | `dupl` |
| Ignores performance | perf checks on | `gocritic` |

Trip one and the fix is almost never `//nolint` — it's guard clauses + early return to flatten
nesting, and extracting small single-purpose functions. A genuinely-immutable global
(`regexp.MustCompile`, a lookup table, a sentinel `error`) may carry
`//nolint:gochecknoglobals // <reason>` — with a reason.

**Write code, not comments.** anvil's floor is *minimal comments*: clear names, small functions,
and flat control flow do the explaining. A comment exists only for a non-obvious *why* the code
can't carry. Missing comments are never a finding; redundant ones are.

## The loop

`/anvil:ship <task>` runs exactly four stages:

1. **Research** — `anvil:researcher` turns the ask (free text, Jira, or GitHub issue) into a
   numbered list of one-liner specs; the human approves that list **once** — the only approval
   anvil asks for. A wrong spec is one line to fix here versus a whole PR later.
2. **Architecture & design** — `anvil:architect` runs the `architecture` skill and writes
   `design.md`: the **simplest correct** structure for the approved specs. By default that's the
   repo's existing layout; heavier patterns only when the specs force them.
3. **Implement** — the main loop builds to the design, test-first, and loops against the gate
   until GREEN.
4. **Review** — `anvil:reviewer` adversarially reviews the diff. Any critical/major finding loops
   back to implement → re-gate → re-review, until `APPROVE`. Then the PR opens.

**Quiet orchestration.** The researcher, architect, and reviewer run as subagents that return only
their distilled artifact (specs, design summary + path, findings table + verdict) — the main loop
holds artifacts and passes paths, never the material the agents read. Prefer a machine check over
a judgment call wherever one exists: the gate is the Definition of Done.

## The skills

`architecture` (the post-approval design pass, run by `anvil:architect`), `go-craft` and
`go-testing` (the craft + real-tests standard, invoked every run and by the reviewer).

## Autonomy

The agent has go/gofmt/golangci-lint/git/gh and may install a tool it needs (`go install`)
rather than asking. For a fully hands-off run, launch the session with runtime permission-bypass —
the gate and hooks still hold, so autonomy never lowers the bar.
