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

**Write code, not comments.** anvil's floor is *minimal comments*: clear names, small functions,
and flat control flow do the explaining. No comments that restate the code, no section-banner or
narration comments, no commented-out code. A comment exists only for a non-obvious *why* the code
can't carry (an invariant, a deliberate workaround, a footgun); doc comments only where the
contract is non-obvious or the host linter requires them. Missing comments are never a finding;
redundant ones are. The idioms live in `go-craft`.

## The loop

**Before the loop (optional):** when the system itself is unsettled — a Flink data/analytics platform,
an event pipeline, a GCP-backed service (Pub/Sub, GCS, BigQuery, Dataflow) — run
`/anvil:design <problem>` first. It runs a **context-engineering research** subagent (how big companies
do it + how Flink already does it + a flinkpedia sweep), settles the **requirements with you** (your
one approval), then invokes the **`architecture` skill** built **only from tools Flink already uses**,
and puts the result through an **adversarial architecture review** — looping architecture ↔ review
until the design is good. It produces a reviewed system architecture; `--ship` hands it to the loop
below. It decides the *what* and the system shape; the `architecture` skill decides the *how-in-Go*
once specs are frozen. Skip it when the task is already well-scoped.

`/anvil:ship <task>` runs: **understand** (research the real ask — free text, Jira, or GitHub) →
**specify & approve** → **design** (`anvil:architect` runs the `architecture` skill → `design.md`) →
**implement** (fill the skeleton tests, TDD) → **gate** → **test** (all kinds real & complete) →
**adversarial review** → **provision infra** → **staging-verify** → **learn**.
`implement → gate → test → review` loops until the gate is green, the tests are real and complete,
and reviewers are clean. You exit on the gate, not on a feeling.

**Quiet orchestration, deterministic checks, beads-tracked.** Every heavy stage runs in a *subagent*
that returns only its distilled artifact (specs, `design.md` + summary, coverage matrix, findings
table, verdict) — the main loop holds the artifacts and passes paths, never the material the agents
read, so the context stays clean and the run stays cheap. Prefer a machine check over a judgment
call wherever one exists: the gate is the Definition of Done, and the architect's boundary rules
become `depguard`/`go-arch-lint` rules the gate enforces. When `bd` (beads) is installed the loop
tracks itself as a beads epic + one issue per spec, so progress lives outside the context window and
survives across subagents and sessions; without `bd`, those steps are skipped silently.

**Fast and cheap by construction.** Independent subagents fan out **in parallel** (the review panel;
the local gate alongside staging verify), each loading **only** the skills its surface touches and
preferring the `architecture/references/*` one-pagers over the deep pattern tree. The `quick` gate
scopes its `-race` run to the *changed* packages and the Stop hook caches the last green by diff
fingerprint, so the inner loop stays fast on a large repo; `full` + CI are the whole-repo safety net.
Long waits (staging deploy, CI) are polled with `/loop`/`ScheduleWakeup` or a background task, not by
holding the context open.

**The one human gate — the spec.** After research, anvil presents the change as a numbered list of
one-liner specifications (the *what*, not the *how*), turns each into a **failing skeleton test**,
and asks you to approve that list. That is the only approval anvil asks for — a wrong spec is one
line to fix here versus a whole PR later. See the `spec-driven` skill.

## The skills (invoked every run)

The Go idioms and process live in skills, invoked by the loop: `spec-driven` (the intent gate),
`architecture` (the post-approval design pass → `design.md`, run by the `anvil:architect` subagent),
`go-craft` and `go-testing` (the craft + real-tests standard), `go-debugging` (root-cause triage),
`go-api` (HTTP/gRPC contract, Auth0, validation, status codes, Postman, gRPC protos via
`grpc-protos`, roles via `iac-auth0`), `go-observability` (Datadog metrics-first, logs on error
only), `go-analytics` (events → Pub/Sub → BigQuery via `data-streaming-platform-events`),
`flink-infra` (the `<service>-infra` repo, `helm-service-charts`, Teller secrets, Envoy Gateway,
Cloudflare), `go-git` (Jira-first branch/PR naming, atomic commits, SemVer), `go-docs` (ADRs +
godoc + changelog), and `doubt-driven` (in-flight adversarial self-check on non-trivial decisions).
`go-craft`/`go-testing`/`spec-driven`/`go-git`/`go-observability` fire every run; `architecture`
fires once, right after spec approval; the rest on the surfaces they apply to.

## Autonomy

The agent has go/gofmt/golangci-lint/git/gh/kubectl/gcloud/docker/grpcurl and may install a
tool it needs (`go install`) rather than asking. For a fully hands-off run, launch the session
with runtime permission-bypass — the gate and hooks still hold, so autonomy never lowers the bar.

## Self-improvement

When you learn something durable, append a lesson (`lessons/CODEC.md`): cross-cutting →
`lessons/global.md` (committed to the anvil repo, travels everywhere); repo-specific →
`~/.claude/anvil/lessons/<repo>.md` (local, never touches the target repo). If a convention is
durable, propose an edit to a skill or this file. The next run should start ahead of this one.
