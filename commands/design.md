---
description: Design a Flink system — analytics / big-data / event-driven / GCP platforms (Pub/Sub, GCS, BigQuery, Dataflow) — grounded in how big companies solve it AND how Flink already does it. A context-engineering research subagent → a requirements loop that is your one approval → the architecture skill (Flink-native tools only) → an adversarial architecture review, looping architecture↔review until the design is good.
argument-hint: "<free-text problem | idea | JIRA-KEY | GitHub issue> [--ship]"
---

You are running a **system-design pass for a Flink data/analytics platform component** — an analytics
or big-data system, an event pipeline, a GCP-backed service (Pub/Sub, Google Cloud Storage,
BigQuery, Dataflow), or similar. You produce a **researched, requirements-approved, Flink-native
system architecture that has survived an adversarial review** — not code. It writes no product code
and arms no gate.

**The problem:** $ARGUMENTS

## The shape of this command

Five stages. **You (the human) act exactly once** — you approve the requirements in stage 2. After
that the command runs on its own, looping architecture ↔ review until the design is good:

1. **Context-engineering research** (subagent) — turn the description into real context: how big
   companies build this class of system, how **Flink** already does it, and everything **flinkpedia**
   knows about it. Returns a brief + a *draft* requirements list + the open questions.
2. **Requirements — your one approval** (here, with you) — work the draft and the questions with you
   until you both agree, then you approve. This is the last thing you have to do.
3. **Architecture** (subagent → invokes the **`architecture` skill**) — turn the approved
   requirements into a system architecture, built **only from tools Flink already uses** (GCP,
   Pub/Sub, GCS, BigQuery, the shared `goflink/*` modules, `helm-service-charts`).
4. **Architecture review** (subagent) — an adversarial review of that architecture: boundaries,
   coupling/cohesion, circular dependencies, patterns, SOLID/DIP, Flink-native correctness, scale,
   cost, failure modes. Scored, with findings.
5. **Loop 3 ↔ 4 until the review says the design is GOOD**, bounded by real progress.

### One harness constraint, stated plainly

A subagent runs once and returns — it **cannot** hold a back-and-forth with you. So the *research*
runs in a subagent (stage 1), but the *requirements conversation* (stage 2) runs here, in the
command's own context, because only the main loop can ask you questions. The research subagent
supplies the draft and the questions; you and I settle them here; I re-spawn the researcher when an
answer needs deeper digging. The effect is the researcher-driven Q&A you asked for.

### Where this sits vs. the `architecture` skill

This command **drives** the design (research → requirements → review loop); the `architecture` skill
is the **engine** it calls in stage 3 to produce the structure. This decides the *what* and the
*system shape*; the skill decides the *how*. Do not skip the review loop — an unreviewed architecture
is a draft, not a decision.

## 0 · Frame the input

Decide the input mode from `$ARGUMENTS`: free text (author the framing yourself), a **Jira key**
(read via the Atlassian MCP — load with ToolSearch), or a **GitHub issue** (`gh`). Note the current
repo (a new service? an existing Flink service being extended?) — the research and the architecture
both need to know whether this is greenfield or an addition.

## 1 · Context-engineering research (subagent)

Spawn **`anvil:designer`**. Pass it the framed problem, the input mode, and a **`DESIGN_PATH`** — an
anvil-local path, **never** committed into the target repo:

```
~/.claude/anvil/design/<repo>-<slug>.design.md
```

It does context engineering in its own context: researches **how big companies build this class of
system** (deep-research / web — real trade-offs and failure modes, not marketing), **how Flink
already does it** (the codebase + platform conventions), and **queries flinkpedia** for every
relevant internal doc — prior RFCs/ADRs, existing services and their owners, the data-streaming and
BigQuery conventions, naming standards. It returns a research brief, a **draft requirements list**,
and the **open questions** it needs you to answer — and nothing it read. You hold the summary.

## 2 · Requirements — your one approval (the loop with you)

Run the requirements loop **here**, seeded by the designer's draft + questions:

1. Present the draft requirements and the open questions to the human with `AskUserQuestion` (focused,
   a few at a time — scope, scale, latency, consistency, cost ceiling, data retention, who consumes
   the output, what's explicitly out of scope).
2. Fold the answers in. When an answer opens a real research gap, **re-spawn `anvil:designer`** with
   the new constraints to deepen the brief and tighten the requirements — don't guess.
3. Repeat until the requirements are complete and you both agree, then ask for **explicit approval**.

On approval the requirements are **frozen** — that is the single human gate, and the last thing the
human does. Freeze them into the design doc at `DESIGN_PATH`. Do not proceed to architecture against
unapproved requirements.

## 3 · Architecture (subagent → the `architecture` skill, Flink-native)

Spawn **`anvil:architect`** with the **approved requirements**, the researcher's findings summary,
`DESIGN_PATH`, and the constraint that this is a **system/data-platform design built only from tools
Flink already uses**. It invokes the **`architecture` skill** and, for this domain, **`go-analytics`**
(events → Pub/Sub → BigQuery, dead-letter, the mandatory BQ subscription) and **`flink-infra`** (the
`<service>-infra` repo, `helm-service-charts` `cloudresources` for topics/buckets/BigQuery/DBs,
`workload` for the deployment). It produces the system architecture into `DESIGN_PATH`: the
components and their boundaries, the data/event flow, the GCP topology (Pub/Sub topics + schemas, GCS
buckets + layout, BigQuery datasets/tables, any Dataflow/stream job), the storage & schema/compat
shape, the failure/consistency model, the metrics (`go-observability`), and an ADR for the load-bearing
decision. It returns only a summary + the path. **No invented technology** — if a need has no
Flink-native answer, it says so as an open risk rather than reaching for something new.

## 4 · Architecture review (subagent)

Spawn **`anvil:arch-reviewer`** scoped to `DESIGN_PATH` (and the current codebase, if the design
extends one). It runs the architecture-review rubric adversarially — structure & boundaries,
dependency direction + coupling/cohesion, **circular dependencies**, design-pattern fit, SOLID/DIP at
the component level, **whether it truly uses Flink-native tools** (or smuggled in something new),
data-consistency and failure modes, scale and **cost**, and observability. It returns a **quality
score**, a severity-ranked findings table (Issue · Location · Impact · Recommendation · Effort ·
Priority), and a verdict: **`GOOD`** (design is sound) or **`NEEDS_WORK`** (with the findings that
must be addressed). It returns only that — not the doc it read.

## 5 · Loop until the design is good

**Loop `3 ↔ 4`:** on `NEEDS_WORK`, hand the findings back to `anvil:architect` to revise the
architecture at `DESIGN_PATH`, then re-run `anvil:arch-reviewer`. Repeat until the reviewer returns
`GOOD`. Bound it by real progress: if the same finding survives a couple of revisions, or two
options are genuinely a toss-up on data you don't have, **stop and surface it to the human** — that's
a real decision, not a retry. If a revision would reopen a *requirement*, stop and go back to stage 2
(don't silently change what the human approved).

## 6 · Present the design

Relay the outcome — not the doc's body, the decision:

1. **What we're building** — the framing and the approved requirements in a few lines.
2. **The architecture** — the components, the data/event flow, and the GCP topology (Pub/Sub / GCS /
   BigQuery / jobs), each named to its Flink-native tool.
3. **The decision (ADR)** — the load-bearing choice, the force that drove it, and what was rejected.
4. **Review result** — the final `GOOD` verdict and the quality score; any residual low-priority
   findings and open risks.
5. **Infra to provision** — what `flink-infra` / `go-analytics` will need (topics, buckets, BQ
   datasets, secrets, gateway), named.
6. **The path** to the design doc.

- **`--ship`** — after you confirm, hand the approved requirements + the reviewed architecture to
  `/anvil:ship` to build it. Without the flag, the reviewed architecture is the deliverable; run
  `/anvil:ship` yourself when ready.
- If the decision is significant or cross-team, offer to land it as a shareable Flink RFC via
  `/flink:doc:rfc` (don't duplicate that template here).

## Honesty

This produces **judgment**, not a gate result — there's no `gate.sh` for an architecture. Be honest
about what the research covered, where a scale/cost number is an estimate vs. grounded in real Flink
usage data, and which risks are unresolved. Ground the requirements and the sizing in **real** Flink
usage/scale data (BigQuery, existing service metrics) where you can, not synthetic numbers. A truthful
"this rests on a throughput assumption we haven't measured" beats a confident false topology.
