# anvil

**The hard surface an agent's output gets hammered into shape against.**

anvil is a portable Claude Code plugin: a Go engineering loop that takes a task — free text, a
Jira key, or a GitHub issue — to a reviewed, staging-verified PR, and a **machine-checkable
Definition-of-Done gate** that makes junior-grade code and fake tests *impossible to declare
done*. It works on any Go repo and leaves **zero footprint** in the target repo.

It exists because the usual fixes (more agents, better prompts, richer skills) don't stick:
guidance is advice, and advice loses to generation pressure. anvil makes the standard
mechanical — a linter that fails on complexity, a gate that runs real tests, and a Stop hook
that won't let an agent stop while any of it is red.

## What's in the box

- **`/anvil:ship <task>`** — the loop: understand → **specify & approve** → plan → implement →
  gate → **test** → adversarial review → **provision infra** → staging-verify → learn. Loops on
  the gate, not on a feeling. The **one human approval** is the spec: anvil presents the change as
  a numbered list of one-liner specifications, makes each a failing skeleton test, and asks you to
  approve that list before it writes a line.
- **The gate** (`scripts/gate.sh`) — format · a strict structure/complexity linter scoped to
  your **diff** (functions >60 lines, cognitive complexity >20, deep nesting, mutable globals,
  dead-perf all fail) · the host repo's own lint/test · build · vet · `-race` tests · a
  **test-theater guard** · (full) testcontainers integration.
- **Hooks** — auto-format Go on save; a **Stop hook** that blocks "done" while the gate is red.
- **Agents** — `anvil:researcher` (real ask → one-liner specs), `anvil:test-engineer` (proves all
  four test kinds are real & complete), `anvil:reviewer` (five-axis adversarial review),
  `anvil:verifier` (proves it runs against real deps **and** enforces that every spec was built,
  every required skill was applied, and no upstream agent overstated its work).
- **Skills** — `spec-driven` (the intent gate), `go-craft` + `go-testing` (the craftsmanship +
  real-tests standard, distilled from masterclass Go codebases), `go-debugging` (root-cause triage),
  `go-api` (HTTP/gRPC contract · Auth0 · validation · status codes · Postman · protos),
  `go-observability` (Datadog metrics-first), `go-analytics` (events → Pub/Sub → BigQuery), and
  `flink-infra` (`<service>-infra` · helm-service-charts · Teller secrets · Envoy Gateway ·
  Cloudflare). Uses the deeper `cc-skills-golang:*` specialists when installed.
- **Lessons** — git-versioned compounding memory (`lessons/`), plus per-repo lessons under
  `~/.claude/anvil/` that never touch the target repo.

## Install

```sh
# from this repo (local path or your private GitHub remote)
claude plugin marketplace add /path/to/anvil        # or: <you>/anvil on GitHub
claude plugin install anvil@anvil
```

Requires on PATH: `go`, `git`, `gh`. Optional but used when present: `golangci-lint` (anvil
installs a pinned v2 into `~/.cache/anvil` if absent), `goimports`, `docker` (integration),
`kubectl`/`gcloud`/`grpcurl` (staging verify).

## Use

```sh
/anvil:ship add a per-tenant rate limiter to the gateway middleware
/anvil:ship PROJ-1234
/anvil:ship fix the flaky retry in the payments client --solo --draft
```

- **`--solo`** — ignore the host repo's `CLAUDE.md`/`AGENTS.md` and project skills; build only
  to anvil's standard (and skip the host's lint/test in the gate).
- **`--no-staging`** — stop after the PR; skip staging verification.
- **`--draft`** — open the PR as a draft.
- **`--ticket`** — file a Jira ticket from the understanding before coding.

### Arming (which repos anvil gates)

anvil only acts on **armed** repos, so installing it globally never hijacks ad-hoc work
elsewhere. `/anvil:ship` arms the current repo automatically. Manually:

```sh
bash "$(dirname "$(command -v anvil 2>/dev/null)")"/... # or just:
scripts/anvil-arm.sh arm | disarm | status     # per-repo
touch ~/.claude/anvil/always-on                 # arm everywhere
touch ~/.claude/anvil/off                        # global kill-switch (disable anvil)
```

## The Definition of Done

Run it yourself any time:

```sh
bash scripts/gate.sh quick     # fast, no Docker
bash scripts/gate.sh full      # + testcontainers integration
ANVIL_SOLO=1 bash scripts/gate.sh quick   # anvil floor only, ignore host lint/test
```

Green means: your new code is within the complexity budget, the host's own checks pass, tests
are real and `-race`-clean, and there's no test theater. See [`ANVIL.md`](ANVIL.md) for the full
standard and the budget table.

## Self-improvement

Cross-cutting lessons accumulate in [`lessons/global.md`](lessons/global.md) (committed here, so
they travel with the plugin); per-repo lessons live under `~/.claude/anvil/lessons/`. Format:
[`lessons/CODEC.md`](lessons/CODEC.md).

## Layout

```
.claude-plugin/{plugin,marketplace}.json   manifest + installable marketplace
commands/ship.md                            /anvil:ship — the loop
agents/{researcher,test-engineer,reviewer,verifier}.md   the subagents the loop spawns
skills/{spec-driven,go-craft,go-testing,go-debugging,go-api,go-observability,go-analytics,flink-infra}/SKILL.md   the standard
hooks/{hooks.json,lib.sh,post-edit-go.sh,stop-gate.sh}   format-on-save + the Stop gate
scripts/{gate.sh,verify-staging.sh,anvil-arm.sh}         the DoD gate + staging + arming
golangci.strict.yml                          the diff-scoped complexity budget
ANVIL.md · lessons/                          the standard + compounding memory
```
