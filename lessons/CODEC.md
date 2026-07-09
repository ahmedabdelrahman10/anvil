# anvil lessons codec

The format for anvil's compounding memory. Self-contained: any model can read this and
correctly parse, add, and retire lessons with no other context. Compact but human-readable —
density comes from structure + brevity, never from invented notation.

## Two stores
- **`lessons/global.md`** (this repo) — cross-cutting lessons true of any Go repo. Versioned
  by git; travels with the plugin. IDs `#Annn`.
- **`~/.claude/anvil/lessons/<repo>.md`** (local, per repo) — facts specific to one codebase
  (its build quirks, domain data, traps). Never committed to the target repo. IDs `#Rnnn`.

## Entry grammar — exactly one line per lesson
```
[YYYY-MM-DD] #ID [topic] TYPE: one-sentence lesson — why it matters. [FLAGS]
```
- `#ID` — monotonic, never reused. Next free id is in the `<!-- next-id: … -->` comment at the
  top of each store; allocate from it, then bump.
- `[topic]` — one of: `[structure] [interfaces] [errors] [concurrency] [testing] [performance]`
  `[grpc] [db] [build] [git] [process] [review] [general]`.
- `TYPE` — `WIN:` (worked, repeat it) · `MISS:` (trap/cost, do X instead) · `NOTE:` (neutral fact).
- `FLAGS` — `[SUPERSEDES #ID]`, `[STALE → #ID]`, `[UNCONFIRMED]`.

## Operations
- **APPEND** — add the line under its topic section; bump the store's `next-id`.
- **RETIRE** (a new lesson contradicts an old one — normal, we grow): append the new lesson with
  `[SUPERSEDES #old]`; move the old line into "Retired" with `[STALE → #new]`. Never edit a
  lesson's text in place; never reuse an id. The old belief stays as an audit trail.
- **LOAD** — to act on live lessons only, ignore retired lines (`grep -v 'STALE →'`).

## Section order (both stores)
`## Structure & interfaces` · `## Errors` · `## Concurrency` · `## Testing` · `## Performance` ·
`## gRPC & DB` · `## Build & tooling` · `## Process & review` · `## Retired / corrected beliefs`
