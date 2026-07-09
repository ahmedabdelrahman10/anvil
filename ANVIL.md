# ANVIL.md — anvil's engineering standard

This is the contract anvil holds a change to. With `--solo`, this file plus anvil's skills
(`go-craft`, `go-testing`) are the *only* standard — the host repo's docs are ignored.
Without `--solo`, this is additive: honor the host repo's conventions **and** this floor.

The Go idioms themselves live in the `go-craft` and `go-testing` skills — invoke them. This
file is the process: what "done" means, and why it's a machine check rather than a feeling.

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

## The loop

`/anvil:ship <task>` runs: **understand** (research the real ask — free text, Jira, or GitHub) →
**plan** (idiomatic design) → **TDD** (failing test first) → **implement** → **gate** →
**adversarial review** → **staging-verify** → **learn**. `implement → gate → review` loops until
the gate is green and reviewers are clean. You exit on the gate, not on a feeling.

## Autonomy

The agent has go/gofmt/golangci-lint/git/gh/kubectl/gcloud/docker/grpcurl and may install a
tool it needs (`go install`) rather than asking. For a fully hands-off run, launch the session
with runtime permission-bypass — the gate and hooks still hold, so autonomy never lowers the bar.

## Self-improvement

When you learn something durable, append a lesson (`lessons/CODEC.md`): cross-cutting →
`lessons/global.md` (committed to the anvil repo, travels everywhere); repo-specific →
`~/.claude/anvil/lessons/<repo>.md` (local, never touches the target repo). If a convention is
durable, propose an edit to a skill or this file. The next run should start ahead of this one.
