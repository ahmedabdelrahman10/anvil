---
name: go-testing
description: How anvil expects Go tests to be written — real tests, not theater. The TDD cycle (failing test first), table-driven units, honest BDD, real integration via testcontainers, and end-to-end assertions against the running service. Use when writing or reviewing tests in an anvil task, or when deciding what "integration", "end-to-end", and "verify" really mean.
---

# Go testing — real, or it doesn't count

anvil's gate has a test-theater guard and its reviewer hunts fake tests, because a test that can't
fail is worse than no test — it's a green light on broken code. Every approved spec is proven by a
real test at the right level, and the whole flow is proven end to end. Write the real one.

## When to use

- Implementing any behavior, fixing any bug, or changing anything with a runtime surface.
- Turning approved specs (`SPEC-N`) into the tests that make the skeleton suite green.
- Reviewing whether a suite actually catches regressions or just passes.

Not for: pure config/doc changes with no behavioral surface.

## The TDD cycle — the failing test comes first

```
   RED                 GREEN                 REFACTOR
write a test  ──▶  smallest code that  ──▶  clean up with
that FAILS         makes it pass            tests still green   ──▶ (repeat)
```

For each spec, write the test **before** the implementation and run it. It must **fail for the
right reason** — an assertion about behavior, not a compile error or a `nil` panic. If you can't
make it fail before you write the code, it isn't testing anything. A test that passes on the first
run proves nothing.

**Bug fixes — the prove-it pattern:** never start by fixing. Write a test that reproduces the bug
and watch it fail (that confirms the bug), then fix, then watch it pass. The regression test that
fails without the fix is the deliverable, not an afterthought.

## The test pyramid — most tests small, few large

```
        ╱╲   end-to-end (~5%) — the running service over its real transport
       ╱──╲  integration (~15%) — real dependency (testcontainers), whole code path
      ╱────╲ unit (~80%) — pure logic, table-driven, milliseconds
```

Test at the lowest level that captures the behavior; don't write an E2E test for what a unit test
covers. But every I/O/API change **also** needs its integration and end-to-end levels — a happy-path
unit test alone is not coverage. Pick the level by the question:

```
pure logic, no I/O            → unit
crosses a boundary (DB/RPC/fs) → integration (real dep)
a spec a caller depends on     → end-to-end against the running service
```

## Unit tests — table-driven, parallel, real assertions

- Table-driven with named cases is the default when cases share a call shape; adding a case is then
  one struct literal. Reach for standalone `t.Run` blocks only when setup genuinely diverges.
- `t.Parallel()` at the top of every test and subtest (except under `t.Setenv`).
- `testify/require` when later lines depend on success (stops the test); `assert` for independent
  checks. **Assert observable behavior**, not tautologies — never `assert.Equal(x, x)`, never
  assert only "no error" when the point is the returned value.
- **Test state, not interactions.** Assert the outcome (returned value, persisted row), not which
  internal method was called — interaction tests break on refactor even when behavior is unchanged.
- Inject clocks/randomness so tests are deterministic; no wall-clock `time.Now()` in assertions.
- Cover the edge and error cases from the specs, not just the happy path.
- **DAMP over DRY:** a test should read like a specification top to bottom. Some duplication is fine
  when it makes each case independently readable; don't hide the inputs behind shared helpers.

## Integration means integration

"Integration test" means a **real dependency**, not a mock:

- Spin up the real thing with **testcontainers-go** (a real Postgres/Redis/etc. in Docker), seed
  the data under test, and exercise the real code path end-to-end — the loader, the query, the RPC.
  A gate-worthy read-path test seeds rows then asserts what the service returns.
- Gate it behind a build tag (`//go:build integration`) so unit runs stay fast; the anvil gate runs
  it in `full` mode.
- Snapshot/restore the container between cases for speed (migrate once, restore per test).
- A test that mocks the database and then asserts the mock returned what you told it to return is
  theater — it proves nothing about the system. The reviewer will flag it.

**Prefer real over mocks**, in this order: real implementation > fake (in-memory) > stub > mock.
Mock only at a boundary that's slow, non-deterministic, or has side effects you can't control
(a third-party API). Over-mocking produces tests that pass while production breaks.

## End-to-end — the whole flow, over the wire

For any user-visible spec, drive the **running service** over its real transport and assert what a
real caller sees — status code **and** body for HTTP, the response message for gRPC, the persisted
effect for a write. This is the assertion the `anvil:verifier` re-runs against staging. Keep E2E to
the critical paths; each one must exercise request → handler → store → response, not a stubbed hop.

## BDD — honest steps

If the repo has a BDD layer (godog/cucumber), it's the behavioral spec: when you change observable
behavior, add or update a scenario in the same change. Reuse existing Given/When/Then phrasing.
Steps must exercise real behavior and assert real outcomes — a step that always passes is a fake
spec. Keep scenarios deterministic (fixed clock). A user-visible spec should have a scenario.

## Verify against the real thing

Tests prove the code; a run against real dependencies proves the system. For a deployed change,
port-forward the real (staging) service and drive a real request (see `scripts/verify-staging.sh`),
assert each spec, and re-run the critical assertion — once-green-once-red is a FAIL. Report what you
actually observed.

## Other tools

`go test -race` always (races corrupt silently). `go test -bench -benchmem` + `benchstat` for hot
paths. `testing/quick` or Go fuzzing for algorithmic edges and to shrink a failing input. `goleak`
to catch leaked goroutines. Coverage is a signal, not a target — 100% of trivial getters proves
nothing; cover the branches that carry risk.

## Common rationalizations

| Rationalization | Reality |
|---|---|
| "I'll write tests after the code works" | You won't — and after-the-fact tests test the implementation, not the behavior. RED first. |
| "It's too simple to test" | Simple code grows complicated. The test documents the behavior you're promising. |
| "I tested it manually" | Manual testing doesn't persist. Tomorrow's change breaks it with no signal. |
| "Mock the DB, it's faster" | A mocked-DB test that asserts the mock is theater. Use testcontainers; catch the real bug. |
| "The happy path passes, ship it" | Every error/edge path in the specs is a coverage obligation. Untested error paths are where prod breaks. |
| "Re-run the suite to be sure" | After a clean run with no code change, re-running adds nothing. Run again after edits, not for reassurance. |

## Red flags

- Code (or a bug fix) with no corresponding test; a bug fix with no reproduction test that failed first.
- A test that passes on its first run (it may not test what you think).
- "Integration" test that mocks the dependency under test; E2E that stubs a hop.
- Asserting internal calls instead of observable outcomes; `assert.Equal(x, x)`.
- A user-visible spec with no BDD scenario / no end-to-end assertion.
- Skipping or weakening a test to make the suite pass.

## Verification

- [ ] Every approved spec has a real test at the right level; error/edge paths covered.
- [ ] Tests failed first (RED), then passed — none passed on the first run without a reason.
- [ ] Integration tests hit a real dependency (testcontainers); E2E drives the running service over the wire.
- [ ] Deterministic: `t.Parallel()`, injected clock/randomness, `-race` clean.
- [ ] Bug fixes include a reproduction test that failed before the fix.
- [ ] No test was skipped or disabled to go green.
