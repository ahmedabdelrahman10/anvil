---
name: flink-infra
description: How anvil provisions the infrastructure a Flink Go service needs — the per-service infra repo, the helm-service-charts (cloudresources + workload) it layers, secrets via Teller/GCP Secret Manager, exposure via Envoy Gateway + Cloudflare, and the networking model. Use when a change needs any runtime resource (config, secret, topic, bucket, DB, gateway/ingress, scaling, Datadog monitor) or when wiring how the service is reached. Read only the specific chart doc you need — never the whole repo.
---

# Flink infra — provision it, don't improvise it

Anything a service needs at runtime that isn't application code — config, secrets, a Pub/Sub
topic, a bucket, a DB, HTTP exposure, autoscaling, a Datadog monitor — is declared in the
service's infra repo `goflink/<service>-infra` (e.g. `pricing2` → `goflink/pricing2-infra`). The
change is not shippable until its resources are provisioned there.

## When to use

- The change reads a new config value or secret, or needs a topic/bucket/DB/queue.
- The service must be reachable over HTTP (a gateway route, auth, CORS, rate limit, timeout).
- You're adding Datadog monitors/dashboards, or changing scaling/resources.

## The infra repo = helm values over shared charts

`<service>-infra` is mostly per-environment helm **values** files (`staging/…`, `production/…`)
that layer the shared charts in `goflink/helm-service-charts`. Two charts matter — **read only the
one doc you need, never the whole repo:**

- **`cloudresources`** — GCP resources (Pub/Sub topics & subscriptions, buckets, secrets, service
  accounts, IAM). For an attribute, read only `cloudresources/docs/EXAMPLES.md`,
  `cloudresources/docs/VALUES.md`, or `cloudresources/schemas/`.
- **`workload`** — the deployment: container, env, autoscaling, and the gateway (`edgeStack`). For
  an attribute, read only `workload/docs/EXAMPLES.md`, `workload/docs/VALUES.md`, or
  `workload/schemas/`.

Only open those exact paths when you need a specific key's name/shape — don't browse the charts.

## Secrets — Teller locally, GCP Secret Manager in the cluster

Never put secrets in `.env` files (they leak into git, unencrypted). Two regimes:

- **Local dev — Teller** loads GCP Secret Manager secrets into your shell as env vars. Install
  `brew tap spectralops/tap && brew install teller`; add a checked-in `.teller.yml`:
  ```yaml
  providers:
    gsm:
      kind: google_secretmanager
      maps:
        - id: staging
          path: projects/flink-core-staging
          keys: { SOME_SECRET: SOME_ENV }   # GSM secret SOME_SECRET → env SOME_ENV
  ```
  Then `teller show` (verify) and `teller run --reset --shell -- go run main.go` (run). Docker:
  `docker run --env-file <(teller env) …`. Optionally sync non-secret `.env` via a `dotenv` provider.
  `.teller.yml` is safe to commit (no secrets in it); Teller is **local-dev only**.
- **Staging/prod (Platform 2.0)** — a GCP Secret Manager secret is synced into a K8s secret by the
  ExternalSecrets operator and consumed as an env var. Three moves, in two files + one CLI step:
  1. **Declare the secret** in `<env>/infra/values.yaml` under `cloudresources.gcpSecrets`:
     ```yaml
     cloudresources:
       gcpSecrets:
         keys: [MY_FIRST_SECRET, MY_SECOND_SECRET]
         additionalAccessors: ['group:my-team@goflink.com']   # view the value
         versionAdders:       ['group:my-team@goflink.com']   # add a new version
     ```
     The chart **prefixes the service name** (repo `foo` → the GCP secret is `FOO_MY_FIRST_SECRET`).
     Accessors/versionAdders must be **Google groups** (`group:` prefix), so on/offboarding is a group edit.
  2. **Consume it** in `<env>/workload/values.yaml` under `externalSecrets` — the `key` **must start
     with the service prefix** (else ArgoCD can't find the GCP secret) and `name` is the env var:
     ```yaml
     workload:
       externalSecrets:
         - { key: FOO_MY_FIRST_SECRET, name: FIRST_SECRET_VAR, version: 2 }
     ```
  3. **Add the value** out-of-band (never in git) via gcloud — `-n` avoids a trailing newline:
     `echo -n "VALUE" | gcloud secrets versions add FOO_MY_FIRST_SECRET --data-file=-`
     (set the project first: `gcloud config set project flink-core-staging`). Until a value exists
     the ExternalSecret shows **Degraded** and the pod errors `secret "..." not found` — expected.
  **Pin `version: N`, never `latest`.** Updating the GCP value does not reload a running pod;
  bumping the `version` in `workload/values.yaml` is what triggers the rollout that re-reads it.

## Exposure — Envoy Gateway (the API Gateway)

Services are cluster-internal (`ClusterIP`) by default and reached over `kubectl port-forward`.
To serve HTTP publicly, enable the gateway in the **workload** values (`<env>/workload/values.yaml`):

```yaml
edgeStack:                      # key is legacy-named; the impl is Envoy Gateway
  enabled: true
  securityPolicy:               # JWT (Auth0) — a SecurityPolicy is required when filterPolicy is on
    enabled: true
    jwtProviders:
      - name: auth0-staging
        audience: "https://api.staging.goflink.com"
        remoteJWKSUri: "https://flink-staging.eu.auth0.com/.well-known/jwks.json"
        issuer: "https://flink-staging.eu.auth0.com/"
        claimToHeaders:          # forward claims (e.g. permissions) to your service as headers
          - { claim: "permissions", header: "X-Token-C-Permissions" }
```

Common knobs (all under `edgeStack`, all in the workload values): `cors` (headers/origins/methods —
never `*` origin), `unfilteredPaths` (leave `/health` open), `apiKeyAuth` (with an `API_KEY` in
`cloudresources.gcpSecrets`), `rateLimit.limitRequestPerUser` ({rate, unit}), `timeout_ms` /
`connect_timeout_ms` / `idle_timeout_ms` (default is 3s — bump for slow endpoints), and
`exposeRoute` / `exposeEndpoint` to publish only a subset of paths. Default host is
`api[.staging].goflink.com`; a custom `hostname` also needs an A record added in
`goflink/iac-cloudflare`. This is the same Auth0/permission model as `go-api` — keep them consistent.

## Networking & Cloudflare (the request path)

North-south traffic enters through **Cloudflare** (DNS, WAF, edge rate-limit, TLS termination) →
the cluster load balancer → Envoy Gateway → your pod (HTTP inside the cluster). Cloudflare only —
DNS records, public rate-limit rules, new zones — is managed in `goflink/iac-cloudflare` (a PR with
review); prefer restricting to trusted origins, never a bare `*`. East-west (service-to-service) is
direct, no proxy. CloudSQL is reached via the Cloud SQL proxy (no private IP). Only expose publicly
what must be; sensitive services stay internal and are reached by port-forward (see `go-api`).

## Terraform (when the infra is Terraform, not just helm values)

Follow the house rules: pass complex inputs as a **list of objects** (`type = any`) and convert to
a map inside the module — not a map at the call site; gate resources on `module_enabled` and
reference conditional resources with `one(...)`; **avoid `try(var.x, null)`** (it masks typos and
always short-circuits — use it only for genuinely-optional nested attributes); be very careful with
`google_*_iam_binding`/`_iam_policy` — they silently **overwrite** existing access, so check before
applying; and pin Terraform, provider, and module versions in every stack.

## Common rationalizations

| Rationalization | Reality |
|---|---|
| "I'll read the config from an env var and set it later" | An undeclared value isn't there in staging/prod. Declare it in `cloudresources` before it's read. |
| "I'll put the secret in a `.env` for now" | `.env` leaks into git, unencrypted. Teller locally, GCP Secret Manager in-cluster. |
| "I'll expose the service on a public URL" | Sensitive services stay `ClusterIP`; expose only via Envoy Gateway + Auth0, and only the paths that must be public. |
| "I'll browse helm-service-charts to find the key" | Read only the one chart's `EXAMPLES.md`/`VALUES.md`/`schemas/` — the repo is large; don't eat context. |
| "`try(var.x, null)` is a safe default" | It always returns `var.x` and hides typos. Use `one()`/explicit locals; reserve `try` for optional nested attrs. |

## Red flags

- A config/secret/resource read at runtime but never declared in `<service>-infra`.
- A secret in a `.env` or in code; a `.teller.yml` used outside local dev.
- A public route with no Auth0 `securityPolicy`, `cors.origins: "*"`, or `/health` left protected.
- A custom hostname with no matching A record in `iac-cloudflare`.
- Terraform: a map-at-call-site input, a bare `google_*_iam_binding` overwriting access, `try(var.x, null)`, unpinned versions.
- Reading the whole helm-service-charts / infra repo instead of the one doc you needed.

## Verification

- [ ] Every new runtime config/secret/resource is declared in `goflink/<service>-infra` (right chart).
- [ ] Secrets: `.teller.yml` for local dev only; staging/prod via `gcpSecrets` → Secret Manager.
- [ ] If exposed: Envoy Gateway enabled with Auth0 `securityPolicy`, scoped CORS, sane timeout,
      `/health` unprotected; custom hostname has an `iac-cloudflare` A record.
- [ ] Pub/Sub topics/subscriptions (incl. analytics + dead-letter) declared in `cloudresources`.
- [ ] Any Terraform follows the house rules (list-of-objects, `one()`, no `try(var.x, null)`, careful IAM, pinned versions).
- [ ] Only the specific chart docs were read — not the whole repo.
