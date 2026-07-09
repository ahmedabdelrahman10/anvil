---
name: go-git
description: How anvil uses git and versions a Go service — Flink's Jira-first branch/PR naming, atomic commits with honest messages, trunk-based short-lived branches, Go pre-commit hygiene, and SemVer/tag/changelog discipline for anything with consumers (a module, a proto, a public API). Use for every change — branching, committing, opening the PR, cutting a release.
---

# Go git & versioning — Jira-first, atomic, reversible

Git is the safety net: commits are save points, branches are sandboxes, history is documentation.
With an agent generating code fast, this discipline is what keeps the work reviewable and
reversible. At Flink every branch and PR is anchored to its Jira story.

## When to use

Every change. Branching, committing, opening the PR, and cutting a release all flow through here.

## Branch & PR naming — start with the Jira number (Flink rule)

**The branch name and the PR title both start with the Jira story id.** The id comes from the
`/anvil:ship` task description — e.g. `/anvil:ship add a rate limiter, jira story id is PRI-1212`
→ `PRI-1212`. A bare key in the text (`PRI-1212`) counts too. **If no ticket is given, use the
default prefix `PRI-1-1`.** Never invent a plausible-looking real ticket number — the default is
literally `PRI-1-1`.

```
branch:     <JIRA>-<kebab-slug>       e.g. PRI-1212-add-rate-limiter   (no ticket → PRI-1-1-add-rate-limiter)
PR title:   <JIRA>: <imperative summary>   e.g. PRI-1212: add per-tenant rate limiter
```

Branch from the default branch, keep it short-lived (merge in 1–3 days), delete after merge.
anvil isolates each run in a git worktree, so parallel agents never fight over the working tree.

## Commits — atomic, honest, one concern each

- **One logical change per commit** (endpoint, then form, then tests — not one "add feature, fix
  sidebar, bump deps" blob). Commit each green slice; a commit is a save point you can revert to.
- **Message = why, not what.** A type prefix + a short imperative subject, then a body explaining
  intent when it isn't obvious:
  ```
  feat: validate rule body at the authoring boundary

  Reject unknown hub_group before it reaches the store so a typo is a 422,
  not a silent no-op. Matches the boundary-validation pattern in go-api.
  ```
  Types: `feat` · `fix` · `refactor` · `test` · `docs` · `chore`.
- **Keep concerns separate** — never mix a formatting/refactor commit with a behavior change; they
  review, revert, and read differently. A refactor and a feature are two commits (ideally two PRs).
- **End every commit message with** `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Stage by explicit path**, never `git add -A`/`.` — keep local config, scratch files, and
  `~/.claude` artifacts out of the commit.
- Size: ~100 lines is easy to review, ~300 acceptable for one logical change, ~1000 → split.

## Pre-commit hygiene (Go)

The anvil gate is the real check — but before you commit, the floor is: `gofmt`/`goimports` clean
(the PostToolUse hook auto-formats), `go build ./...`, `go vet ./...`, `go test -race ./...`, and
`golangci-lint` (the strict diff-scoped budget). No secrets in the diff
(`git diff --staged | grep -iE 'secret|token|api_key|password'`). Don't commit build output,
`.env`, or IDE config; the repo's `.gitignore` should already cover them (anvil adds nothing to the
host repo). For a regression, let `git bisect` find the commit (see `go-debugging`).

## Change summary (surface scope discipline)

When you finish, state what you touched, what you deliberately left alone, and any concern — it
catches wrong assumptions and shows you didn't go on an unsolicited renovation:

```
CHANGED:      internal/authoring/http.go (validation), internal/authoring/rule.go (type)
DIDN'T TOUCH: internal/resolve/* — similar gap, out of scope for PRI-1212
CONCERN:      strict body rejects unknown fields — confirm that's intended
```

## Versioning — for anything with consumers

Commits track *your* change; a **version** is how *consumers* track it. The moment another team, a
published module, a proto, or a deployed client depends on your code, "latest on main" stops
answering "what am I running, is it safe to upgrade?".

- **SemVer** `MAJOR.MINOR.PATCH`: breaking → major, additive-compatible → minor, fix → patch. When
  unsure if a change is breaking, assume it is (Hyrum's Law — see `go-api`). A Go module past v1
  needs the `/vN` suffix in its module path.
- **Protos:** run `buf breaking --against '.git#branch=main'`; reserve removed field numbers, never
  reuse one (see `go-api`/`go-analytics`).
- **Tag the release** (`git tag -a v1.4.0 -m "…"`, push the tag) and derive the version from the
  tag, not hand-edited files, so artifact/tag/changelog can't disagree.
- **Changelog** for consumers: curated, grouped `Added/Changed/Fixed/Deprecated/Removed/Security`,
  written in the same change while the impact is fresh (see `go-docs`).

## Common rationalizations

| Rationalization | Reality |
|---|---|
| "I'll name the branch whatever, rename later" | The Jira prefix links the branch/PR to the story for everyone. Start with it: `<JIRA>-…` (or `PRI-1-1`). |
| "I'll commit when the feature's done" | One giant commit can't be reviewed or reverted. Commit each green slice. |
| "The message doesn't matter" | Messages are the history a future agent reads. Explain the why. |
| "I'll squash it all at the end" | Squashing away the narrative loses the save-point trail. Keep clean incremental commits. |
| "It's a small fix, bump the patch" | Check what consumers can observe. A behavior change they relied on is a major, whatever the diff size. |
| "Changelog is just the commit log" | Commits are for you; the changelog is curated by consumer impact. |

## Red flags

- A branch or PR title that doesn't start with a Jira id (or `PRI-1-1` when none was given).
- An invented real-looking ticket number instead of the `PRI-1-1` default.
- Large uncommitted changes accumulating; commit messages like "fix"/"update"/"wip".
- Formatting/refactor mixed with a behavior change in one commit; `git add -A`.
- Secrets in a diff; committing `.env`/build output.
- A breaking change (or breaking proto) shipped under a minor/patch bump; a release with no tag.

## Verification

- [ ] Branch and PR title start with the Jira id (or `PRI-1-1` when none was provided).
- [ ] Each commit does one logical thing; message explains the why and ends with the Co-Authored-By trailer.
- [ ] Staged by explicit path; no secrets, no build output, no `.env` in the diff.
- [ ] Refactor and behavior changes are separate commits.
- [ ] For a consumer-facing change: version bump matches (breaking→major), release tagged, changelog entry written.
