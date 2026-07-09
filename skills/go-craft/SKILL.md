---
name: go-craft
description: The craftsmanship standard for Go that anvil holds code to — small composable interfaces, flat control flow, explicit errors, no mutable globals, performance on hot paths. Use when writing or reviewing Go in an anvil-driven task, or whenever you need the idiomatic way to structure, name, abstract, or simplify Go code.
---

# Go craft

The bar comes from the codebases the community treats as masterclasses — wtf, bolt,
groupcache, memberlist, upspin. Their shared taste: **absolute clarity, small powerful
interfaces, explicit errors, and a flat layout — simplicity over architectural
over-engineering.** anvil's linter enforces the measurable parts; this skill is the
judgment the linter can't encode. When rules tension, **clarity wins.**

## Structure — packages as layers, dependencies point inward

- Root/domain holds pure types + the interfaces the business speaks; it imports **no
  infrastructure** (no `pgx`, no proto/JSON tags, no `net/http`). Infra packages
  (`sqlite/`, `http/`, `grpc/`) implement those interfaces and import inward, never the
  reverse. The compiler enforces no cycles; you enforce the direction.
- **One package per concern, named for what it does** — never `utils`, `common`, `helpers`,
  `models`. If you can't name it for a concern, the boundary is wrong.
- `main`/`cmd` is wiring only: build dependencies in order, inject them, serve, handle
  shutdown. Extract an `app.New()` factory when it outgrows ~150 lines, not before.

## Interfaces — small, consumer-side, concrete returns

- **Declare the interface in the package that CONSUMES it**, not beside the implementation.
  The concrete type imports the interface, never the reverse. This keeps the mock surface
  tiny and avoids Java-style layer cake.
- **Small and cohesive** — 1–3 methods is the target; a 4-method interface beats a 20-method
  one everyone depends on. `io.Reader` is the north star.
- **Ports return your own/domain types**, never SDK/infra types (`[]domain.X`, not `*sql.Rows`).
  A leaked SDK type makes the interface mockable but useless as an abstraction.
- **No interface until there's a second implementation or a real test-double need.** One
  concrete impl + tests that hit it directly → no interface yet. Accept interfaces, return structs.

## Control flow — flat, small, one thing per function

- **Guard clauses and early return**, not a staircase of nested `if/else`. Handle the error/
  edge case and `return`; keep the happy path at the left margin.
- A `for` inside a `for` inside an `if` is a smell — extract the inner loop as a named function.
- Each function does one thing; the step-down rule orders a file top-to-bottom like a
  narrative (entry point first, helpers below). If a function needs a comment to explain its
  sections, it's several functions.

## Errors — explicit, wrapped, handled once

- Wrap with `%w` (not `%v`) and add context, so callers can `errors.Is`/`errors.As`:
  `fmt.Errorf("apply rule %s: %w", id, err)`. Put `%w` at the end for a chain; lead with the
  sentinel when wrapping one.
- **No redundant context** — `os` already names the path; write `"load config: %w"`, not
  `"could not open /etc/x: %w"`.
- **Sentinel errors** (`var ErrNotFound = errors.New("…")`) for caller-distinguishable cases,
  matched with `errors.Is`. Handle an error exactly once — don't log-and-return it.
- Never ignore returns (`errcheck` covers type assertions — use `v, ok :=`). Return the
  `error` interface, never a concrete error pointer type (a nil `*T` in an `error` is non-nil).

## Context, logging, config

- `ctx context.Context` is **always the first parameter**; derive timeouts from it; pass it to
  every blocking call. **Never store a ctx in a struct.**
- Prefer stdlib `log/slog` with **typed attributes** and the `*Context` methods
  (`logger.InfoContext(ctx, "msg", slog.String(...))`) so trace/span IDs attach — never a
  format string in a log message. Match the constructor to the type (`slog.Int64` for int64).
  Pick the level by "would I be paged?".
- Config loaded once at construction into a struct; fail fast on missing required values.
  Don't `os.Getenv` deep in business logic. Never commit secrets.

## Concurrency — safe to share by design

- **No unguarded package-level mutable state.** Read-mostly map → `sync.RWMutex`; counter/flag
  → `atomic.*`. Never hold one component's lock while calling into another.
- **Every goroutine has a known exit** before you start it (a `ctx.Done()`, a `WaitGroup`, a
  closed channel). Leave goroutine lifetime to the caller where you can; specify channel
  direction in signatures; the sender closes, never the receiver.
- Always `go test -race ./...`. A race is a correctness bug — fix the code, don't skip the test.

## Performance — part of correctness on hot paths

- Favor stack over heap: value semantics for small short-lived data; avoid pointer-chasing.
- Preallocate slices/maps you can size (`make([]T, 0, n)`); `sync.Pool` for transient buffers
  on proven hot paths. Bound all external input (`io.LimitReader`); copy slices/maps at
  boundaries you don't own.
- Databases: never `SELECT *`; kill N+1 with a JOIN or a batch; parameterize every query.
- Measure before tuning (`go test -bench -benchmem`, `benchstat`); don't guess.

## Anti-patterns (do not ship)
Premature interfaces · implementation-side interface declarations · SDK types leaking through
ports · format-string logging · unguarded global mutable state · `utils`/`common`/`helpers`
packages · fat handlers doing validation+logic+I/O · refactoring drive-bys inside a fix ·
commenting out a linter instead of fixing it.
