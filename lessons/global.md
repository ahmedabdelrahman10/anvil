<!-- next-id: A004 -->
# anvil global lessons

Cross-cutting lessons true of any Go repo, compounding across every /anvil:ship run. Format:
`lessons/CODEC.md`. Seeded from building anvil itself.

## Testing
[2026-07-06] #A001 [testing] MISS: a green unit suite hides broken systems when tests mock the very dependency under test — "integration" must boot a REAL dependency (testcontainers) and assert what the service actually returns, or it proves nothing. anvil's theater guard + reviewer exist because this is the #1 way agents fake "done".

## Build & tooling
[2026-07-06] #A002 [build] WIN: enforce the complexity budget DIFF-SCOPED (`golangci-lint --new-from-merge-base=<default-branch>`) so strict linters (gocognit/gocyclo/nestif/funlen/gochecknoglobals) judge only NEW code — legacy debt never blocks, so the floor can be strict without a mass-refactor. This is the lever that makes agent Go stop reading junior.

## Process & review
[2026-07-06] #A003 [process] WIN: guidance the model can ignore under pressure (skills, docs) loses; a machine gate + a Stop hook that won't let it stop while red is what actually changes output. Make quality mechanical, not advisory. macOS ships bash 3.2 and has no `timeout` — hook/gate scripts must avoid both.

## Structure & interfaces

## Errors

## Concurrency

## Performance

## gRPC & DB

## Retired / corrected beliefs
