---
name: spec-driven
description: Intent-driven development — the "what" is pinned and approved before any "how". After research, present the change as a numbered list of one-liner specs, turn each into a FAILING skeleton test (unit or BDD), and get the human's single approval on that list. Use at the start of every anvil:ship run, before planning or implementing. This is the one human gate.
---

# Spec-driven — pin the "what" before the "how"

anvil's loop is autonomous, but there is exactly **one** place the human decides: *are we
building the right thing?* This skill is that gate. It converts research into a short list of
one-liner specifications (the intent), makes each one executable as a failing skeleton test,
and stops for a single approval. Everything after — plan, implement, gate, review, verify — is
mechanical and needs no further sign-off.

The point is to fail fast **before** work, not after: a wrong spec costs one line to fix here
and a whole PR to fix later.

## When to use

- At the start of **every** `anvil:ship` run, right after the researcher returns and **before**
  any planning or code.
- When the ask is ambiguous and you want the human to confirm scope once, cheaply.

Not for: mechanical one-line changes with no behavioral surface (a rename, a comment) — there is
no spec to approve. Say so and proceed.

## Step 1 — Specs are one-liners, not an essay

Each spec is a single testable sentence describing observable behavior — the *what*, never the
*how*. No prose paragraphs, no design, no file names. If a spec needs a comma-spliced "and", it's
two specs.

```
SPEC-1  Creating a rule with a valid body returns 201 and the persisted rule with a server id.
SPEC-2  Creating a rule with an unknown hub_group returns 422 with error code VALIDATION_ERROR.
SPEC-3  GET /rules/{id} for a missing id returns 404, never a 500.
SPEC-4  A superseded rule keeps its id and increments its version; the old version stays readable.
SPEC-5  Reads require read:pricing_rule:all; a token without it gets 403, not 401.
```

Good specs are: observable (asserts an output/state, not an internal call), bounded (one
behavior), and decidable (you can tell pass from fail without reading the code).

## Step 2 — Make each spec a FAILING skeleton test

Turn the list into test skeletons — one test per spec, named for the spec, that **fails on
purpose**. Do NOT implement them; they are the contract the implementer fills in step "implement".

- **Unit / integration (Go):** a test function (or table row) per spec that fails loudly until
  filled — `t.Fatalf("SPEC-2: not implemented")`. Name it after the behavior
  (`TestCreateRule_UnknownHubGroup_Returns422`) so the name carries the intent; don't leave
  arrange/act/assert banner comments for the implementer to fill — the test name and the spec are
  the scaffolding.
- **BDD (if the repo uses godog/cucumber):** a `.feature` scenario per user-visible spec with
  Given/When/Then in the repo's existing phrasing; leave the steps undefined (pending) so the
  suite is red.
- Map every spec to at least one skeleton; every skeleton names its `SPEC-N`. One-to-one, both ways.

Run them once and confirm they are **red** (a skeleton that passes is not a skeleton). A red
skeleton suite is the executable form of the approved intent — it is what the implementer makes
green, and what the `anvil:test-engineer` step later checks for realism.

## Step 3 — The single approval

Present the **one-liner spec list** to the human and ask them to approve it (`AskUserQuestion`
in the main session). This is the only approval anvil asks for.

- Show only the numbered specs and any BLOCKING open question — not the plan, not the code, not
  the skeleton source. Keep it scannable.
- On approve → proceed to plan/implement; the skeletons are now the frozen contract.
- On change → edit the spec list and skeletons, re-present. Don't start implementing against
  unapproved specs.

## Common rationalizations

| Rationalization | Reality |
|---|---|
| "I'll just explain the plan in a paragraph" | A paragraph hides the decisions. One-liners force each testable claim into the open where the human can veto it. |
| "Writing skeletons first is overhead" | The skeletons are the acceptance tests you'd write anyway (TDD RED). Writing them now pins the intent for free. |
| "I'll get approval at the PR" | By PR time the work is done — approval there is expensive to act on. The cheap veto is on the spec list, before code. |
| "The spec is obvious, skip approval" | Obvious-to-you is the exact case that ships the wrong thing. One quick approval is cheaper than one wrong PR. |

## Red flags

- A spec that describes *how* (names a function, a table, a library) instead of observable behavior.
- A skeleton test that passes, or that fails to compile for a reason unrelated to being unimplemented.
- A spec with no skeleton, or a skeleton with no `SPEC-N` — the mapping must be total.
- Starting to implement before the human approved the list.
- An essay presented for approval instead of a scannable numbered list.

## Verification

Before leaving this gate:

- [ ] Every spec is a single, observable, testable one-liner (no "how", no "and").
- [ ] Every spec maps to at least one skeleton test; every skeleton names its spec.
- [ ] The skeleton suite runs and is **red** for the right reason (unimplemented, not broken).
- [ ] The human approved the one-liner list (the single anvil approval), or requested changes
      that were folded in and re-presented.
