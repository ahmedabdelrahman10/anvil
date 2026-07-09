---
name: doubt-driven
description: In-flight adversarial self-check — before a non-trivial or hard-to-reverse decision is baked in, spawn a fresh-context skeptic to try to DISPROVE it, while course-correction is still cheap. Use during implementation for concurrency/invariant claims, migrations, public API/proto changes, or unfamiliar code. This is not the reviewer (post-implementation) or the verifier (final enforcement) — it's a per-decision gut-check mid-flight.
---

# Doubt-driven — disprove it before you bake it in

A confident answer is not a correct one. A long implementing session quietly turns assumptions
into "facts". Doubt-driven is the discipline of materializing a fresh-context reviewer — biased to
**disprove**, not approve — before a non-trivial decision stands. It catches a wrong direction at
step 4 (implement), when a fix is one edit — not at step 7 review or step 10 verify, when it's a
whole re-loop. It **complements** them: doubt-driven is in-flight and per-decision; `anvil:reviewer`
is the post-implementation gate; `anvil:verifier` is the final enforcement.

## When to use

Apply to a **non-trivial** decision — one where at least one is true:

- It introduces or reshapes branching logic.
- It asserts a property the compiler/type system can't verify — goroutine safety, ordering,
  idempotence, an invariant.
- Its blast radius is hard to reverse — a DB migration, a public API / gRPC proto change, an event
  schema (columns can't be renamed later), anything that touches production data.
- Its correctness depends on context the future reader can't see, or you're in unfamiliar code.

**Not for:** mechanical edits (rename, format, file move), a one-line change with obvious
correctness, following an unambiguous instruction, or reading/summarizing code. If you doubt every
keystroke you ship nothing — this is for the load-bearing decisions only.

## The cycle

```
- [ ] CLAIM     — write the decision + why it matters, in 2–3 lines
- [ ] EXTRACT   — isolate the artifact (the diff/function) + the contract it must satisfy
- [ ] DOUBT     — spawn a fresh-context reviewer with an adversarial prompt
- [ ] RECONCILE — classify each finding against the artifact; fix, accept, or dismiss
- [ ] STOP      — trivial findings, 3 cycles, or "ship it"
```

### CLAIM — name what stands
```
CLAIM: The snapshot swap is safe to run while readers are live.
WHY:   A race here serves half-updated pricing — silent, and hard to catch in QA.
```
If you can't state it this compactly, it's a vibe, not a decision.

### EXTRACT — the smallest reviewable unit
The reviewer needs the **artifact** (the diff or function, not the whole file) and the
**contract** (the 3–5 sentences of what it must satisfy) — not your reasoning. Strip your
reasoning: hand over conclusions and you get back validation of your conclusions. If it's a
500-line change, decompose first.

### DOUBT — spawn the fresh skeptic
Spawn a fresh-context agent — `anvil:reviewer` scoped to the artifact, or a general subagent —
with an adversarial prompt, and **pass ARTIFACT + CONTRACT only, never the CLAIM** (handing over
your conclusion biases it toward agreement):

```
Adversarially review this Go artifact. Assume the author is overconfident. Find what is wrong:
unstated assumptions, unhandled edge cases, data races / ordering / goroutine-lifetime bugs,
hidden shared state, ways the contract is violated, backward-incompat or migration hazards.
Do NOT validate, do NOT summarize. Report issues, or state you found none after real examination.
ARTIFACT: <the diff/function>   CONTRACT: <what it must satisfy>
```
Optional: for the highest-stakes calls, a colder second model (if a CLI like gemini/codex is
available and the user authorizes it) catches blind spots a single model shares with itself —
offer it, don't force it; never run an external CLI without explicit authorization.

### RECONCILE — findings are data, not verdict
You're still the orchestrator; re-read the artifact against each finding (first match wins):
1. **Contract misread** — your CONTRACT was unclear → fix the contract, re-loop.
2. **Valid + actionable** — real issue → change the code, re-loop.
3. **Valid trade-off** — real but not worth fixing → document it so the human sees it.
4. **Noise** — correct under context the reviewer lacked → note it, move on.
A fresh reviewer can be wrong *because* it lacks your context — don't rubber-stamp it either.

### STOP — bounded, not recursive
Stop when the next cycle returns only trivial/already-considered findings, **or** after 3 cycles
(escalate to the human — three unresolved rounds is information about the artifact), **or** the
user says ship it. If 3 cycles feel "obviously not enough," the artifact is too big — decompose,
don't lift the bound.

## Common rationalizations

| Rationalization | Reality |
|---|---|
| "I'm confident, skip it" | Confidence correlates poorly with correctness on novel problems; certainty is exactly where blind spots hide. |
| "Spawning a reviewer is expensive" | Debugging a wrong migration in prod is far more expensive. The check is bounded; the bug isn't. |
| "I'll catch it at review" | Review is the post-hoc gate; by then the wrong direction is baked in. Doubt while course-correction is cheap. |
| "The reviewer disagreed, so I was wrong" | It lacks your context — disagreement is information. Re-read the artifact, classify, then decide. |
| "Two opinions are always better" | Not when the second has less context and produces noise. Reconcile, don't defer. |

## Red flags

- Spawning a skeptic for a one-line rename (over-application) — or skipping it under time pressure on a migration (under-application).
- Prompting "is this good?" instead of "find what's wrong"; passing the CLAIM or your reasoning to the reviewer.
- Rubber-stamping the reviewer without re-reading the artifact; looping >3 cycles without escalating.
- **Doubt theater:** across ≥2 cycles with substantive findings, zero classified actionable — you're validating, not doubting. Stop and escalate.

## Verification

- [ ] Every non-trivial/irreversible decision was named as a CLAIM before it stood.
- [ ] The reviewer got ARTIFACT + CONTRACT only — not the CLAIM, not your reasoning — with an adversarial prompt.
- [ ] Findings were classified against the artifact (misread/actionable/trade-off/noise), not rubber-stamped.
- [ ] A stop condition was met (trivial findings, 3 cycles, or user override); trade-offs surfaced to the human.
