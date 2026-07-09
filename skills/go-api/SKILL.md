---
name: go-api
description: How anvil designs, secures, and proves a Go API — HTTP (JSON) or gRPC. Contract-first, validated at the boundary, honest status codes/gRPC codes, Auth0-protected, tested end-to-end, and shipped with a runnable Postman collection (Auth0 device-flow auth built in). Covers where Flink protos and Auth0 roles live and where to add them, and that every config/secret/resource is provisioned in the service's infra repo. Use whenever a change adds or changes an HTTP or gRPC surface.
---

# Go API — a surface you can't misuse, and can prove

An API is a contract with a blast radius. anvil holds any HTTP/gRPC surface to: contract-first,
validated at the edge, honest errors, authorized, observable, tested end-to-end, and callable by a
teammate in one click. If it isn't all of those, it isn't done.

## When to use

- Adding or changing an HTTP endpoint or a gRPC method/service.
- Changing a request/response shape, a status code, an auth requirement, or a proto.
- Any time the change's acceptance criteria mention "endpoint", "API", "RPC", "route", or "handler".

## Contract first

Define the shape before the handler. The contract is the spec; the implementation follows it.

- **HTTP:** design resources as plural nouns, no verbs in paths (`POST /v1/rules`, not
  `/v1/createRule`); version under a base path (`/v1`); paginate every list endpoint; PATCH is a
  partial update. Keep the OpenAPI spec in the change, next to the code.
- **gRPC:** the proto **is** the contract. Flink protos live in
  [`goflink/grpc-protos`](https://github.com/goflink/grpc-protos) — consume the generated client
  from there; if you need a new message/method, add it there (reserve removed field numbers, never
  reuse one) and cut a new version, then regenerate. Run `buf breaking --against '.git#branch=main'`
  before changing an existing proto. See the `golang-grpc` specialist skill for server/client/interceptor patterns.
- Separate input types from output types (server-generated fields live only on the output).
- Extend, don't mutate: add optional fields; never change or remove an existing one on a live surface.

## Validate at the boundary, trust inside

External input is untrusted until validated at the edge; internal code then trusts the types.
Validate request bodies, query params, path args, and **every third-party/RPC response** you
consume. Reject unknown/oversized input. Don't re-validate between internal functions.

## Honest errors and status codes

Pick one error body shape and use it on every endpoint (`{code, message, details?}` with a
machine-readable `code`). Map the transport faithfully — the caller branches on these:

| HTTP | gRPC code | Means |
|---|---|---|
| 400 | `InvalidArgument` | malformed request |
| 401 | `Unauthenticated` | missing/invalid token |
| 403 | `PermissionDenied` | authenticated, lacks the permission |
| 404 | `NotFound` | no such resource (never a 500 for a missing id) |
| 409 | `AlreadyExists`/`Aborted` | conflict, version mismatch |
| 422 | `InvalidArgument`/`FailedPrecondition` | well-formed but semantically invalid |
| 500 | `Internal` | server fault — never leak internals to the body |

Wrap internal errors with `%w` for your logs; return a sanitized message to the caller. A 5xx is a
bug to fix, not a status to return for bad input.

## Security — Auth0, permissions, least privilege

Flink surfaces are protected by **Auth0 JWT** (`Authorization: Bearer <token>`), validated per
request (issuer, audience, expiry, signature). Never trust the client for identity.

- Authorize on the **permission** the route needs, not just authentication: reads and writes carry
  distinct scopes (e.g. `read:pricing_rule:all` vs `write:pricing_rule:all`). A valid token missing
  the scope is a **403**, not a 401.
- Permissions, roles, and the API/client apps are defined in
  [`goflink/iac-auth0`](https://github.com/goflink/iac-auth0). If your endpoint needs a new
  permission or role, add it there (Terraform) — do not invent a scope only the code knows about.
- Keep the audience/issuer/client-id in config, never hardcoded; secrets never in code or logs.
- Prefer cluster-internal (`ClusterIP`) exposure for sensitive services; reach them over a
  `kubectl port-forward` tunnel rather than a public URL.

## Test it end-to-end

Unit tests for validation/mapping, an **integration** test that boots the real transport + real
dependency (testcontainers) and drives the handler over the wire, and an **end-to-end** assertion
against the running service (the `anvil:verifier` staging step). Assert status code **and** body
for the happy path and every error path in the specs — a handler tested only on 200 is untested.
See the `go-testing` skill for what "real" means.

## Ship a runnable Postman collection

Every API change updates a Postman collection committed with the code (`<service>.postman_collection.json`):

- One request per endpoint/RPC, with example bodies and the `{{baseUrl}}` / `{{token}}` variables.
- A **collection pre-request script that obtains an Auth0 token** so a teammate can authenticate
  and call the API without hand-rolling auth. Use the device-authorization flow against the
  service's registered CLI app (client-id + audience from `iac-auth0`), cache the token in a
  collection variable, and refresh on expiry. Ship the same flow as a `get-token.sh` helper for
  curl/grpcurl users. The canonical shape (device code → poll → `kubectl port-forward` tunnel →
  call `localhost` with the bearer token; prod vs staging just swaps `auth.goflink.com` /
  `auth.staging.goflink.com` and the cluster) is documented in
  [`pricing2/internal/authoring`](https://github.com/goflink/pricing2/blob/main/internal/authoring/README.md#authentication--calling-the-api-directly-pri-67) — copy it, parameterizing the audience/client-id/service/namespace.
- A machine-to-machine caller uses the client-credentials grant instead of the device flow; note
  which one your endpoint expects.

## Provision what the API needs in infra

Anything the API depends on at runtime — config values, secrets, a new topic/bucket/DB, an ingress
or service exposure, the Auth0 app — is declared in the service's infra repo
`goflink/<service>-infra` (e.g. `pricing2` → `goflink/pricing2-infra`), not improvised at runtime.
The change is not shippable until its resources are provisioned there. See the ship loop's infra step.

## Common rationalizations

| Rationalization | Reality |
|---|---|
| "I'll add auth later" | An unauthenticated write path is a live incident, not a TODO. Wire Auth0 before the endpoint serves. |
| "404 vs 500 doesn't matter" | It's the difference between "you asked for something gone" and "we're broken". Callers alert on 5xx. |
| "Postman is just docs, skip it" | It's how a teammate verifies your API in one click. No collection = every caller re-derives auth. |
| "I'll define the scope in the handler" | A scope only the code knows can't be granted to anyone. Define it in `iac-auth0` or it doesn't exist. |
| "I'll add the proto field and reuse number 3" | Reused field numbers silently corrupt old consumers. Reserve, never reuse. |

## Red flags

- A handler that returns 200 with an error in the body, or 500 for bad input.
- Validation scattered inside business logic instead of at the boundary; unknown fields accepted silently.
- A write endpoint with no permission check, or authorization by authentication alone (no scope).
- A new proto field reusing a number, or an existing field's type/number changed.
- No integration/E2E test for an error path named in the specs.
- No Postman collection, or one without a working auth script.
- A new config/secret/resource read at runtime but never declared in `<service>-infra`.

## Verification

- [ ] Contract defined first (OpenAPI for HTTP; proto in `grpc-protos` for gRPC), backward-compatible.
- [ ] Input validated at the boundary; third-party/RPC responses validated before use.
- [ ] One consistent error shape; HTTP status ↔ gRPC code map honored; no internals leaked.
- [ ] Auth0 JWT enforced; the route authorizes on the correct permission (403 vs 401 correct);
      any new permission/role added in `iac-auth0`.
- [ ] Happy path and every error path in the specs tested end-to-end (unit → integration → staging).
- [ ] Postman collection updated with all endpoints and a working Auth0 token script (+ `get-token.sh`).
- [ ] Every runtime config/secret/resource provisioned in `goflink/<service>-infra`.
