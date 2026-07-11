---
name: ship
description: Run Anvil's end-to-end Go shipping workflow. Use when the user invokes "@anvil:ship" in the Codex desktop app, "$anvil:ship" in Codex CLI or IDE, asks Anvil to ship a Go task, provides a Jira key or GitHub issue to implement, or wants a task taken from spec approval through implementation, gate, tests, review, staging verification, and PR.
argument-hint: "<free-text task | JIRA-KEY | GitHub issue> [--solo] [--no-staging] [--draft] [--ticket]"
allowed-tools: Read, Write, Edit, MultiEdit, Glob, Grep, Bash, Task, AskUserQuestion, Skill
user-invocable: true
context: inject
category: workflow
metadata:
  mcpmarket-version: 1.0.0
---

# Anvil ship

This skill is the user-invoked entry point for Anvil's end-to-end Go shipping workflow.
Invoke it as `@anvil:ship` in the Codex desktop app or `$anvil:ship` in Codex CLI/IDE.
The legacy Claude Code command remains `commands/ship.md`.

## Source of truth

Before running the workflow, read the legacy command file at:

```text
../../commands/ship.md
```

Use that file as the authoritative procedure. Treat the invocation arguments as `$ARGUMENTS` from
the command file.

If the command file cannot be read, stop and report that the plugin installation is incomplete
instead of approximating the workflow.

## Execution contract

Run Anvil's full Go delivery loop for the current repository. This workflow takes a task from an
initial ask to a reviewed, staging-verified PR, with at most one human approval on the spec list.

Follow the same stages as `commands/ship.md`:

1. Arm Anvil for the repository and load the required Anvil standard.
2. Research the real ask and produce testable one-line specs.
3. Get explicit human approval on the spec list.
4. Produce the architecture/design artifact through `anvil:architect`.
5. Implement to the approved specs and design.
6. Run Anvil's gate until green.
7. Prove tests are real and complete through `anvil:test-engineer`.
8. Run adversarial review through `anvil:reviewer`.
9. Provision required infra when the change needs runtime resources.
10. Deploy or verify on staging unless explicitly skipped.
11. Run final verification through `anvil:verifier`.
12. Open or prepare the PR according to the invocation flags.

Respect `--solo`, `--no-staging`, `--draft`, and `--ticket` exactly as defined in `commands/ship.md`.
Do not skip the spec approval gate or weaken Anvil's gate to make progress.
