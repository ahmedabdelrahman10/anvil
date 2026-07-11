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
- **`/anvil:design <problem>`** — design a **Flink data/analytics platform** (analytics, big-data,
  events, GCP — Pub/Sub, GCS, BigQuery, Dataflow), grounded in how big companies solve it **and** how
  Flink already does it. Four stages, **one human approval**: a **context-engineering research**
  subagent (`anvil:designer` — big-company patterns + Flink prior art + a flinkpedia sweep) → a
  **requirements loop** with you that's your only gate → the **`architecture` skill** built from
  Flink-native tools only (via `anvil:architect` + `go-analytics` + `flink-infra`) → an **adversarial
  architecture review** (`anvil:arch-reviewer`), looping architecture ↔ review until the design is
  `GOOD`. Produces a reviewed system architecture, not code. `--ship` hands it to `/anvil:ship`.
- **`/anvil:review <PR | branch | files | diff>`** — a **standalone** review: the `anvil:reviewer`
  rubric (five axes + the complexity budget + a Go checklist) run on demand against a PR, a branch
  diff, a pasted diff, or specific files. Emits a severity-ranked findings table + `APPROVE` /
  `REQUEST_CHANGES`. It does **not** run or change the ship loop — `/anvil:ship` still reviews at
  stage 7 exactly as before.
- **The gate** (`scripts/gate.sh`) — format · a strict structure/complexity linter scoped to
  your **diff** (functions >60 lines, cognitive complexity >20, deep nesting, mutable globals,
  dead-perf all fail) · the host repo's own lint · build · vet · `-race` tests · a
  **test-theater guard** · (full) the host test suite + testcontainers integration. `quick` scopes
  the `-race` run to the **changed packages** for a fast inner loop; `full` + CI run the whole module.
- **Hooks** — auto-format Go on save; a **Stop hook** that blocks "done" while the gate is red
  (and caches the last green by diff fingerprint, so a repeated stop with no new Go edit is instant).
- **Agents** — `anvil:designer` (context-engineering research: big-company patterns + Flink prior art
  + flinkpedia → draft requirements, run by `/anvil:design`), `anvil:arch-reviewer` (adversarial
  architecture review → `GOOD`/`NEEDS_WORK`, drives the design loop), `anvil:researcher` (real ask →
  one-liner specs), `anvil:architect` (post-approval design pass → `design.md`; also the Flink-native
  system-architecture stage of `/anvil:design`), `anvil:test-engineer` (proves all four test kinds are real & complete),
  `anvil:reviewer` (five-axis adversarial review), `anvil:verifier` (proves it runs against real deps
  **and** enforces that every spec was built, every required skill was applied, and no upstream agent
  overstated its work). Each returns only its distilled artifact, so the main loop's context stays
  clean.
- **Orchestration** — heavy stages run as subagents that hand back only their artifact (specs,
  `design.md` + summary, findings table, verdict); the architect's boundary rules become
  `depguard`/`go-arch-lint` checks the gate enforces; and when `bd` (beads) is installed the loop
  tracks itself as a beads epic + one issue per spec, so progress lives outside the context window
  and survives across subagents and sessions. Skipped silently if `bd` is absent. Independent
  subagents **fan out in parallel** (the review panel; the local gate alongside staging verify),
  each loads only the skills its surface needs, and long waits (deploy, CI) are polled with `/loop`
  / `ScheduleWakeup` rather than by holding the context open — so a run is faster and cheaper.
- **Skills** — `spec-driven` (the intent gate), `architecture` (the post-approval design pass, Go —
  principles, patterns, GoF-the-Go-way, distributed systems, ADRs), `go-craft` + `go-testing` (the
  craftsmanship + real-tests standard, distilled from masterclass Go codebases), `go-debugging`
  (root-cause triage),
  `go-api` (HTTP/gRPC contract · Auth0 · validation · status codes · Postman · protos),
  `go-observability` (Datadog metrics-first), `go-analytics` (events → Pub/Sub → BigQuery),
  `flink-infra` (`<service>-infra` · helm-service-charts · Teller secrets · Envoy Gateway ·
  Cloudflare), `go-git` (Jira-first branch/PR · atomic commits · SemVer), `go-docs` (ADRs · godoc ·
  changelog), and `doubt-driven` (in-flight adversarial self-check). Uses the deeper
  `cc-skills-golang:*` specialists when installed.
- **Lessons** — git-versioned compounding memory (`lessons/`), plus per-repo lessons under
  `~/.claude/anvil/` that never touch the target repo.

## Works with Claude Code and Codex

anvil ships as a Claude Code plugin, but its standard and gate are **tool-agnostic** — plain
markdown + portable bash, no dependency on any one harness. [`AGENTS.md`](AGENTS.md) at the repo
root is the entry point any AGENTS.md-aware agent (Codex, or a manual run) reads: it maps the
Claude-only affordances (slash commands, subagents, hooks, the `Skill` tool) to portable
equivalents, and the Definition-of-Done gate runs the same for everyone:

```sh
bash /path/to/anvil/scripts/gate.sh quick   # from inside the target Go repo — any shell, no plugin harness
```

Claude Code users get the orchestrated loop via the slash commands below; other tools follow the
same phased instructions in `commands/*.md` and enforce the same `gate.sh`.

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
ANVIL.md · AGENTS.md                         the standard · the tool-agnostic entry point (Codex/any agent)
commands/{ship,design,review}.md            /anvil:ship — the loop · /anvil:design — Flink data-platform design → review loop · /anvil:review — standalone review
agents/{designer,arch-reviewer,researcher,architect,test-engineer,reviewer,verifier}.md   the subagents the commands spawn
skills/{spec-driven,architecture,go-craft,go-testing,go-debugging,go-api,go-observability,go-analytics,flink-infra,go-git,go-docs,doubt-driven}/   the standard (architecture/ has a Go reference library)
hooks/{hooks.json,lib.sh,post-edit-go.sh,stop-gate.sh}   format-on-save + the Stop gate
scripts/{gate.sh,verify-staging.sh,anvil-arm.sh}         the DoD gate + staging + arming
golangci.strict.yml                          the diff-scoped complexity budget
lessons/                                     compounding memory (global here + per-repo under ~/.claude/anvil)
```
