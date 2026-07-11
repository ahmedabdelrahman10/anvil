---
name: design
description: Run Anvil's system-design workflow for a Flink analytics, big-data, event-driven, or GCP-backed platform component. Use when the user invokes "@anvil:design" in the Codex desktop app, "$anvil:design" in Codex CLI or IDE, asks to design a Flink system, provides a design idea, Jira key, or GitHub issue, or wants a researched architecture reviewed before implementation.
argument-hint: "<free-text problem | idea | JIRA-KEY | GitHub issue> [--ship]"
allowed-tools: Read, Write, Glob, Grep, Bash, Task, AskUserQuestion, Skill
user-invocable: true
context: inject
category: workflow
metadata:
  mcpmarket-version: 1.0.0
---

# Anvil design

This skill is the user-invoked entry point for Anvil's system-design workflow.
Invoke it as `@anvil:design` in the Codex desktop app or `$anvil:design` in Codex CLI/IDE.
The legacy Claude Code command remains `commands/design.md`.

## Source of truth

Before running the workflow, read the legacy command file at:

```text
../../commands/design.md
```

Use that file as the authoritative procedure. Treat the invocation arguments as `$ARGUMENTS` from
the command file.

If the command file cannot be read, stop and report that the plugin installation is incomplete
instead of approximating the workflow.

## Execution contract

Run a system-design pass for a Flink data or analytics platform component. Produce a researched,
requirements-approved, Flink-native architecture that has passed adversarial architecture review.
Do not write product code.

Follow the same stages as `commands/design.md`:

1. Frame the input as free text, Jira key, or GitHub issue.
2. Spawn `anvil:designer` for context-engineering research.
3. Run the requirements approval loop with the human in the main context.
4. Freeze approved requirements into `~/.claude/anvil/design/<repo>-<slug>.design.md`.
5. Spawn `anvil:architect` to write the Flink-native architecture.
6. Spawn `anvil:arch-reviewer` to review the architecture.
7. Loop architecture and review until the reviewer returns `GOOD`, or stop if progress stalls or a requirement must be reopened.
8. Present the decision summary, final verdict, residual risks, infra to provision, and design-doc path.

When the invocation includes `--ship`, hand the approved requirements and reviewed architecture to
`@anvil:ship` only after confirming with the human.
