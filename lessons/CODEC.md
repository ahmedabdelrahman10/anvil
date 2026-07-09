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

## Contributing lessons across a team
The shared store (`lessons/global.md`) travels with the plugin, so teammates already *receive*
lessons on install. To let many people *add* them without stepping on each other — plain git, no
database:

- **Merge is automatic.** `.gitattributes` sets `lessons/*.md merge=union`, so two people appending
  concurrently keep both sides' lines with no conflict. Because the store is strictly
  one-entry-per-line, union merge is safe here (it is *not* safe for prose).
- **Author-tag the id so it can't collide.** With no central lock, two contributors can both grab
  `#A004`. Suffix your initials: `#A004-aa`. Ids stay unique and `[SUPERSEDES]` / `[STALE → ]`
  still resolve. The top `<!-- next-id -->` counter is then advisory (a hint for your own next id,
  not a shared lock); if union merge leaves two counter lines, the curator pass reconciles them.
- **Prefer a PR for the shared store.** Lessons are curated, not a dump — a PR into `global.md`
  keeps quality mechanical, the same as the gate. A shared branch with direct push also works when
  review is overkill; union merge covers both.
- **Keep proprietary facts out of the shared store.** Anything specific to one codebase (its build
  quirks, domain data, internal names) belongs in the local per-repo store
  (`~/.claude/anvil/lessons/<repo>.md`, ids `#Rnnn`), which never leaves your machine. Only
  cross-cutting, non-proprietary lessons (`#Annn`) go in `global.md`.

Do **not** move this store into a database (Dolt/SQL/etc.). The whole store is designed to be read
and extended by any model from the raw markdown with no tooling; a DB dependency trades that
portability for merge machinery git already provides on an append-only file this size.
