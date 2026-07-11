# AGENTS.md — anvil for any agent (Claude Code, Codex, or other)

anvil is packaged as a **Claude Code plugin**, but its standard and its Definition-of-Done gate are
**tool-agnostic**: plain markdown + portable bash, with no dependency on any one harness. This file
is the entry point for **any** coding agent — Codex, Claude Code running anvil as raw files, or a
human — so the same standard and the same gate apply whichever tool is driving.

If you are **Claude Code with the anvil plugin installed**, use the slash commands
(`/anvil:ship`, `/anvil:design`, `/anvil:review`) and the `Skill` tool — they orchestrate
everything below for you, and `${CLAUDE_PLUGIN_ROOT}` resolves to this repo. If you are **any other
agent**, this file maps those Claude-only affordances to portable equivalents you can run directly.

## The one rule (every tool)

You do **not** decide when a Go change is done — the gate does. It is portable bash and runs in any
shell, from the repo root of the **target** Go repo you are changing:

```sh
bash <path-to-anvil>/scripts/gate.sh quick   # fast: format · strict lint (diff) · host lint · build · vet · -race tests(changed pkgs) · test-theater guard. No Docker.
bash <path-to-anvil>/scripts/gate.sh full    # + host test suite, whole-repo -race, testcontainers integration (Docker)
ANVIL_SOLO=1 bash <path-to-anvil>/scripts/gate.sh quick   # anvil's floor only; ignore the host repo's own lint/test
```

`<path-to-anvil>` is wherever this repo is checked out. Under Claude Code it is
`${CLAUDE_PLUGIN_ROOT}`; under Codex or a manual run, use the repo-relative or absolute path. The
script self-locates its config (`golangci.strict.yml`) from its own directory, so it works from any
CWD as long as you invoke it from inside the target repo. Exit 0 means done; never weaken a test,
delete an assertion, add `//nolint`, or edit the gate to pass — **fix the code.**

## The standard (read as plain docs, any tool)

- **[`ANVIL.md`](ANVIL.md)** — what "done" means, the complexity budget, and the minimal-comments
  floor. Read it first.
- **`skills/*/SKILL.md`** — the craft. Under Claude Code these load via the `Skill` tool; any other
  agent reads them as markdown. Load **only** the ones the surface touches (see below) — don't read
  the whole tree. The always-on set: `go-craft`, `go-testing`, `spec-driven`, `go-git`,
  `go-observability`. Per surface: `go-api` (HTTP/gRPC), `go-analytics` (events→BigQuery),
  `flink-infra` (runtime resources), `architecture` (post-spec design pass), `go-docs`,
  `go-debugging`, `doubt-driven`.
- **`skills/architecture/references/*.md`** — one-page cheat-sheets. Prefer these; open a deep
  `skills/architecture/{patterns,design-patterns,...}/*.md` file **only** when you actually apply
  that pattern (the deep tree is ~700 KB — reading it wholesale is the biggest avoidable token cost).

## Minimal comments (a floor that binds every tool)

anvil writes **minimal comments**. Clear names, small functions, and flat control flow do the
explaining — not prose. No comments that restate the code, no section-banner/narration comments, no
commented-out code, no stale `// TODO`. Write a comment only for a non-obvious *why* the code can't
carry (an invariant, a deliberate workaround, a footgun). Doc comments only where the contract is
non-obvious or the host linter requires them. See `go-craft` → "Comments — the code is the comment".

## Claude-only affordances → portable equivalents

| Claude Code (plugin) | Any other agent (Codex, manual) |
|---|---|
| `/anvil:ship <task>` | Follow the phased loop in [`commands/ship.md`](commands/ship.md) by hand: understand → spec+approve → design → implement → **run `gate.sh`** → test → review → verify. |
| `/anvil:review <target>` | Follow [`commands/review.md`](commands/review.md); the five axes + Go checklist are the rubric. |
| `/anvil:design <problem>` | Follow [`commands/design.md`](commands/design.md). |
| Subagents (`anvil:researcher`, `anvil:reviewer`, …) | Their prompts are `agents/*.md` — read the relevant one and perform that role in your own context, or spawn your tool's equivalent worker. |
| `Skill` tool | Read the corresponding `skills/*/SKILL.md` as a doc. |
| Stop-hook gate (auto-enforced) | Run `gate.sh quick` yourself before declaring done; it is the same check. |
| `${CLAUDE_PLUGIN_ROOT}` | The path to this repo. |

## The one human gate (every tool)

Before writing code, present the change as a numbered list of one-liner specs (the *what*), turn
each into a failing skeleton test, and get the human's single approval on that list. See
`spec-driven`. Everything after that is mechanical and gated by `gate.sh`.

## Contributing to anvil itself (across tools)

This repo is docs + bash + JSON — no build, no dev server. When editing it:

- Keep the scripts **POSIX-friendly bash** and harness-independent (no hard dependency on
  `${CLAUDE_PLUGIN_ROOT}`; self-locate from `BASH_SOURCE`). Test with `bash scripts/gate.sh quick`
  inside a throwaway Go repo.
- Keep every `skills/*/SKILL.md`, `commands/*.md`, and `agents/*.md` readable as **standalone
  markdown** — an instruction that only makes sense inside one tool's UI breaks the other tool.
- Bump `.claude-plugin/plugin.json` `version` on any behavior change so Claude Code refreshes its
  cache; note the change in `README.md`.
