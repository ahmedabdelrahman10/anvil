---
name: go-testing
description: How anvil expects Go tests to be written — real tests, not theater. TDD (failing test first), table-driven units, real integration via testcontainers, honest BDD, and the assertions that actually catch regressions. Use when writing or reviewing tests in an anvil task, or when deciding what "integration test" and "verify" really mean.
---

# Go testing — real, or it doesn't count

anvil's gate has a test-theater guard and its reviewer hunts fake tests, because a test that
can't fail is worse than no test — it's a green light on broken code. Write the real one.

## TDD — the failing test comes first
For each acceptance criterion, write the test **before** the implementation and run it. It
must **fail for the right reason** — an assertion about behavior, not a compile error or a
`nil` panic. If you can't make it fail before you write the code, it isn't testing anything.

## Unit tests — table-driven, parallel, real assertions
- Table-driven with named cases is the default when cases share a call shape; adding a case is
  then one struct literal. Reach for standalone `t.Run` blocks only when setup genuinely diverges.
- `t.Parallel()` at the top of every test and subtest (except under `t.Setenv`).
- `testify/require` when later lines depend on success (stops the test); `assert` for
  independent checks. **Assert observable behavior**, not tautologies — never `assert.Equal(x, x)`,
  never assert only that "no error" when the point is the returned value.
- Inject clocks/randomness so tests are deterministic; no wall-clock `time.Now()` in assertions.
- Cover the edge and error cases from the acceptance criteria, not just the happy path.

## Integration means integration
"Integration test" means a **real dependency**, not a mock:
- Spin up the real thing with **testcontainers-go** (a real Postgres/Redis/etc. in Docker),
  seed the data under test, and exercise the real code path end-to-end — the loader, the query,
  the RPC. A gate-worthy read-path test seeds rows then asserts what the service returns.
- Gate it behind a build tag (`//go:build integration`) so unit runs stay fast; the anvil gate
  runs it in `full` mode.
- Snapshot/restore the container between cases for speed (migrate once, restore per test).
- A test that mocks the database and then asserts the mock returned what you told it to return
  is theater — it proves nothing about the system. The reviewer will flag it.

## BDD — honest steps
If the repo has a BDD layer (godog/cucumber), it's the behavioral spec: when you change
observable behavior, add or update a scenario in the same change. Reuse existing Given/When/Then
phrasing. Steps must exercise real behavior and assert real outcomes — a step that always passes
is a fake spec. Keep scenarios deterministic (fixed clock).

## Verify against the real thing
Tests prove the code; a run against real dependencies proves the system. For a deployed change,
port-forward the real (staging) service and drive a real request (see
`scripts/verify-staging.sh`), assert each acceptance criterion, and re-run the critical
assertion — once-green-once-red is a FAIL. Report what you actually observed.

## Other tools
`go test -race` always (races corrupt silently). `go test -bench -benchmem` + `benchstat` for
hot paths. `testing/quick` or Go fuzzing for algorithmic edges. `goleak` to catch leaked
goroutines. Coverage is a signal, not a target — 100% of trivial getters proves nothing;
cover the branches that carry risk.
