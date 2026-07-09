#!/usr/bin/env bash
#
# verify-staging.sh — prove a change against a REAL service running in a k8s cluster.
#
# Generic by design: it does the plumbing (optional GKE creds, namespace discovery,
# port-forward, readiness wait) and then runs YOUR assertion command with the local
# port exported as $ANVIL_PORT. /anvil:ship builds the specific command (a grpcurl
# RPC, a curl, a smoke script); this script makes the tunnel reliable and cleans up.
#
# USAGE
#   verify-staging.sh --service pricing2 --remote-port 8081 [--namespace NS] \
#       [--selector 'app.kubernetes.io/name=pricing2'] [--local-port 18081] \
#       [--context CTX | --cluster C --project P --region R] \
#       [--check] -- grpcurl -plaintext -d '{...}' localhost:$ANVIL_PORT some.Service/Method
#
#   --check   prerequisites + namespace discovery only; opens no tunnel.
#
# Read-only against the cluster (a port-forward). Exit 0 iff the assertion command
# succeeds. Re-run the critical assertion yourself for determinism — this runs the
# command once.

set -uo pipefail

SERVICE="" NAMESPACE="" SELECTOR="" REMOTE_PORT="" LOCAL_PORT="18080"
CONTEXT="" CLUSTER="" PROJECT="" REGION="" CHECK_ONLY=0
CMD=()
while [ $# -gt 0 ]; do
  case "$1" in
    --service) SERVICE="$2"; shift;;
    --namespace) NAMESPACE="$2"; shift;;
    --selector) SELECTOR="$2"; shift;;
    --remote-port) REMOTE_PORT="$2"; shift;;
    --local-port) LOCAL_PORT="$2"; shift;;
    --context) CONTEXT="$2"; shift;;
    --cluster) CLUSTER="$2"; shift;;
    --project) PROJECT="$2"; shift;;
    --region) REGION="$2"; shift;;
    --check) CHECK_ONLY=1;;
    --) shift; CMD=("$@"); break;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
  shift
done

die() { echo "✗ $*" >&2; exit 1; }
say() { echo "› $*"; }

command -v kubectl >/dev/null || die "kubectl not on PATH"
[ -n "$SERVICE" ] || die "--service is required"
[ -z "$SELECTOR" ] && SELECTOR="app.kubernetes.io/name=$SERVICE"

# credentials / context
if [ -n "$CONTEXT" ]; then
  kubectl config use-context "$CONTEXT" >/dev/null 2>&1 || die "no kube context '$CONTEXT'"
elif [ -n "$CLUSTER" ]; then
  command -v gcloud >/dev/null || die "gcloud not on PATH (needed for --cluster)"
  say "getting GKE credentials for $CLUSTER ($PROJECT/$REGION)"
  gcloud container clusters get-credentials "$CLUSTER" ${PROJECT:+--project "$PROJECT"} ${REGION:+--region "$REGION"} >/dev/null 2>&1 \
    || die "could not get GKE credentials — check 'gcloud auth login' / access"
fi

# namespace discovery
if [ -z "$NAMESPACE" ]; then
  say "discovering namespace for selector '$SELECTOR'"
  cands="$(kubectl get pods -A -l "$SELECTOR" -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u)"
  [ -z "$cands" ] && die "no pods match '$SELECTOR'. Pass --namespace/--selector."
  NAMESPACE="$(printf '%s\n' "$cands" | grep -i staging | head -1)"
  [ -z "$NAMESPACE" ] && NAMESPACE="$(printf '%s\n' "$cands" | head -1)"
  say "namespace: $NAMESPACE  (candidates: $(printf '%s' "$cands" | tr '\n' ' '))"
fi
kubectl -n "$NAMESPACE" get pods -l "$SELECTOR" >/dev/null 2>&1 || die "no pods for '$SELECTOR' in '$NAMESPACE'"

if [ "$CHECK_ONLY" -eq 1 ]; then
  kubectl -n "$NAMESPACE" get pods -l "$SELECTOR"
  echo "✓ prerequisites OK — cluster reachable, '$SERVICE' present in '$NAMESPACE'."
  exit 0
fi

[ -n "$REMOTE_PORT" ] || die "--remote-port is required (the service's container port)"
[ "${#CMD[@]}" -gt 0 ] || die "no assertion command after '--' (e.g. -- grpcurl ... localhost:\$ANVIL_PORT ...)"

PF_PID=""
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null; }
trap cleanup EXIT INT TERM

say "port-forward svc/$SERVICE :$REMOTE_PORT → localhost:$LOCAL_PORT (ns $NAMESPACE)"
kubectl -n "$NAMESPACE" port-forward "svc/$SERVICE" "$LOCAL_PORT:$REMOTE_PORT" >/tmp/anvil-pf.log 2>&1 &
PF_PID=$!
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  grep -q "Forwarding from" /tmp/anvil-pf.log 2>/dev/null && { ready=1; break; }
  kill -0 "$PF_PID" 2>/dev/null || { cat /tmp/anvil-pf.log; die "port-forward died — check the service name (try 'svc/$SERVICE' vs a deployment)"; }
  sleep 1
done
[ "$ready" -eq 1 ] || die "port-forward not ready after 15s (see /tmp/anvil-pf.log)"

export ANVIL_PORT="$LOCAL_PORT"
say "running assertion: ${CMD[*]}"
if ANVIL_PORT="$LOCAL_PORT" "${CMD[@]}"; then
  echo "✓ staging assertion passed against live $SERVICE in $NAMESPACE."
else
  die "staging assertion FAILED (exit $?). The change is not verified in staging."
fi
