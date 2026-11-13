#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# The chart's performance drill on kind, with the real server (image built from ostrom-server main, loaded as
# $SERVER_IMAGE), two server replicas and the built-in PostgreSQL:
#   1. startup: for PostgreSQL and each server pod, the seconds from the pod's creation to scheduled, initialized
#      (the server's `migrate` init container done, PostgreSQL's wait included), started and ready, in the job
#      summary; a server pod fails above $STARTUP_CEILING_SECONDS from initialized to ready (its own start: the
#      container, the startup probe, the first readiness; the startup probe gives up at 120 s);
#   2. the server's PodDisruptionBudget against a node drain: kind has one node, so a drain can evict one server pod
#      and must then be refused for the other (its replacement cannot schedule on the cordoned node). The Service
#      keeps a ready endpoint all along, and a direct eviction of the last ready pod gets 429.
# Usage: SERVER_IMAGE=ostrom-server:chart-ci ci/perf-drill.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SERVER_IMAGE:?SERVER_IMAGE (repository:tag of the loaded server image) is required}"
CEILING=${STARTUP_CEILING_SECONDS:-30}
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
# jq does the dates (fromdateiso8601), so the script runs with any date(1).
kubectl -n $NS get pods -l "app.kubernetes.io/component in (server,postgresql)" -o json > "$work/pods.json"
jq -r '
  def at($t): [.status.conditions[] | select(.type == $t) | .lastTransitionTime][0];
  def since($c; $t): if $t == null then "-" else (($t | fromdateiso8601) - ($c | fromdateiso8601)) end;
  .items[] | .metadata.creationTimestamp as $c
  | [.metadata.labels["app.kubernetes.io/component"], .metadata.name, since($c; at("PodScheduled")),
     since($c; at("Initialized")), since($c; [.status.containerStatuses[].state.running.startedAt] | max),
     since($c; at("Ready"))] | @tsv' "$work/pods.json" > "$work/startup.tsv"
cat "$work/startup.tsv"
{
  echo "### Chart startup (kind, real server, ${SERVER_IMAGE})"
  echo
  echo "Seconds from the pod's creation. The server's \"initialized\" includes PostgreSQL's first start and the migrations."
  echo
  echo "| pod | scheduled | initialized | started | ready |"
  echo "|---|---|---|---|---|"
  awk -F'\t' '{ printf "| %s | %s | %s | %s | %s |\n", $2, $3, $4, $5, $6 }' "$work/startup.tsv"
  echo
} >> "$SUMMARY"
[ "$(awk -F'\t' '$1 == "server"' "$work/startup.tsv" | wc -l)" -eq 2 ] || fail "two server pods expected in the measure"
[ "$(awk -F'\t' '$1 == "postgresql"' "$work/startup.tsv" | wc -l)" -eq 1 ] || fail "the PostgreSQL pod is not in the measure"
slow=$(awk -F'\t' -v max="$CEILING" '$1 == "server" && ($6 == "-" || $4 == "-" || $6 - $4 > max) { printf " %s=%ss", $2, ($6 == "-" ? "never" : $6 - $4) }' "$work/startup.tsv")
[ -z "$slow" ] || fail "server pods ready more than ${CEILING}s after their init containers:$slow"

echo "== 2. The PodDisruptionBudget holds a drain"
[ "$(kubectl -n $NS get pdb $REL-server -o jsonpath='{.spec.minAvailable}')" = 1 ] || fail "no PodDisruptionBudget with minAvailable 1"
kubectl -n $NS wait pdb/$REL-server --for=jsonpath='{.status.disruptionsAllowed}'=1 --timeout 60s \
  || fail "the budget does not allow one disruption with two ready pods"
node=$(kubectl -n $NS get pods -l app.kubernetes.io/component=server -o jsonpath='{.items[0].spec.nodeName}')
ready_endpoints() {
  kubectl -n $NS get endpointslices -l kubernetes.io/service-name=$REL-server -o json \
    | jq '[.items[].endpoints[]? | select(.conditions.ready)] | length'
}
# One sample a second (plus the call's own time); a failed call writes nothing, it is a missed sample, not a zero.
( while :; do ready_endpoints || true; sleep 1; done ) > "$work/endpoints.log" 2>/dev/null &
watcher=$!
if kubectl drain "$node" --pod-selector=app.kubernetes.io/component=server --ignore-daemonsets \
    --delete-emptydir-data --timeout=90s > "$work/drain.log" 2>&1; then
  cat "$work/drain.log"; fail "the drain evicted every server pod: the budget did not hold"
fi
kill "$watcher" 2>/dev/null || true; watcher=""
cat "$work/drain.log"
grep -q "disruption budget" "$work/drain.log" || fail "the drain did not stop on the budget"
echo "ready endpoints during the drain: $(sort -n "$work/endpoints.log" | uniq -c | tr -s ' ' | tr '\n' ';')"
samples=$(grep -cx '[0-9][0-9]*' "$work/endpoints.log" || true)
[ "$samples" -ge 30 ] || fail "only $samples samples of the Service's endpoints during the drain"
! grep -qx '0' "$work/endpoints.log" || fail "the server had no ready endpoint during the drain"
ready_pods=$(kubectl -n $NS get pods -l app.kubernetes.io/component=server -o json | jq -r '.items[]
  | select(.metadata.deletionTimestamp == null and any(.status.conditions[]?; .type == "Ready" and .status == "True"))
  | .metadata.name')
[ "$(echo "$ready_pods" | grep -c .)" -eq 1 ] || fail "one ready server pod expected after the drain, got: $ready_pods"
last=$ready_pods
printf '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"%s","namespace":"%s"}}' "$last" $NS > "$work/eviction.json"
if kubectl create --raw "/api/v1/namespaces/$NS/pods/$last/eviction" -f "$work/eviction.json" > "$work/evict.log" 2>&1; then
  fail "the last server pod was evicted"
fi
grep -q "disruption budget" "$work/evict.log" || { cat "$work/evict.log"; fail "the eviction was refused, but not by the budget"; }
echo "the last server pod's eviction: refused by the budget"
kubectl uncordon "$node"; node=""
kubectl -n $NS rollout status deploy/$REL-server --timeout 5m || fail "the server did not come back after the uncordon"
echo "Drain of the node: one server pod evicted, the other refused by the budget (429), a ready endpoint all along ($samples samples)." >> "$SUMMARY"

helm uninstall $REL -n $NS --wait
kubectl delete namespace $NS --wait=false
echo "perf drill: ok"
