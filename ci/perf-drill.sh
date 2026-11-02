#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# The chart's performance drill on kind, with the real server (image built from ostrom-server main, loaded as
# $SERVER_IMAGE), two server replicas and the built-in PostgreSQL:
#   1. startup: for PostgreSQL and each server pod, the seconds from the pod's creation to scheduled, initialized
#      (the server's `migrate` init container done), started and ready; written to the job summary, and a failure
#      above $STARTUP_CEILING_SECONDS for a server pod (the startup probe gives up at 120 s);
#   2. the server's PodDisruptionBudget against a node drain: kind has one node, so a drain can evict one server pod
#      and must then be refused for the other (its replacement cannot schedule on the cordoned node). The Service
#      keeps a ready endpoint all along, and a direct eviction of the last ready pod gets 429.
# Usage: SERVER_IMAGE=ostrom-server:chart-ci ci/perf-drill.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SERVER_IMAGE:?SERVER_IMAGE (repository:tag of the loaded server image) is required}"
CEILING=${STARTUP_CEILING_SECONDS:-90}
REL=ostrom
NS=ostrom-perf
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/stdout}
work=$(mktemp -d)
node=""

fail() { echo "FAIL: $*" >&2; kubectl get pods,pdb,endpointslices -n "$NS" -o wide >&2 || true; exit 1; }
cleanup() {
  [ -z "${watcher:-}" ] || kill "$watcher" 2>/dev/null || true
  [ -z "$node" ] || kubectl uncordon "$node" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

kubectl create namespace $NS
kubectl label namespace $NS pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest
helm install $REL charts/ostrom -n $NS -f charts/ostrom/ci/standin-values.yaml --set ingress.enabled=false \
  --set polis.enabled=false --set server.image.repository="${SERVER_IMAGE%:*}" \
  --set server.image.tag="${SERVER_IMAGE##*:}" --set-json 'server.args=[]' --set migrations.initContainer=true \
  --set server.replicas=2 --set web.enabled=false --set site.enabled=false \
  --wait --timeout 10m || fail "install with the real server"

echo "== 1. Startup, seconds from the pod's creation"
seconds() { [ -n "$2" ] && [ "$2" != null ] && echo $(( $(date -d "$2" +%s) - $(date -d "$1" +%s) )) || echo "-"; }
{
  echo "### Chart startup (kind, real server, ${SERVER_IMAGE})"
  echo
  echo "| pod | scheduled | initialized | started | ready |"
  echo "|---|---|---|---|---|"
} >> "$SUMMARY"
slow=""
for p in $(kubectl -n $NS get pods -l "app.kubernetes.io/component in (server,postgresql)" -o name); do
  kubectl -n $NS get "$p" -o json > "$work/pod.json"
  created=$(jq -r .metadata.creationTimestamp "$work/pod.json")
  cond() { jq -r --arg t "$1" '.status.conditions[] | select(.type == $t) | .lastTransitionTime' "$work/pod.json"; }
  started=$(jq -r '[.status.containerStatuses[] | .state.running.startedAt] | max' "$work/pod.json")
  ready=$(seconds "$created" "$(cond Ready)")
  echo "| ${p#pod/} | $(seconds "$created" "$(cond PodScheduled)") | $(seconds "$created" "$(cond Initialized)") | $(seconds "$created" "$started") | $ready |" >> "$SUMMARY"
  case "$p" in *-server-*) [ "$ready" != - ] && [ "$ready" -le "$CEILING" ] || slow="$slow ${p#pod/}=${ready}s" ;; esac
done
echo >> "$SUMMARY"
[ -z "$slow" ] || fail "server pods ready after more than ${CEILING}s:$slow"

echo "== 2. The PodDisruptionBudget holds a drain"
[ "$(kubectl -n $NS get pdb $REL-server -o jsonpath='{.spec.minAvailable}')" = 1 ] || fail "no PodDisruptionBudget with minAvailable 1"
kubectl -n $NS wait pdb/$REL-server --for=jsonpath='{.status.disruptionsAllowed}'=1 --timeout 60s \
  || fail "the budget does not allow one disruption with two ready pods"
node=$(kubectl -n $NS get pods -l app.kubernetes.io/component=server -o jsonpath='{.items[0].spec.nodeName}')
ready_endpoints() {
  kubectl -n $NS get endpointslices -l kubernetes.io/service-name=$REL-server -o json \
    | jq '[.items[].endpoints[]? | select(.conditions.ready)] | length'
}
( while :; do ready_endpoints || echo error; sleep 1; done ) > "$work/endpoints.log" 2>/dev/null &
watcher=$!
if kubectl drain "$node" --pod-selector=app.kubernetes.io/component=server --ignore-daemonsets \
    --delete-emptydir-data --timeout=90s > "$work/drain.log" 2>&1; then
  cat "$work/drain.log"; fail "the drain evicted every server pod: the budget did not hold"
fi
kill "$watcher"; watcher=""
cat "$work/drain.log"
grep -q "disruption budget" "$work/drain.log" || fail "the drain did not stop on the budget"
echo "ready endpoints during the drain: $(sort -n "$work/endpoints.log" | uniq -c | tr -s ' ' | tr '\n' ';')"
[ -s "$work/endpoints.log" ] || fail "no sample of the Service's endpoints during the drain"
! grep -qvx '[1-9][0-9]*' "$work/endpoints.log" || fail "the server had no ready endpoint during the drain"
last=$(kubectl -n $NS get pods -l app.kubernetes.io/component=server \
  -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' | head -1)
[ -n "$last" ] || fail "no server pod left running"
printf '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"%s","namespace":"%s"}}' "$last" $NS > "$work/eviction.json"
if kubectl create --raw "/api/v1/namespaces/$NS/pods/$last/eviction" -f "$work/eviction.json" > "$work/evict.log" 2>&1; then
  fail "the last server pod was evicted"
fi
grep -q "disruption budget" "$work/evict.log" || { cat "$work/evict.log"; fail "the eviction was refused, but not by the budget"; }
echo "the last server pod's eviction: refused by the budget"
kubectl uncordon "$node"; node=""
kubectl -n $NS rollout status deploy/$REL-server --timeout 5m || fail "the server did not come back after the uncordon"
echo "Drain of the node: one server pod evicted, the other refused by the budget (429), a ready endpoint all along ($(wc -l < "$work/endpoints.log" | tr -d ' ') samples)." >> "$SUMMARY"

helm uninstall $REL -n $NS --wait
kubectl delete namespace $NS --wait=false
echo "perf drill: ok"
