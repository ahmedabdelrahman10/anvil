---
name: go-observability
description: How anvil makes a Go service diagnosable in production — Datadog metrics that cover every path, and logs only on error. Metrics-first, low-cardinality, one greppable signal per failure mode, symptom-based alerts. The bar is: when something breaks, one glance at the dashboard says what and where. Use when building or changing any feature that runs in production — it is instrumented in the same change, like tests.
---

# Go observability — metrics that make failure obvious

Code you can't observe is code you can't operate. anvil's rule is narrow on purpose: **metrics
cover every scenario; logs fire only on error.** A wall of info logs is noise that slows the next
incident; a small set of well-named metrics answers "what's wrong?" in one glance. Instrument in
the same change as the feature — not after the first page.

## When to use

- Building or changing any feature that runs in production (this is invoked on every ship run).
- Adding an endpoint, background job, queue consumer, or external/RPC dependency.
- Reviewing a change that adds I/O, retries, or cross-service calls with no new telemetry.

Not for: diagnosing a live failure (that's `go-debugging`) or optimizing measured slowness
(`golang-performance`). This skill is what makes those fast next time.

## Step 1 — Name the on-call questions first

Telemetry without a question is noise. Before instrumenting, write the 2–4 questions an on-call
engineer will ask about this feature, then make each answerable by exactly one metric:

```
FEATURE: rule authoring write path
ON-CALL WILL ASK:
1. Are writes succeeding? → counter rule_write_total{result=ok|error}
2. When they fail, why?   → tag result=error, reason=validation|auth|store|conflict
3. Is the store slow?     → histogram rule_store_duration_seconds
```

If you can't name the questions, you'll emit everything and learn nothing.

## Step 2 — Metrics cover every scenario (Datadog)

Emit metrics to Datadog (dogstatsd / `DD_`-configured client, or OpenTelemetry → Datadog). Two
layers, both required:

- **RED on every endpoint and every dependency** — **R**ate, **E**rrors, **D**uration (a latency
  histogram, never an average). For resources (pools, queues) use **USE** (utilization, saturation,
  errors).
- **A business-outcome counter per feature** with a `result` tag and, on failure, a bounded
  `reason` tag. This is the "stupidly simple" part: **every distinct failure mode increments a
  distinct `reason`**, so the dashboard names the cause without anyone reading code.

```go
// one counter, one tag per outcome — every path is covered
tags := []string{"result:" + result} // "ok" | "error"
if reason != "" {
    tags = append(tags, "reason:"+reason) // "validation"|"auth"|"store"|"conflict" — a FIXED set
}
statsd.Incr("rule_write_total", tags, 1)
statsd.Histogram("rule_store_duration_seconds", secs, []string{"result:" + result}, 1)
```

**Cardinality is the failure mode.** Tags must come from small fixed sets (route template, status
class, reason, provider). Never tag with a user id, order id, raw URL, or error text — that is
unbounded and melts the metrics backend. Read percentiles (p50/p95/p99), never averages.

Cover **every** branch: each early return / error path increments the counter with its own
`reason`. A path with no metric is a blind spot — that's the anti-goal.

## Step 3 — Logs only on error

Metrics say *what* and *how often*; a log says *why* for the one case that broke. So log at
`error` (and `warn` for a handled degradation), with structured fields and enough context to act —
and **do not** emit `info`/`debug` per request in production. No happy-path narration.

```go
// only when something actually went wrong:
slog.ErrorContext(ctx, "rule write failed",
    "reason", reason, "rule_id", id, "err", err) // structured fields, not a sentence
```

- Structured key/value, stable message, never string-interpolated prose. Use Flink's
  `github.com/goflink/go-telemetry/v2/flog` (slog-based, auto-correlates Datadog trace/span ids) —
  always pass `ctx` (`flog.ErrorContext(ctx, …)`); a format string loses correlation.
- **Match the `slog.*` constructor to the field's Go type — never narrow-cast.** `slog.Int` takes
  `int` (32-bit on some targets), so `slog.Int("id", int(id64))` silently truncates a TalonOne-style
  `int64` id; use `slog.Int64`. Likewise `slog.Float64`/`slog.Duration`/`slog.Time`/`slog.Bool`.
  `-race` and tests won't catch it — it's an arch-dependent runtime defect.
- A correlation/trace id on every error line (accept or generate at the boundary; propagate via
  `context.Context`) so a failure ties back to its request and Datadog trace.
- **Never** log secrets, tokens, or PII — telemetry is a classic leak path.
- If you find yourself logging to confirm success, that's a metric, not a log.

## Step 4 — Alert on symptoms, not causes

Page on what a user feels — error rate, p99 latency, queue age — not on CPU/memory (those are
dashboard context). Every alert is actionable, has a threshold justified by an SLO/history, and
links a runbook. Two severities only: **page** (act now) and **ticket** (act this week).

## Step 5 — Verify the telemetry itself

Instrumentation is code and can be wrong. Before "done": force each failure path in staging and
confirm the counter increments with the right `reason`; confirm the latency histogram has sane
percentiles; confirm an induced error is findable in Datadog by correlation id; test-fire each new
alert once. The infra side (Datadog monitors, dashboards, the DD agent/config) is declared in
`goflink/<service>-infra` — see the ship loop's infra step.

## Common rationalizations

| Rationalization | Reality |
|---|---|
| "I'll add metrics after it works" | "After" means "after the first incident" — the most expensive moment to discover you're blind. |
| "More logs = more visibility" | Unstructured info-spam makes incidents slower. Three metrics beat three hundred log lines. |
| "I'll log every request so I can trace it" | That's a metric (rate) plus a trace id. Per-request info logs are cost with no diagnostic payoff. |
| "One error metric is enough" | Without a `reason` tag you know it broke, not why. One tag per failure mode is the whole point. |
| "User id as a tag makes debugging easier" | It's an unbounded cardinality bomb. Identity belongs in a log/trace, never a metric tag. |

## Red flags

- A feature with retries/queues/external calls and zero new metrics.
- An error path that returns without incrementing a failure metric (a blind spot).
- Metrics tagged with user id, raw URL, or error text (cardinality bomb).
- `info`/`debug` logs narrating the happy path in production.
- Latency tracked as an average; no p95/p99.
- Secrets/PII in any log line.
- Datadog monitors/dashboards created by hand instead of declared in `<service>-infra`.

## Verification

- [ ] The on-call questions are written down; each maps to exactly one metric.
- [ ] RED metrics on every new endpoint and dependency; a business counter with `result` (+ bounded
      `reason`) covering **every** branch including each error path.
- [ ] All metric tags come from small fixed sets — no user id / raw URL / error text.
- [ ] Latency is a histogram; p95/p99 are queryable.
- [ ] Logs fire only on error/warn, structured, with a correlation id, no secrets/PII, no happy-path spam.
- [ ] New alerts are symptom-based with a runbook link and were test-fired once.
- [ ] Datadog monitors/dashboards and DD config are declared in `goflink/<service>-infra`.
