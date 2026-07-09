---
name: go-analytics
description: How anvil emits analytics/BI data from a Go service the Flink way — you never write to BigQuery directly. You define an event schema, publish to a Pub/Sub topic, and a mandatory BigQuery subscription lands it in a BQ table. Covers the schema repo (data-streaming-platform-events), the proto rules and DATA naming conventions, wiring the topic/subscription/dead-letter in infra, and implementing the publisher. Use whenever a change needs to track an event or send data to BigQuery/analytics.
---

# Go analytics — events to BigQuery via Pub/Sub

At Flink you do not write to BigQuery from a service. The path is: **define an event schema →
publish to a Pub/Sub topic (schema attached as the contract) → a mandatory BigQuery subscription
ingests it into a BQ table** (with a dead-letter topic for invalid events). This makes ingestion
self-service and gives the data team a governed, backward-compatible contract. Note: this is a
different repo and purpose from gRPC — RPC contracts live in `grpc-protos` (`go-api`); **analytics
event schemas live in `data-streaming-platform-events`**.

## When to use

- A change needs to record something for BI / data science / analytics ("track this event", "send
  X to BigQuery", "we need this in a dashboard").
- Adding a field to, or versioning, an existing analytics event.

Not for: service-to-service RPC (that's `go-api`), or operational metrics/alerting (that's
`go-observability` → Datadog).

## Step 1 — Define the event schema (data-streaming-platform-events)

Add a proto to `events/schemas/{gcp-project}/{service}/` (e.g. `flink-core/pricing/`) — the file is
snake_case named for the event (`order_created.proto`), plus `config.yaml` and a `README.md`. The
schema **is** the contract; the CI/CD there validates it and publishes it to Pub/Sub Schemas.

Rules (these are load-bearing — the platform enforces them and BigQuery makes some permanent):

- **`proto3`.** Package `schema`.
- **No imports** — Pub/Sub Schemas forbids them. So **no `google.protobuf.Timestamp`**: every time
  field is a POSIX millisecond `int64` with a `_posix` suffix (`int64 event_timestamp_posix = 5;`).
- **Mandatory common fields, at the top level (never nested):** `string event_name` (global event
  id, e.g. `order_created`) and `int64 event_timestamp_posix` (ms UTC, when the event *occurred* —
  not when sent). Include `string event_id` (publisher-generated uuid) too.
- **Strings, not enums** — BigQuery stores enums as integers, which is unreadable and drifts from
  the code. Use `string` with documented values.
- **Comment every field** with a description.
- **Follow the DATA naming conventions** below for every non-mandatory field.
- **You can never rename or delete a column** once it's in the BQ table — plan the shape carefully;
  additive changes only (append a new field number, never reuse or remove one).

Deploy: open a PR; **approval by the data platform team auto-deploys to staging** (you can also run
the staging workflow manually first); **merging auto-deploys to production.**

## DATA naming conventions (the field names the data team enforces)

| Kind | Rule | Example |
|---|---|---|
| General | descriptive `snake_case`, never bare `id`/`type` | `order_id`, `event_type` |
| Orders | customer=`order_id`, supplier=`purchase_order_id` | — |
| Money | `amt_` prefix, `_gross`/`_net` then currency suffix | `amt_gmv_gross_eur`, `*_local` (+`currency`) |
| POSIX time | `_posix` suffix (ms, UTC, when it happened) | `event_timestamp_posix` |
| Timestamp | `_timestamp` suffix, UTC, RFC3339 | `created_at_timestamp` |
| Duration | suffix full unit name, plural | `drive_duration_minutes` |
| Date | `_date` (UTC; `_local` if local) | `order_date` |
| Distance/weight/vol | `type_measurement_unit` (full, plural) | `*_distance_meters`, `order_weight_kilos` |
| Boolean | `is_`/`has_` prefix, TRUE/FALSE | `is_first_order` |
| Geo | `_geo` suffix; country iso `country_iso` (UPPER) | — |
| Aggregations | `number_of_`, `sum_of_`, `avg_`, `share_of_Y_with_X`, `pct_`, `_rate` | `number_of_items` |
| Categorical | the event-type field is named `event_type` | — |
| Hidden/private | `_` prefix | `_internal_flag` |

Avoid acronyms. Full reference: the *DATA Naming Conventions* page. When a field's business meaning
is unclear, align it with the data/analytics team before merging.

## Step 2 — Provision the streaming resources in infra

In the service's `goflink/<service>-infra` (the `cloudresources` chart — see `flink-infra`), declare:

- the **Pub/Sub topic** (in the producer's project), with the schema attached;
- the **mandatory BigQuery subscription** that lands the topic into a BQ table (the BQ table itself
  is created via `data-bq-schemas`, which also applies **policy tags** to sensitive/PII columns);
- a **dead-letter topic** for events that fail ingestion, with its own BQ subscription to a
  dedicated table, plus an alert;
- IAM granting the service publish rights and any consumer the subscribe right.

A consumer team creates its *own* pull subscription in *its* project — you provision the topic, the
mandatory BQ subscription, and the dead-letter. For how subscriptions are wired in a values file,
`goflink/discovery-infra` is a worked example.

## Step 3 — Implement the publisher in the service

Publish the event to the topic on the real code path, mapping your domain type to the schema
fields (POSIX-ms timestamps, string enums). For the concrete publisher wiring (client setup,
marshalling, error handling), `goflink/discovery` PR #1372 is the reference implementation to
follow. On a publish failure, surface it as an error metric (`go-observability`) — a lost publish
is silent data loss.

## Step 4 — Monitoring & quality

A publish error or a dead-letter arrival must alert (Datadog dashboard + Slack per the RFC).
Define the agreed data-quality rules (uniqueness, allowed values, latency) so a bad event is caught
before it propagates. Sensitive fields get policy tags via `data-bq-schemas`.

## Common rationalizations

| Rationalization | Reality |
|---|---|
| "I'll just insert into BigQuery from the service" | There's no direct write path — and you'd lose the schema contract, history, and DLQ. Publish to Pub/Sub. |
| "I'll use an enum, it's cleaner in Go" | BigQuery stores it as an int; the data team sees `1`, not `COMPLETED`. Use a documented string. |
| "I'll rename this column later" | You can't — BQ columns are permanent. Get the name right now, additive-only after. |
| "google.protobuf.Timestamp is standard" | Pub/Sub Schemas forbids imports. Use an `int64 *_posix` millisecond field. |
| "A short field name is fine" | The data team enforces descriptive `snake_case`. `id`/`type` get rejected in review. |

## Red flags

- A service writing to BigQuery directly, or bypassing the schema repo.
- A `_posix` timestamp field typed as anything but `int64`, or a proto with an `import`.
- Missing `event_name` / `event_timestamp_posix` at the top level; enums instead of strings.
- A topic with no mandatory BQ subscription, or no dead-letter topic + alert.
- A publish error path that doesn't increment a metric (silent data loss).
- Field names that flout the DATA naming conventions (bare `id`, `amt_gmv_eur_gross`, acronyms).

## Verification

- [ ] Event schema added under `events/schemas/{project}/{service}/`, proto3, no imports, `_posix`
      `int64` times, `event_name` + `event_timestamp_posix` at top level, strings not enums, every field commented.
- [ ] Field names follow the DATA naming conventions; the shape is additive-only (no future rename/delete needed).
- [ ] Topic + mandatory BQ subscription + dead-letter topic/subscription + IAM declared in `<service>-infra`.
- [ ] Publisher emits on the real path; publish failures increment an error metric and alert.
- [ ] Sensitive columns tagged via `data-bq-schemas`; data-quality rules agreed with the data team.
