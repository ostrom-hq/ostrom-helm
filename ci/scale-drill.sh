#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Scaling under load on kind, with the real server (image built from ostrom-server main, loaded as $SERVER_IMAGE),
# the built-in PostgreSQL and the HPA on (2 to 4 replicas; needs metrics-server in the cluster). k6 runs in a pod of
# the namespace and hits the server's Service (ci/load/drill.js):
#   1. a peak from two replicas: from 10 to $PEAK_RATE requests/s, held; the HPA must add replicas, the new ones
#      must become ready and serve, and no request fails;
#   2. a version rollout under steady load: `helm upgrade` changes the pod template while k6 sends $ROLLOUT_RATE
#      requests/s; zero failed request (no 5xx, no reset, no timeout), every pod replaced, no container restart
#      (the probes held): the server's shutdown delay drains each old pod before it stops. The CI's requests are below the defaults (ci/standin-values.yaml), so the HPA reacts sooner
#      here than in production: the drill proves the mechanism (scale-up, new pods ready and serving under load), not
#      the production threshold.
# Every figure goes to the job summary. Usage: SERVER_IMAGE=ostrom-server:chart-ci ci/scale-drill.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SERVER_IMAGE:?SERVER_IMAGE (repository:tag of the loaded server image) is required}"
ROLLOUT_RATE=${ROLLOUT_RATE:-50}
PEAK_RATE=${PEAK_RATE:-300}
K6_IMAGE=docker.io/grafana/k6:2.3.0@sha256:2dd4756ec6e14e62778916e1eb850108e4b499304c02df56760fa0bdb0fba0b8
REL=ostrom
NS=ostrom-scale
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/stdout}
work=$(mktemp -d)
sampler=""

fail() { echo "FAIL: $*" >&2; kubectl get pods,hpa,pdb,jobs -n "$NS" -o wide >&2 || true
  kubectl -n "$NS" logs -l job-name --tail=30 >&2 || true; exit 1; }
cleanup() { [ -z "$sampler" ] || kill "$sampler" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT

real=(-f charts/ostrom/ci/standin-values.yaml --set ingress.enabled=false --set polis.enabled=false
      --set server.image.repository="${SERVER_IMAGE%:*}" --set server.image.tag="${SERVER_IMAGE##*:}"
      --set-json 'server.args=[]' --set migrations.initContainer=true
      --set web.enabled=false --set site.enabled=false
      --set server.autoscaling.enabled=true --set server.autoscaling.minReplicas=2 --set server.autoscaling.maxReplicas=4)

kubectl -n kube-system rollout status deployment/metrics-server --timeout 5m || fail "metrics-server is not running"
kubectl create namespace $NS
kubectl label namespace $NS pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest
helm install $REL charts/ostrom -n $NS "${real[@]}" --wait --timeout 10m || fail "install with the real server and the HPA"
kubectl -n $NS create configmap scale-drill-k6 --from-file=drill.js=ci/load/drill.js
target="http://$(kubectl -n $NS get service $REL-server -o jsonpath='{.spec.clusterIP}'):8080"

# k6 as a Job of the release's test component: the NetworkPolicies let it reach the server, nothing else.
k6_job() { # name mode rate duration
  kubectl -n $NS apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata: { name: $1 }
spec:
  backoffLimit: 0
  template:
    metadata:
      labels: { app.kubernetes.io/name: ostrom, app.kubernetes.io/instance: $REL, app.kubernetes.io/component: test }
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext: { runAsNonRoot: true, runAsUser: 12345, runAsGroup: 12345, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: k6
          image: $K6_IMAGE
          args: ["run", "--quiet", "--no-color", "/scripts/drill.js"]
          env:
            - { name: TARGET, value: "$target" }
            - { name: MODE, value: "$2" }
            - { name: RATE, value: "$3" }
            - { name: DURATION, value: "$4" }
            - { name: RAMP, value: "30s" }
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          resources: { requests: { cpu: 200m, memory: 128Mi }, limits: { memory: 512Mi } }
          volumeMounts:
            - { name: script, mountPath: /scripts, readOnly: true }
            - { name: tmp, mountPath: /tmp }
      volumes:
        - { name: script, configMap: { name: scale-drill-k6 } }
        - { name: tmp, emptyDir: { sizeLimit: 64Mi } }
YAML
  kubectl -n $NS wait --for=jsonpath='{.status.ready}'=1 job/"$1" --timeout 3m || fail "k6 ($1) did not start"
}
k6_result() { # name timeout -> the summary JSON in $work/<name>.json
  kubectl -n $NS wait --for=condition=complete job/"$1" --timeout "$2" || true
  kubectl -n $NS logs job/"$1" > "$work/$1.log" 2>&1 || true
  grep '^DRILL-SUMMARY ' "$work/$1.log" | tail -1 | cut -d' ' -f2- > "$work/$1.json"
  [ -s "$work/$1.json" ] || { tail -40 "$work/$1.log"; fail "k6 ($1) gave no summary"; }
  cat "$work/$1.json"
}
server_pods() { kubectl -n $NS get pods -l app.kubernetes.io/component=server -o json; }

echo "== 1. A peak from two replicas: the HPA must follow"
kubectl -n $NS wait hpa/$REL-server --for=jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' \
  --timeout 3m >/dev/null 2>&1 || echo "::warning::the HPA had no CPU metric yet before the peak"
# One sample every 5 s: seconds since the start, desired and current replicas, ready server pods.
peak_start=$(date +%s)
( while :; do
    h=$(kubectl -n $NS get hpa $REL-server -o jsonpath='{.status.desiredReplicas} {.status.currentReplicas}' 2>/dev/null || true)
    r=$(kubectl -n $NS get pods -l app.kubernetes.io/component=server -o json 2>/dev/null \
      | jq '[.items[] | select(.metadata.deletionTimestamp == null and any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' || true)
    [ -z "$h" ] || echo "$(( $(date +%s) - peak_start )) $h $r"
    sleep 5
  done ) > "$work/hpa.log" 2>/dev/null &
sampler=$!
k6_job k6-peak peak "$PEAK_RATE" 150s
k6_result k6-peak 6m
kill "$sampler" 2>/dev/null || true; sampler=""
cat "$work/hpa.log"
read -r requests failed dropped p95 p99 < <(jq -r '"\(.requests) \(.failed) \(.dropped) \(.p95) \(.p99)"' "$work/k6-peak.json")
peak_restarts=$(server_pods | jq '[.items[].status.containerStatuses[]?.restartCount] | add // 0')
max_desired=$(awk 'BEGIN { m = 0 } $2 > m { m = $2 } END { print m }' "$work/hpa.log")
max_ready=$(awk 'BEGIN { m = 0 } $4 > m { m = $4 } END { print m }' "$work/hpa.log")
first_up=$(awk '$2 > 2 { print $1; exit }' "$work/hpa.log")
ready_up=$(awk '$4 > 2 { print $1; exit }' "$work/hpa.log")
{
  echo "### Scaling under load (kind, real server, ${SERVER_IMAGE}, HPA 2-4)"
  echo
  echo "| Pass | Requests | Failed | Dropped by k6 | p95 (ms) | p99 (ms) | Other |"
  echo "|---|---|---|---|---|---|---|"
  printf '| peak to %s req/s | %s | %s | %s | %.1f | %.1f | HPA asked %s replicas after %s s, %s ready after %s s, %s restarts |\n' \
  "$PEAK_RATE" "$requests" "$failed" "$dropped" "$p95" "$p99" "$max_desired" "${first_up:--}" "$max_ready" "${ready_up:--}" "$peak_restarts"
} >> "$SUMMARY"
[ "$max_desired" -gt 2 ] || fail "the HPA did not scale up under the peak"
[ "$max_ready" -gt 2 ] || fail "the HPA asked for more replicas, but none became ready during the peak"
[ "$failed" = 0 ] || fail "$failed requests failed during the peak"
[ "$peak_restarts" = 0 ] || fail "$peak_restarts container restarts during the peak (OOM or a probe gave up)"
echo "peak: the HPA went to $max_desired replicas ($max_ready ready), $requests requests, none failed"

echo "== 2. A version rollout under steady load (the HPA may move meanwhile)"
before=$(server_pods | jq -r '[.items[].metadata.name] | sort | join(" ")')
k6_job k6-rollout steady "$ROLLOUT_RATE" 150s
sleep 15
start=$(date +%s)
helm upgrade $REL charts/ostrom -n $NS "${real[@]}" --set-string server.podAnnotations.drill-rollout=2 \
  --wait --timeout 5m || fail "the upgrade under load"
kubectl -n $NS rollout status deploy/$REL-server --timeout 5m || fail "the rollout under load"
rolled=$(( $(date +%s) - start ))
k6_result k6-rollout 5m
server_pods > "$work/after.json"
after=$(jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name] | sort | join(" ")' "$work/after.json")
for p in $before; do case " $after " in *" $p "*) fail "pod $p was not replaced by the upgrade" ;; esac; done
restarts=$(jq '[.items[].status.containerStatuses[]?.restartCount] | add // 0' "$work/after.json")
read -r requests failed dropped p95 p99 < <(jq -r '"\(.requests) \(.failed) \(.dropped) \(.p95) \(.p99)"' "$work/k6-rollout.json")
{
  printf '| rollout at %s req/s | %s | %s | %s | %.1f | %.1f | rollout %s s, %s restarts |\n' \
    "$ROLLOUT_RATE" "$requests" "$failed" "$dropped" "$p95" "$p99" "$rolled" "$restarts"
  echo
} >> "$SUMMARY"
[ "$failed" = 0 ] || fail "$failed requests failed during the rollout"
[ "$requests" -ge $(( ROLLOUT_RATE * 150 * 9 / 10 )) ] || fail "only $requests requests sent during the rollout"
[ "$restarts" = 0 ] || fail "$restarts container restarts during the rollout (a probe gave up)"
[ "$rolled" -le 120 ] || fail "the rollout took ${rolled}s: it outlasted the load window (135 s)"
echo "rollout under load: $requests requests, none failed, every pod replaced in ${rolled}s"

helm uninstall $REL -n $NS --wait
kubectl delete namespace $NS --wait=false
echo "scale drill: ok"
