---
name: architecture
description: The design pass anvil runs AFTER the spec list is approved and BEFORE implementation — pick the simplest correct structure for the approved specs and emit a compact, enforceable design the implementer builds from. Go-focused. Covers principles (SOLID, DRY/KISS/YAGNI, SoC, DIP), architecture patterns (clean, hexagonal, layered, DDD, CQRS/event-sourcing, microservices), the GoF design patterns done the Go way, distributed-systems patterns, and decision records (ADRs, trade-offs). Invoked by the anvil:architect agent; also usable standalone for a refactor or an architecture decision.
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: true
context: inject
category: skill
metadata:
  mcpmarket-version: 1.0.0
---

# Architecture — the design pass (Go)

This skill is anvil's **design stage**. It runs at exactly one point in the loop: **after the human
approves the spec list, before any implementation.** The approved specs pin the *what*; this skill
pins the *how* — the smallest, most idiomatic Go structure that satisfies those specs and breaks
none of the researcher's invariants — and writes it down as a compact artifact the implementer fills
in. The design is chosen once, cheaply, before code exists, so a wrong structural call is one edit
here instead of a rewrite later.

All examples are **Go**, held to anvil's `go-craft` standard. The patterns below are a **toolbox,
not a checklist** — the anvil floor is the *simplest correct* design (YAGNI). Reach for a pattern
only when the specs and invariants make its absence the more complex option. A design that applies
five patterns to a CRUD handler fails this skill.

## When to use

- **In `/anvil:ship`:** the `anvil:architect` agent invokes this right after step 2 (spec approval)
  to produce `design.md`, which becomes the implementer's blueprint. This is the primary path.
- **Standalone:** refactoring a legacy Go package, making a specific architecture decision (writing
  an ADR), or a design review. Same rubric, no ship loop.

Do **not** use it to re-open the *what* — the specs are frozen. This stage decides structure only.

## How to run the design pass

1. **Read the inputs, not the world.** Take the approved specs, the researcher's named surface
   (packages/files/RPCs/tables/protos), and the invariants. Read only the code the design touches.
2. **Name the forces.** What must this design optimize for — testability, a swappable dependency, a
   hot path, a compatibility boundary, a concurrency invariant? Forces pick the pattern; taste does
   not.
3. **Pick the structure.** Choose the boundary style (usually ports & adapters / hexagonal or a thin
   layered split for a small service), the domain shape (entities/value-objects vs. plain structs),
   and any GoF pattern the forces justify — each done the Go way (see the references). Prefer
   composition and small interfaces over inheritance-shaped designs.
4. **State what you rejected.** Name the more-abstracted option you did *not* take and why. An
   unstated rejection is how over-engineering sneaks in.
5. **Make the boundaries enforceable.** Express the dependency rules as something a machine can
   check (see *Deterministic architecture fitness*), not just prose.
6. **Emit the artifact** (below). Return only its path + a short summary to the orchestrator — never
   the material you read. Keeping the main context clean is the point of running this in a subagent.

## The design artifact (`design.md`)

Write a single compact file the implementer can build from without re-deriving anything:

- **Design intent** — one or two lines: the chosen structure and the single force that drove it.
- **Chosen patterns** — each pattern used, one line of rationale, and the anvil-Go form (e.g.
  "ports & adapters: `PricingStore` is a 3-method interface declared in `pricing`, a `pgx` adapter
  in `pricingpg`").
- **Ports / interfaces** — each interface, its ≤~5 methods, and the package it's **declared in**
  (consumer side) vs. implemented in. Accept interfaces, return concrete structs.
- **Package layout & dependency direction** — the packages to add/change and which way imports flow
  (domain depends on nothing; adapters depend on domain, never the reverse).
- **Boundary rules** — the import constraints to enforce (e.g. "nothing under `internal/domain` may
  import `internal/adapter/*`"; "external SDKs only in `internal/adapter/*`"), written so they map to
  a `depguard`/`go-arch-lint` rule.
- **Data & compatibility** — schema/migration shape (expand-contract), proto/API changes and their
  compatibility story, any concurrency/ordering invariant.
- **Perf risks** — hot paths and how the design avoids N+1 / needless allocation / unbounded work.
- **ADR** — if the change is significant or hard to reverse, an ADR stub (context → decision →
  consequences) per `decision-making/architecture-decision-records.md`; hand off to `go-docs` to
  land it.
- **Open risks** — anything the design leaves genuinely uncertain for the implementer to watch.

Each design decision should trace to a spec or an invariant. If it traces to neither, cut it.

## Deterministic architecture fitness

Prose boundaries drift; a check does not. Whatever dependency rules the design declares, express
them as an **enforceable** rule so the gate — not a reviewer's memory — catches a violation:

- `depguard` (bundled in `golangci-lint`) — deny imports across the boundaries you drew (e.g. domain
  packages may not import adapter packages or third-party SDKs).
- `go-arch-lint` — declare components and allowed dependencies in a YAML and fail on any edge you
  didn't allow.
- Package-boundary tests — a small `_test.go` that asserts `go list -deps` contains no forbidden edge.

The architect writes these rules into `design.md`; landing them in the host repo's golangci config
(or an `.go-arch-lint.yml`) turns the architecture into part of anvil's Definition of Done. Feed the
*why* into the rule's message ("domain must stay framework-free — move this to an adapter") so the
failure teaches, not just blocks.

## The reference library

Read only the file you need for the decision at hand — **never the whole tree**. Default to the
`references/` one-pagers below; open a deep `patterns/` / `design-patterns/` / `distributed-systems/`
/ `decision-making/` file **only** when you're actually applying that specific pattern. The deep
tree is ~700 KB across 35 files — reading it wholesale is the biggest avoidable token cost in the
loop.

### `principles/` — the design principles that decide structure
- `solid.md` · `dry-kiss-yagni.md` · `separation-of-concerns.md` · `dependency-inversion.md`

### `patterns/` — application-level architecture patterns
- `clean-architecture.md` · `hexagonal-architecture.md` · `layered-architecture.md`
- `domain-driven-design.md` · `cqrs-event-sourcing.md` · `microservices.md`

### `design-patterns/` — the GoF patterns, done the Go way
- Creational: `factory.md` · `builder.md` (→ functional options) · `singleton.md` (→ `sync.Once`,
  and why it's usually a smell) · `dependency-injection.md` (constructor injection / wire)
- Structural: `adapter.md` · `decorator.md` · `facade.md` · `repository.md`
- Behavioral: `command.md` · `observer.md` · `strategy.md` · `state-machine.md`

### `distributed-systems/` — patterns for a service among services
- `service-communication.md` · `data-consistency.md` · `resilience-patterns.md` · `event-driven.md`

### `decision-making/` — how to record and defend a decision
- `architecture-decision-records.md` · `trade-offs.md` · `documentation.md`

### `references/` — one-page cheat-sheets
- `principles.md` · `patterns.md` · `design-patterns.md` · `distributed.md` · `decision-making.md`

## Hand-offs

This stage sits between `spec-driven` (upstream: the approved specs it designs against) and the
implementer (downstream: fills `design.md`'s skeleton to green). It leans on `go-craft` for the Go
idioms, `go-api` when the surface is HTTP/gRPC, `flink-infra` when the design needs a runtime
resource, and `go-docs`/`doubt-driven` to land and stress-test a significant decision.
