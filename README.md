<div align="center">

# ⚒️ anvil

**The hard surface an agent's output gets hammered into shape against.**

![version](https://img.shields.io/badge/version-0.4.0-1f6feb)
![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-8A63D2)
![Go](https://img.shields.io/badge/Go-engineering%20loop-00ADD8?logo=go&logoColor=white)
![Flink](https://img.shields.io/badge/Flink-aware-E6526F)
![footprint](https://img.shields.io/badge/target%20repo-zero%20footprint-2da44e)

</div>

---

anvil is a portable [Claude Code](https://github.com/ahmedabdelrahman10/anvil) plugin: a Go
engineering loop that takes a task — free text, a Jira key, or a GitHub issue — to a **reviewed,
staging-verified PR**, plus a **machine-checkable Definition-of-Done gate** that makes junior-grade
code and fake tests *impossible to declare done*. It works on any Go repo and leaves **zero
footprint** in the target repo.

> **Why it exists:** the usual fixes (more agents, better prompts, richer skills) don't stick —
> guidance is advice, and advice loses to generation pressure. anvil makes the standard *mechanical*:
> a linter that fails on complexity, a gate that runs real tests, and a Stop hook that won't let an
> agent stop while any of it is red.

## Contents

- [✨ What's in the box](#-whats-in-the-box)
- [📦 Install](#-install)
- [🚀 Use](#-use)
- [✅ The Definition of Done](#-the-definition-of-done)
- [🔁 Self-improvement](#-self-improvement)
- [🗂 Layout](#-layout)

## ✨ What's in the box

### Commands

| Command | What it does |
|---|---|
| **`/anvil:ship <task>`** | The full loop: understand → **specify & approve** → plan → implement → gate → test → adversarial review → provision infra → staging-verify → learn. Loops on the gate, not on a feeling. |
| **`/anvil:design <problem>`** | Design a **Flink data/analytics platform** (analytics, big-data, events, GCP — Pub/Sub, GCS, BigQuery, Dataflow), grounded in how big companies solve it **and** how Flink already does it. Four stages, one human approval; produces a reviewed architecture, not code. `--ship` hands it to `/anvil:ship`. |
| **`/anvil:review <PR \| branch \| files \| diff>`** | A **standalone** review: five axes + the complexity budget + a Go checklist → a severity-ranked findings table + `APPROVE` / `REQUEST_CHANGES`. Doesn't run or change the ship loop. |

> **The one human approval is the spec.** anvil presents the change as a numbered list of one-liner
> specifications, turns each into a failing skeleton test, and asks you to approve that list *before*
> it writes a line of implementation.

<details>
<summary><b>Inside <code>/anvil:design</code> — the four stages</b></summary>

1. **Context-engineering research** (`anvil:designer`) — big-company patterns + Flink prior art + a flinkpedia sweep → a draft requirements list.
2. **Requirements loop** with you — your only gate.
3. **The `architecture` skill**, built from Flink-native tools only (via `anvil:architect` + `go-analytics` + `flink-infra`).
4. **Adversarial architecture review** (`anvil:arch-reviewer`), looping architecture ↔ review until the design is `GOOD`.

</details>

### The gate

`scripts/gate.sh` runs against **your diff** — not the whole repo:

1. **Format**
2. **Strict structure/complexity linter** — fails on functions > 60 lines, cognitive complexity > 20, deep nesting, mutable globals, and dead-perf.
3. **The host repo's own lint & test**
4. **Build**
5. **Vet**
6. **`-race` tests**
7. **Test-theater guard**
8. **Integration** *(`full` only)* — testcontainers.

### Hooks

Auto-format Go on save, plus a **Stop hook** that blocks "done" while the gate is red.

### Agents

Each returns only its distilled artifact, so the main loop's context stays clean.

| Agent | Role |
|---|---|
| `anvil:designer` | Context-engineering research (big-company patterns + Flink prior art + flinkpedia) → draft requirements. Run by `/anvil:design`. |
| `anvil:arch-reviewer` | Adversarial architecture review → `GOOD` / `NEEDS_WORK`; drives the design loop. |
| `anvil:researcher` | Real ask → one-liner specs. |
| `anvil:architect` | Post-approval design pass → `design.md`; also the Flink-native system-architecture stage of `/anvil:design`. |
| `anvil:test-engineer` | Proves all four test kinds are real & complete. |
| `anvil:reviewer` | Five-axis adversarial review. |
| `anvil:verifier` | Proves it runs against real deps **and** enforces that every spec was built, every required skill was applied, and no upstream agent overstated its work. |

### Skills

| Skill | Covers |
|---|---|
| `spec-driven` | The intent gate. |
| `architecture` | The post-approval design pass (Go) — principles, patterns, GoF-the-Go-way, distributed systems, ADRs. |
| `go-craft` + `go-testing` | The craftsmanship + real-tests standard, distilled from masterclass Go codebases. |
| `go-debugging` | Root-cause triage. |
| `go-api` | HTTP/gRPC contract · Auth0 · validation · status codes · Postman · protos. |
| `go-observability` | Datadog, metrics-first. |
| `go-analytics` | Events → Pub/Sub → BigQuery. |
| `flink-infra` | `<service>-infra` · helm-service-charts · Teller secrets · Envoy Gateway · Cloudflare. |
| `go-git` | Jira-first branch/PR · atomic commits · SemVer. |
| `go-docs` | ADRs · godoc · changelog. |
| `doubt-driven` | In-flight adversarial self-check. |

Uses the deeper `cc-skills-golang:*` specialists when installed.

### Orchestration & Lessons

- **Orchestration** — heavy stages run as subagents that hand back only their artifact (specs,
  `design.md` + summary, findings table, verdict); the architect's boundary rules become
  `depguard` / `go-arch-lint` checks the gate enforces; and when `bd` (beads) is installed the loop
  tracks itself as a beads epic + one issue per spec, so progress lives outside the context window
  and survives across subagents and sessions. Skipped silently if `bd` is absent.
- **Lessons** — git-versioned compounding memory (`lessons/`), plus per-repo lessons under
  `~/.claude/anvil/` that never touch the target repo.

## 📦 Install

```sh
# from this repo (local path or your private GitHub remote)
claude plugin marketplace add /path/to/anvil        # or: <you>/anvil on GitHub
claude plugin install anvil@anvil
```

**Requires on `PATH`:** `go`, `git`, `gh`.

**Optional (used when present):** `golangci-lint` (anvil installs a pinned v2 into `~/.cache/anvil`
if absent), `goimports`, `docker` (integration), `kubectl` / `gcloud` / `grpcurl` (staging verify).

## 🚀 Use

```sh
/anvil:ship add a per-tenant rate limiter to the gateway middleware
/anvil:ship PROJ-1234
/anvil:ship fix the flaky retry in the payments client --solo --draft
```

| Flag | Effect |
|---|---|
| `--solo` | Ignore the host repo's `CLAUDE.md` / `AGENTS.md` and project skills; build only to anvil's standard (and skip the host's lint/test in the gate). |
| `--no-staging` | Stop after the PR; skip staging verification. |
| `--draft` | Open the PR as a draft. |
| `--ticket` | File a Jira ticket from the understanding before coding. |

### Arming — which repos anvil gates

anvil only acts on **armed** repos, so installing it globally never hijacks ad-hoc work elsewhere.
`/anvil:ship` arms the current repo automatically. Manually:

```sh
scripts/anvil-arm.sh arm | disarm | status     # per-repo
touch ~/.claude/anvil/always-on                 # arm everywhere
touch ~/.claude/anvil/off                        # global kill-switch (disable anvil)
```

## ✅ The Definition of Done

Run it yourself any time:

```sh
bash scripts/gate.sh quick                # fast, no Docker
bash scripts/gate.sh full                 # + testcontainers integration
ANVIL_SOLO=1 bash scripts/gate.sh quick   # anvil floor only, ignore host lint/test
```

**Green means:** your new code is within the complexity budget, the host's own checks pass, tests
are real and `-race`-clean, and there's no test theater.

See [`ANVIL.md`](ANVIL.md) for the full standard and the budget table.

## 🔁 Self-improvement

Cross-cutting lessons accumulate in [`lessons/global.md`](lessons/global.md) (committed here, so
they travel with the plugin); per-repo lessons live under `~/.claude/anvil/lessons/`.
Format: [`lessons/CODEC.md`](lessons/CODEC.md).

## 🗂 Layout

```
.claude-plugin/{plugin,marketplace}.json   manifest + installable marketplace
commands/{ship,design,review}.md           /anvil:ship — the loop
                                           /anvil:design — Flink data-platform design → review loop
                                           /anvil:review — standalone review
agents/{designer,arch-reviewer,researcher,architect,test-engineer,reviewer,verifier}.md
                                           the subagents the commands spawn
skills/{spec-driven,architecture,go-craft,go-testing,go-debugging,go-api,
        go-observability,go-analytics,flink-infra,go-git,go-docs,doubt-driven}/
                                           the standard (architecture/ has a Go reference library)
hooks/{hooks.json,lib.sh,post-edit-go.sh,stop-gate.sh}   format-on-save + the Stop gate
scripts/{gate.sh,verify-staging.sh,anvil-arm.sh}         the DoD gate + staging + arming
golangci.strict.yml                        the diff-scoped complexity budget
ANVIL.md · lessons/                        the standard + compounding memory
```
