# anvil — intent-driven development for Go

**Set the specifications first. Leave anvil to meet them.**

anvil turns your intent into a short list of observable specifications. You approve that list
once; anvil then designs, implements, and reviews the change in a loop that only exits when a
machine-checkable gate is green and the reviewer approves.

## The loop

```text
/anvil:ship add a per-tenant rate limiter to the gateway middleware
```

Four stages, one human approval:

1. **Research** — a researcher subagent turns the ask (free text, Jira key, or GitHub issue) into
   numbered one-liner specs. You approve the list — the only approval anvil asks for.
2. **Architecture & design** — an architect subagent writes `design.md`: the simplest structure
   that satisfies the specs. It follows the repo's existing layout by default and reaches for
   heavier patterns only when the specs genuinely force them.
3. **Implement** — anvil builds test-first and loops against the gate until green.
4. **Review** — a reviewer subagent adversarially reviews the diff; every critical/major finding
   loops back into implementation and re-review, until `APPROVE`. Then the PR opens.

## The Definition of Done

The gate is portable Bash. Run it from the root of the Go repository you are changing:

```sh
bash /path/to/anvil/scripts/gate.sh quick   # fast, Docker-free inner loop
bash /path/to/anvil/scripts/gate.sh full    # + host test suite, whole-repo -race, integration
```

Green means: formatting clean · new code within the strict complexity budget · the host repo's
own lint and tests pass · build and `go vet` pass · race-enabled tests pass · tests prove behavior
instead of mocks proving themselves. Red means the work continues — the Stop hook won't let an
armed session stop on a red gate.

Run only anvil's floor when the host repository is not ready:

```sh
ANVIL_SOLO=1 bash /path/to/anvil/scripts/gate.sh quick
```

The complete contract and complexity limits live in [`ANVIL.md`](ANVIL.md).

## Install

```sh
claude plugin marketplace add /path/to/anvil
claude plugin install anvil@anvil
```

The marketplace path can also be your GitHub remote. Once installed, start with `/anvil:ship`.

Required on `PATH`: `go`, `git`, and `gh`. Optional: `golangci-lint`, `goimports`, Docker. anvil
installs its pinned linter into `~/.cache/anvil` when needed.

## Options

```text
--solo    use anvil's standard without the host repository's agent instructions
--draft   open the pull request as a draft
```

## Safe by default

Installing anvil globally does not make it take over every repository. `/anvil:ship` arms the
current repository automatically; you can also manage that state yourself:

```sh
scripts/anvil-arm.sh arm
scripts/anvil-arm.sh status
scripts/anvil-arm.sh disarm
```

Use `touch ~/.claude/anvil/always-on` to arm every repository, or `touch ~/.claude/anvil/off` as
the global kill switch. anvil keeps its design artifacts outside the target repository — your
codebase gets the change and its tests, not plugin clutter.

## What is inside?

- [`.claude-plugin/`](.claude-plugin) — plugin and marketplace manifests
- [`commands/ship.md`](commands/ship.md) — the four-stage workflow
- [`agents/`](agents) — the researcher, architect, and reviewer roles
- [`skills/`](skills) — architecture, Go craft, and Go testing standards
- [`hooks/`](hooks) — Go auto-formatting and the Stop gate
- [`scripts/`](scripts) — the portable gate and arming

The plugin is markdown, Bash, and JSON. The standard is visible, reviewable, and portable — and
the gate, not the agent, gets the final word.
