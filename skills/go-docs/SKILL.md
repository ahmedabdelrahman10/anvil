---
name: go-docs
description: How anvil documents a Go service — the decisions, not the obvious code. ADRs for significant/irreversible choices, godoc comments that explain the why, a README that runs, a changelog for consumers, and proto/OpenAPI as the API's own docs. Use when making an architectural decision, changing a public API/proto, shipping user-facing behavior, or recording context a future engineer or agent will need.
---

# Go docs & ADRs — capture the why

Code shows *what* was built; documentation explains *why it was built this way* and *what was
rejected*. That context is what a future engineer — or the next agent — can't recover from the
diff. Document decisions and gotchas; never restate code.

## When to use

- A significant or hard-to-reverse decision (a dependency, a data model/migration, an auth or
  transport choice, a Pub/Sub vs. sync-RPC call).
- Adding or changing a public API, a gRPC proto, or an analytics event schema.
- Shipping user-facing behavior; onboarding a human or agent to the service.

Not for: obvious code, throwaway spikes, or comments that restate what the code already says.

## ADRs — the highest-value doc you can write

Record the reasoning behind a significant decision as an Architecture Decision Record in the
repo's convention (commonly `docs/adr/` or `docs/decisions/`), sequentially numbered. For a
cross-team or platform decision, Flink's RFC process (Confluence) is the wider forum — link the ADR
to the RFC rather than duplicating it.

```markdown
# ADR-004: Emit order events via Pub/Sub, not a synchronous call to the data service

## Status
Accepted        # Proposed | Accepted | Superseded by ADR-NNN | Deprecated

## Date
2026-07-09

## Context
Analytics needs every order event in BigQuery. A synchronous push couples ordering to the data
path and drops events on downstream downtime; we need durability and a schema contract.

## Decision
Publish to a Pub/Sub topic with an attached schema; a mandatory BigQuery subscription lands it
(see go-analytics). Ordering stays decoupled and events survive consumer outages.

## Alternatives considered
- Direct BigQuery insert — rejected: no schema contract, no history, no dead-letter.
- Synchronous gRPC to the data service — rejected: couples ordering to data uptime.

## Consequences
- Schema lives in data-streaming-platform-events; columns can't be renamed later (plan the shape).
- A dead-letter topic + alert is required for invalid events.
```

Lifecycle: `Proposed → Accepted → (Superseded | Deprecated)`. **Never delete an old ADR** — when a
decision changes, write a new one that supersedes it. The trail ("we used to think X, now Y") is
the value.

## godoc — the why, only where it earns its place

anvil's default is **minimal comments** — clear names and small functions do the explaining (see
`go-craft`). Documentation is for the *why* the code can't carry, written sparingly, not a comment
on every line or every symbol.

- **Doc comments are not mandatory on every exported identifier.** Write a name-leading doc comment
  (`// RuleStore persists authored rules and …`, what `go doc` / pkg.go.dev render) **when the
  contract isn't obvious from the signature, or when the host repo's linter requires it** (revive
  `exported` / `golint`). A doc comment that just re-says the signature (`// GetUser gets a user.`)
  is noise — drop it. A missing doc comment is not a defect anvil flags; a redundant one is.
- Comment **intent and non-obvious constraints**, never the mechanics:
  ```go
  // Rate limiting uses a sliding window reset at the window boundary (not a fixed
  // schedule) so a burst at the edge can't double the allowance. See ADR-006.
  ```
- Document **known gotchas** where they bite (ordering assumptions, "must be called before …",
  concurrency/idempotence invariants the compiler can't express).
- No commented-out code (git has history); no `// TODO` for something you should just do now.
- **Don't document absence.** Negative-space comments ("we don't sync X because…", "no column for
  Y because…") describe a decision that isn't in the code and rot fastest — that context belongs in
  the PR/commit message. Comment what *is* there and why it's shaped that way.
  This reinforces `go-craft`'s clarity rule — a function that needs a comment to explain its
  sections is several functions.

## API docs are part of the contract

- **gRPC:** the proto comments are the docs — keep them accurate in `grpc-protos` (see `go-api`).
- **HTTP:** the OpenAPI spec committed with the code is the doc; keep it in sync with the handlers.
- **Analytics events:** each field is commented in the schema proto (see `go-analytics`).

## README & changelog

- **README** runs the service: one-paragraph what, quick start (`go build ./...`, how to run with
  Teller for secrets — see `flink-infra`), the make/test targets, and a short architecture note
  linking the ADRs.
- **Changelog** for anything with consumers (a module, a proto, a public API): curated, grouped
  `Added/Changed/Fixed/Deprecated/Removed/Security`, newest on top, phrased by user impact — written
  in the same change while the impact is fresh, not reconstructed at release time (see `go-git`).

## Common rationalizations

| Rationalization | Reality |
|---|---|
| "The code is self-documenting" | For the *what*, it should be — that's the goal, so don't narrate it. But code never shows *why*, what was rejected, or what constraint applies; that (only that) is worth a comment or an ADR. |
| "Every exported symbol needs a doc comment" | Only where the contract isn't obvious or the host lint requires it. A doc comment that echoes the signature is noise. |
| "ADRs are overhead" | A 10-minute ADR kills the same 2-hour debate six months later — and stops the next agent re-deciding. |
| "I'll document the API once it's stable" | The doc is the first test of the design; it stabilizes faster when written. |
| "Comments rot" | Comments on *why* are stable; comments on *what* rot — which is why you only write the former. |
| "Nobody reads docs" | Agents do, on every run. So does your three-months-later self. |

## Red flags

- A significant/irreversible decision with no ADR; an old ADR edited or deleted instead of superseded.
- A comment that restates the code, narrates sections, or echoes a signature (the common defect —
  not a missing comment).
- A proto/OpenAPI spec drifted out of sync with the handlers.
- Commented-out code left in; `// TODO` sitting for weeks.
- A consumer-facing release with no changelog entry, or a changelog that's dumped commit messages.

## Verification

- [ ] Significant/irreversible decisions have an ADR (superseded, never deleted); platform ones link the RFC.
- [ ] Comments are minimal and explain *why*, never *what*; none restate code or echo a signature. Exported doc comments exist only where the contract is non-obvious or the host lint requires them.
- [ ] Known gotchas documented where they bite; no commented-out code or stale TODOs.
- [ ] Proto/OpenAPI/event-schema comments match the implementation.
- [ ] README runs the service; consumer-facing changes have a changelog entry.
