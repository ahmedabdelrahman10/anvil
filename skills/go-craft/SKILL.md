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

## When to use

- Writing or reviewing any Go in an anvil task.
- Deciding how to structure a package, shape an interface, name a thing, handle an error, or
  flatten control flow.
- Judging whether an abstraction earns its complexity (the linter passed but it still smells).

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
- **Method order is documentation.** When a consumer interface bundles many methods, order them to
  match the orchestrator's execution sequence, so a reader scanning the caller and the interface
  sees the same shape twice. Reorder the interface in the same commit the caller reorders — not
  alphabetically, not newest-at-bottom.

## Control flow — flat, small, one thing per function

- **Guard clauses and early return**, not a staircase of nested `if/else`. Handle the error/
  edge case and `return`; keep the happy path at the left margin.
- A `for` inside a `for` inside an `if` is a smell — extract the inner loop as a named function.
- Each function does one thing; the step-down rule orders a file top-to-bottom like a
  narrative (entry point first, helpers below). If a function needs a comment to explain its
  sections, it's several functions.

## Comments — the code is the comment

**Default to none.** Clear names, small functions, and flat control flow are how you explain
code — not prose beside it. anvil's floor is *minimal comments*; a diff that reads as
self-explanatory Go is the goal, not one narrated line by line.

- **Never restate the code.** `// increment i`, `// loop over rules`, `// return the result`
  add nothing — delete them. If a line needs a comment to say *what* it does, rename or extract
  until it doesn't.
- **No structural narration.** No `// --- validation ---` / `// Step 1:` section banners
  (that's the "several functions" smell), no header-block comments, no `// end of function`.
- **No commented-out code** (git has the history) and **no `// TODO`** for something you should
  just do now.
- **Comment only a non-obvious *why* the code cannot carry** — a subtle invariant, a deliberate
  workaround and the reason for it, a footgun a maintainer will otherwise re-introduce, an
  ordering/concurrency assumption the compiler can't express. Put the *why*; never the *what*.
- **Exported doc comments: only where they earn it.** Idiomatic Go and some host linters (revive
  `exported`, `golint`) want a name-leading doc comment on exported identifiers — write those,
  terse, **when the host lint requires it or the contract isn't obvious from the signature**. A
  doc comment that just re-says the signature (`// GetUser gets a user.`) is noise; drop it.
  Missing doc comments are not a defect anvil flags — redundant ones are.
- **Schema docs are the exception, and they're not code narration.** Proto / OpenAPI /
  analytics-event field descriptions are the API's own contract (they become the column/field
  docs consumers read) — keep those accurate (see `go-docs`, `go-api`, `go-analytics`).

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
- **Filter before you build.** In a loop that constructs a domain object then discards it, put the
  cheapest discriminating predicate *before* the constructor — don't build (and serialize) a heavy
  object for rows a prefix/flag check will throw away. It also keeps "seen X" counts honest.
- Measure before tuning (`go test -bench -benchmem`, `benchstat`); don't guess.

## Shared Flink modules (`goflink/go`) — reuse, don't hand-roll

Before hand-rolling an HTTP client, JWT validation, a DB client, a Pub/Sub client, or a service
bootstrap, reach for the shared `goflink/go` modules — they carry Flink's logging/tracing/health/
retry/auth conventions, so a bespoke version is a near-duplicate that drifts. It's a multi-module
repo (each has its own `go.mod`): `go get github.com/goflink/go/<module>@latest`.

| Need | Module | Use |
|---|---|---|
| Outbound HTTP + retry | `github.com/goflink/go/http` | `NewRetryableClient(opts…)` (wraps `hashicorp/go-retryablehttp`; `RetryMax`/wait/policy options) + JSON encoders, health |
| Auth / Auth0 JWT | `github.com/goflink/go/auth`, `.../auth/auth0` | Auth0 validation middleware + `claims` extraction; `auth/locker` for locking — don't hand-roll JWT parsing |
| Database (Postgres) | `github.com/goflink/go/db`, `.../db/postgres` | Postgres client + config |
| Pub/Sub | `github.com/goflink/go/pubsub` | `NewClient(ctx, cfg)` + `Publisher` — publish analytics/domain events (see `go-analytics`) |
| Service bootstrap | `github.com/goflink/go/container` | runs the app with logger/tracer/profiler/health + wired deps; implement its `App` interface (`Name`/`Run`/`Close`) |
| Test / BDD helpers | `github.com/goflink/go/test`, `.../test/cucumber` | shared godog/cucumber steps + conversion helpers (see `go-testing`) |

Prefer these over a third-party or bespoke equivalent unless the repo already standardized on
something else; if you must deviate, say why. Details: `github.com/goflink/go` (README + per-module READMEs).

## Common rationalizations

| Rationalization | Reality |
|---|---|
| "I'll add an interface so it's testable" | One impl + a direct test needs no interface. Premature interfaces are layer-cake; add one at the second impl or a real double need. |
| "Return the SDK type, the caller can use it" | A leaked `*sql.Rows`/proto type makes the port useless as an abstraction. Return your domain types. |
| "A format-string log is fine" | It's unqueryable and drops trace context. Use `slog` typed attributes with the `*Context` methods. |
| "I'll just nest another if" | A staircase hides the happy path. Guard-clause the edge and return; keep the main line at the left margin. |
| "One global cache is harmless" | Unguarded package-level mutable state is a race waiting to happen. Guard it or inject it. |
| "While I'm here I'll refactor this too" | A drive-by refactor inside a fix pollutes the diff and the review. Keep the change focused. |
| "A comment will make this clearer" | A comment that explains *what* the code does is a rename or an extraction you skipped. Fix the code; comment only a non-obvious *why*. |

## Red flags (do not ship)

Premature interfaces · implementation-side interface declarations · SDK types leaking through
ports · format-string logging · unguarded global mutable state · `utils`/`common`/`helpers`
packages · fat handlers doing validation+logic+I/O · refactoring drive-bys inside a fix ·
`SELECT *` / N+1 / unparameterized queries · storing a `ctx` in a struct · commenting out a
linter instead of fixing it · comments that restate the code · section-banner/narration
comments · commented-out code · redundant doc comments that echo the signature.

## Verification

- [ ] Dependencies point inward — domain imports no infrastructure; the compiler shows no cycles.
- [ ] Interfaces are small (1–3 methods), consumer-side, and return domain types.
- [ ] Control flow is flat: guard clauses, early return, one thing per function, step-down order.
- [ ] Errors wrapped with `%w` and context, handled once, never ignored; `error` interface returned.
- [ ] `ctx` is the first parameter, never stored; logging is structured with typed attributes.
- [ ] No unguarded global mutable state; every goroutine has a known exit; `-race` clean.
- [ ] Hot paths: bounded input, sensible preallocation, no `SELECT *`/N+1, measured before tuned.
- [ ] Comments are minimal: none that restate code, no narration/banners, no commented-out code; a comment exists only for a non-obvious *why*.
