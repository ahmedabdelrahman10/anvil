---
description: Take a Go task from a one-line ask to a reviewed, staging-verified PR — end to end, with a single human approval on the spec, in a loop that exits only when anvil's Definition-of-Done gate is green.
argument-hint: <free-text task | JIRA-KEY | GitHub issue> [--solo] [--no-staging] [--draft] [--ticket]
---

You are shipping a change to the current Go repository, end to end. The human's involvement is, at
most, **one approval — the spec list in step 2** — plus the final PR. Work the loop below **in
order**. Four stages each loop back into `implement → gate` and only release you when they come
back clean — you never advance past a red stage:

- **gate** (5): loop `implement ↔ gate` until GREEN.
- **test** (6): `anvil:test-engineer` → any gap/red test → back to implement → re-gate → re-run
  test-engineer, until `TESTS_COMPLETE`.
- **review** (7): `anvil:reviewer` → any critical/major finding → back to implement → re-gate →
  re-review, until `APPROVE`.
- **verify** (10): `anvil:verifier` — runtime on staging **plus** enforcement (every approved spec
  built & passing, every required skill's fingerprint present, no upstream agent overstated its
  work) → any `FAILED` → back to implement → re-gate → re-test → re-review → redeploy → re-verify,
  until `VERIFIED`.

Each loop is bounded by real progress, not patience: if a stage keeps failing for the same reason
after a couple of passes, stop and surface it to the human — that's a real blocker, not a retry.

**The task:** $ARGUMENTS

## The one rule that makes this different

You do not decide when you're done. **anvil's gate decides.** Run it with:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" quick     # fast: no Docker
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" full      # + testcontainers integration
```

It runs: format · **anvil's strict structure/complexity linter on your diff** (functions >60
lines, cognitive complexity >20, deep nesting, mutable globals, dead-perf all FAIL) · the host
repo's own lint/test (so your PR passes their CI) · build · vet · `-race` tests · a **test-theater
guard**. The Stop hook will not let you stop while it's red on Go changes. Do not weaken a test,
delete an assertion, add `//nolint`, or disable anvil to pass it — **fix the code.** A strict
finding you truly believe is wrong is the rare thing to raise with the human, not to silence.

## 0 · Arm, isolate & load the standard

- Arm anvil for this repo (enables the gate hooks here, zero repo footprint):
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/anvil-arm.sh" arm`
- Read `${CLAUDE_PLUGIN_ROOT}/ANVIL.md` and **invoke anvil's skills — every run**: `go-craft`,
  `go-testing`, `spec-driven`, `go-git`, and `go-observability` (every production feature gets
  metrics). Add per-surface: `go-api` (HTTP/gRPC surface), `go-analytics` (emits an analytics/BI
  event or sends data to BigQuery), `flink-infra` (needs any runtime resource — config, secret,
  topic, bucket, DB, gateway exposure, Datadog monitor), `go-docs` (a significant/irreversible
  decision or a public API/proto change), `doubt-driven` (before baking in a non-trivial or
  hard-to-reverse decision), and `go-debugging` the moment anything goes red. Use the deeper
  `cc-skills-golang:*` specialists for the surfaces you touch (grpc, database, concurrency,
  performance, security, error-handling) when installed.
- **`--solo` mode:** ignore the host repo's `CLAUDE.md`/`AGENTS.md` and any project-level skills
  entirely — build ONLY to anvil's standard (ANVIL.md + anvil skills), and run the gate with
  `ANVIL_SOLO=1` so it skips the host's lint/test too. Without `--solo`, honor the host repo's
  conventions AND anvil's floor (anvil is additive).
- Confirm you're on a feature branch off the default branch (not the default branch itself). If
  not, create one named per `go-git` — **it starts with the Jira id**: `<JIRA>-<slug>` (e.g.
  `PRI-1212-add-rate-limiter`), or `PRI-1-1-<slug>` when no ticket was given.

## 1 · Understand the real ask (research — do not skip)

Most junior output comes from solving the *stated* task instead of the *intended* one. Spawn
`anvil:researcher` (it invokes `spec-driven`) to produce the intent as a **numbered list of
one-liner specs** — testable statements of the *what*, covering the happy path and every
error/edge/auth path — plus the named surface (packages/files/RPCs/tables/protos), the invariants
that must not break, and any BLOCKING open question. Input modes: free text (the description IS the
brief — you author the specs; highest risk), a Jira key (read via Atlassian MCP), a GitHub issue
(read via `gh`). If a genuinely blocking question can't be resolved from code/docs/tickets, ask the
user now (`AskUserQuestion`) before going further. **Capture the Jira id** from the task
description (a bare key like `PRI-1212`, or phrasing like "jira story id is PRI-1212") — it
prefixes the branch and PR per `go-git`; if none was given, use `PRI-1-1`. If `--ticket` was
passed, file a Jira ticket from the intent via the `atlassian:jira` skill and use its key instead.

## 2 · Specify & approve — the single human gate

Following the `spec-driven` skill, turn the researcher's spec list into **failing skeleton tests**:
one test per spec (unit table stub or a godog `.feature` scenario for user-visible behavior),
named for its `SPEC-N`, that fails on purpose — do **not** implement them. Run them and confirm the
suite is **red for the right reason** (unimplemented, not broken). Then present the **one-liner
spec list** to the human with `AskUserQuestion` and get approval — **this is the only approval
anvil asks for.** Show only the numbered specs and any blocking question, not the plan or the
skeleton source. On approve, the skeletons are the frozen contract; on change, edit the list +
skeletons and re-present. Do not implement against unapproved specs.

## 3 · Plan the idiomatic design

Decide *how*, judged against ANVIL.md's craft bar (small composable functions, small consumer-side
interfaces, guard clauses over nesting, no premature abstraction, no mutable globals, performance
on hot paths). Write the plan: files/types/interfaces (≤~5 methods, declared where consumed) and
dependency direction; performance risks and how you avoid them; for an API surface, the contract
(OpenAPI / the `grpc-protos` proto), auth/permission, and error/status mapping (`go-api`); the
metrics and error-only logs the feature needs (`go-observability`); and **the resources it will
need provisioned in infra** (step 8). Reject the over-engineered option. For a non-trivial design,
spawn a `Plan` agent to check: is this the simplest correct design that fits the codebase?

## 4 · Implement to green (fill the skeletons)

Make the approved skeleton tests real and pass them — write each failing test's assertions first
(TDD: it must fail for the right reason before you write the code), then the smallest idiomatic
code that passes. Guard clauses, small single-purpose functions, small interfaces, errors wrapped
with `%w`, `context.Context` first and never stored, error-only structured logging with `ctx`,
injected clocks. For an API surface, validate at the boundary, enforce Auth0 + the right
permission, return honest status/gRPC codes (`go-api`). Instrument every path with a Datadog metric
(`go-observability`). Before baking in a non-trivial or hard-to-reverse decision — a
concurrency/ordering invariant, a migration, a public API/proto or event-schema change — apply
`doubt-driven`: spawn a fresh-context skeptic to try to disprove it while the fix is still one
edit. The PostToolUse hook auto-formats your Go. Commit in small, focused steps per `go-git`
(atomic, why-not-what messages, the Co-Authored-By trailer).

## 5 · Gate (the hard Definition of Done)

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" quick` (prefix `ANVIL_SOLO=1` if `--solo`). Fix
every failure — loop `4 ↔ 5` until GREEN. Then run `... gate.sh full` for any I/O, store,
migration, or RPC change (boots the integration suite) and get it green too. A red strict-lint
finding means your new code is too complex/nested/global — refactor, don't suppress. When a failure
isn't obvious — a `-race` report, a flaky test, a regression, staging behavior that doesn't match —
stop guessing and invoke the `go-debugging` skill: reproduce, find the cause, guard it with a
failing test. Never clear the red by weakening a test or `//nolint`.

## 6 · Prove the tests are real & complete

Spawn `anvil:test-engineer`. It audits that every approved spec is covered across all applicable
kinds — **unit, BDD, integration, and end-to-end** — that each test hits real dependencies and
asserts observable behavior over the whole flow (not a mock in a tautology), and it **writes any
missing real test** (including error paths). **Loop `6 → 4 → 5 → 6`:** if it returns `GAPS_FOUND`
with red tests, fix the product code (step 4), re-gate (step 5), and re-run the test-engineer;
repeat until it returns `TESTS_COMPLETE`. If it only added green coverage, re-gate and continue.

## 7 · Adversarial review (parallel, then fix, then re-gate)

Spawn reviewers **concurrently**, scoped to your diff (`git diff <default-branch>...HEAD`):

- `anvil:reviewer` — five-axis craft review (correctness, craft/architecture, security,
  performance) + smell hunt + structural remedies.
- If installed: `pr-review-toolkit:silent-failure-hunter` (swallowed errors),
  `pr-review-toolkit:pr-test-analyzer` (coverage **and** test realism),
  `pr-review-toolkit:type-design-analyzer` (interface/abstraction quality).

Treat findings adversarially: real vs. noise. **Loop `7 → 4 → 5 → 6 → 7`:** fix every
critical/major finding (step 4), re-gate (5), re-run the test-engineer (6) so fixes didn't shift
coverage, and re-review; repeat until `anvil:reviewer` returns `APPROVE` and the others only
justifiable nits. Do not exit early because the build is green.

## 8 · Provision resources in infra

Invoke `flink-infra`. Anything the change needs at runtime that isn't code — config values,
secrets, a new topic/bucket/DB, service exposure/gateway, Datadog monitors — is declared in the
service's infra repo `goflink/<service>-infra` (e.g. `pricing2` → `goflink/pricing2-infra`), which
layers the shared `goflink/helm-service-charts` charts: `cloudresources` for GCP resources and
`workload` for the deployment/gateway. When you need a specific attribute, read only that chart's
`docs/EXAMPLES.md`, `docs/VALUES.md`, or `schemas/` — never the whole repo. Secrets follow
Teller-local / GCP-Secret-Manager-in-cluster; public exposure goes through Envoy Gateway + Auth0
(`iac-auth0` for permissions/roles) fronted by Cloudflare (`iac-cloudflare` for DNS/A-records) — all
per `flink-infra`. If the change emits analytics events, `go-analytics` covers the Pub/Sub topic +
mandatory BigQuery subscription + dead-letter here too. The change is not shippable until its
resources are provisioned: open the infra PR (or confirm the resource exists) **before** staging
verification, since the staging deploy reads from it. If the change needs nothing new, say so.

## 9 · Open the PR

Push the Jira-prefixed branch. `gh pr create` per `go-git` — the **title starts with the Jira id**:
`<JIRA>: <summary>` (e.g. `PRI-1212: add per-tenant rate limiter`), or `PRI-1-1: <summary>` when no
ticket was given (never invent a real-looking number). Body: **what & why** (from step 1), the
**approved specs as a checklist**, **test evidence** (paste the green `gate.sh full` summary + the
test-engineer coverage matrix), any **infra PR link**, **risk/rollback**, and a **changelog entry /
ADR link** where the change warrants it (`go-docs`). `--draft` if the flag was passed; fill the
repo's PR template if any.

## 10 · Verify on staging (unless `--no-staging`)

A green gate proves the code; staging proves the system; the verifier also proves the *process* was
honest. After the change deploys to staging (and its infra has landed), spawn `anvil:verifier` — it
does both the runtime check **and** enforcement: it audits that every approved `SPEC-N` was
implemented and passes on the running service, that every required skill left its fingerprint
(`go-craft`/`go-testing`/`go-api`/`go-observability`/`spec-driven`/infra), and that the researcher,
test-engineer, and reviewer didn't overstate their work. Use
`${CLAUDE_PLUGIN_ROOT}/scripts/verify-staging.sh` to port-forward the real service and run a real
request against it (it exports `$ANVIL_PORT`):

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-staging.sh" --service <name> --remote-port <port> \
  [--cluster <c> --project <p> --region <r>] -- <grpcurl|curl … localhost:$ANVIL_PORT …>
```

Poll the deploy first (`gh run list`/`gh run view`; treat IN_PROGRESS/QUEUED as non-terminal).
Assert **each approved spec** against the running service, and **re-run the critical assertion** —
once-green-once-red is a FAIL. **Loop back on `FAILED`:** if the verifier finds a real defect
(wrong response, a spec unmet, a flaky assertion), return to step 4, fix it, re-gate (5), re-test
(6), re-review (7), let it redeploy, and re-verify — until `VERIFIED`. A staging gap that is *not*
a code defect (no deploy yet, missing access, seed not run) is not a loop: report it as a gap and
stop. Report exactly what you asserted and the actual responses; never claim verified work you
didn't observe.

## 11 · Learn (self-improve, across repos)

If you hit a repo trap, a pattern that worked, or a durable convention, append a lesson:

- **Cross-cutting** (any Go repo) → `${CLAUDE_PLUGIN_ROOT}/lessons/global.md` (follow
  `${CLAUDE_PLUGIN_ROOT}/lessons/CODEC.md`). Commit it to the anvil repo so it travels.
- **Repo-specific** → `~/.claude/anvil/lessons/<repo>.md` (created on demand; never touches the
  target repo).

## Close out

End with: the PR link (and any infra PR); each approved spec marked ✅/⚠️ with how it was verified
(unit / BDD / integration / staging); the final `gate.sh full` result; and anything that genuinely
needs the human (a real ambiguity, a risky migration, the PR approval). Be honest about gaps — a
truthful "staging not verified because X" beats a confident false "verified."
