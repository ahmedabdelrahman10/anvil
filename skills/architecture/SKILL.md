---
name: architecture
description: The design pass anvil runs AFTER the spec list is approved and BEFORE implementation — pick the simplest correct structure for the approved specs and emit a compact design the implementer builds from. Go-focused. Simple by default; patterns only when the forces justify them. Invoked by the anvil:architect agent; also usable standalone for a refactor or an architecture decision.
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: true
context: inject
category: skill
---

# Architecture — the design pass (Go)

This skill is anvil's **architecture & design stage**. It runs at exactly one point in the loop:
after the human approves the spec list, before any implementation. The approved specs pin the
*what*; this skill pins the *how* — the smallest, most idiomatic Go structure that satisfies those
specs — and writes it down as a compact artifact the implementer fills in.

Do **not** use it to re-open the *what* — the specs are frozen. This stage decides structure only.

## Simple by default

The anvil floor is the **simplest correct** design (YAGNI). For most changes that means:

- **Follow the repo's existing layout.** Put code in the package that owns the behavior.
- **Plain structs and functions.** No layers, no indirection the specs didn't ask for.
- **A small interface (≤~5 methods, declared where consumed) only where a dependency genuinely
  needs swapping** — a store behind a test, an external API. Accept interfaces, return structs.

Reach for heavier structure — hexagonal/clean layers, DDD shapes, CQRS, event sourcing — **only
when the specs are genuinely complex enough to force it**: multiple real adapters behind one port,
a compatibility boundary that must not leak, a domain with real invariants. Forces pick the
pattern; taste does not. A design that applies five patterns to a CRUD handler fails this skill.

## How to run the design pass

1. **Read the inputs, not the world.** Take the approved specs, the named surface, and the
   invariants. Read only the code the design touches.
2. **Name the forces.** What must this design optimize for — testability, a swappable dependency,
   a hot path, a compatibility boundary, a concurrency invariant?
3. **Pick the structure** — the simplest one that answers the forces (see above).
4. **State what you rejected.** Name the more-abstracted option you did *not* take and why. An
   unstated rejection is how over-engineering sneaks in.
5. **Emit the artifact** (below). Return only its path + a short summary — never the material you
   read.

## The design artifact (`design.md`)

Write a single compact file the implementer can build from without re-deriving anything:

- **Design intent** — one or two lines: the chosen structure and the single force that drove it.
- **Structure** — the packages to add/change, each interface (methods + the package it's declared
  in), and which way imports flow.
- **Data & compatibility** — schema/migration shape (expand-contract), proto/API changes and
  their compatibility story, any concurrency/ordering invariant.
- **Perf risks** — hot paths and how the design avoids N+1 / needless allocation / unbounded work.
- **What was rejected** — the heavier option and why it wasn't needed.
- **Open risks** — anything genuinely uncertain for the implementer to watch.

Each decision must trace to a spec or an invariant. If it traces to neither, cut it. If the design
draws a real boundary (e.g. "domain packages may not import adapter packages"), express it as a
`depguard` rule in the host repo's golangci config so the gate enforces it.

## The reference library

One-page cheat-sheets in `references/` — read only the one you need for the decision at hand:

- `principles.md` — SOLID, DRY/KISS/YAGNI, separation of concerns, dependency inversion
- `patterns.md` — layered / hexagonal / clean / DDD / CQRS, and when each is actually warranted
- `design-patterns.md` — the GoF patterns done the Go way
- `distributed.md` — service communication, data consistency, resilience, event-driven
- `decision-making.md` — ADRs and trade-off records, for a significant or hard-to-reverse decision
