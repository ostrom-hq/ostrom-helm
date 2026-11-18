#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Scaling under load on kind, with the real server (image built from ostrom-server main, loaded as $SERVER_IMAGE),
# the built-in PostgreSQL and the HPA on (2 to 4 replicas; needs metrics-server in the cluster). k6 runs in a pod of
# the namespace and hits the server's Service (ci/load/drill.js):
#   1. a peak from two replicas: from 10 to $PEAK_RATE requests/s, held; the HPA must add replicas, the new ones
#      must become ready and serve, and no request fails;
#   2. a version rollout under steady load: `helm upgrade` changes the pod template while k6 sends $ROLLOUT_RATE
#      requests/s; zero failed request (no 5xx, no reset, no timeout), every pod replaced, no container restart
#      (the probes held), and the rollout ends well inside the load window. It starts right after the peak, at the
#      replica count the HPA still holds (its scale-down waits 300 s): up to four pods replaced one by one under load.
# The CI's requests are below the defaults (ci/standin-values.yaml), so the HPA reacts sooner here than in production:
# the drill proves the mechanism (scale-up, new pods ready and serving under load), not the production threshold.
# Every figure goes to the job summary. Usage: SERVER_IMAGE=ostrom-server:chart-ci ci/scale-drill.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SERVER_IMAGE:?SERVER_IMAGE (repository:tag of the loaded server image) is required}"
ROLLOUT_RATE=${ROLLOUT_RATE:-50}
# 120 requests/s is 3 to 5 times the CI's CPU target per pod (35m of a 50m request) and still within what the
# 2-vCPU runner carries with k6 and PostgreSQL on it; 300 saturated the node itself (run 41545347185).
PEAK_RATE=${PEAK_RATE:-120}
PEAK_RAMP=30      # seconds from 10 to PEAK_RATE requests/s (ci/load/drill.js)
PEAK_HOLD=150     # seconds held at PEAK_RATE
ROLLOUT_LOAD=240  # seconds of steady load around the rollout
ROLLOUT_LEAD=15   # seconds of load before `helm upgrade`
ROLLOUT_TAIL=30   # seconds of load that must remain after the rollout ends
K6_IMAGE=docker.io/grafana/k6:2.3.0@sha256:2dd4756ec6e14e62778916e1eb850108e4b499304c02df56760fa0bdb0fba0b8
REL=ostrom
NS=ostrom-scale
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/stdout}
work=$(mktemp -d)
sampler=""
catcher=""

fail() { echo "FAIL: $*" >&2; kubectl get pods,hpa,pdb,jobs -n "$NS" -o wide >&2 || true
  echo "-- server containers: restarts and last termination" >&2
  kubectl -n "$NS" get pods -l app.kubernetes.io/component=server -o json 2>/dev/null | jq -r '.items[] | .metadata.name as $p
    | .status.containerStatuses[]? | "\($p) \(.name) restarts=\(.restartCount) last=\(.lastState.terminated.reason // "-")/\(.lastState.terminated.exitCode // "-")"' >&2 || true
  echo "-- events (probes, kills, OOM)" >&2
  kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null | grep -E 'Unhealthy|Killing|OOM|BackOff|Evict' | tail -30 >&2 || true
  for p in $(kubectl -n "$NS" get pods -l app.kubernetes.io/component=server -o name 2>/dev/null); do
    echo "-- $p (previous)" >&2; kubectl -n "$NS" logs "$p" -c server --previous --tail=20 >&2 2>/dev/null || true
  done
  echo "-- every restart seen during the drill" >&2; crashes >&2
  kubectl -n "$NS" logs -l job-name --tail=10 >&2 || true; exit 1; }
stop_sampler() { [ -z "$sampler" ] && return 0; touch "$work/stop"; wait "$sampler" 2>/dev/null || true; sampler=""; }
stop_catcher() { [ -z "$catcher" ] && return 0; touch "$work/stop-catcher"; wait "$catcher" 2>/dev/null || true; catcher=""; }
# Every server container that restarts, whatever the pass: its last termination (reason, exit code, signal, times) and
# its previous logs, read while the pod still exists (a rollout deletes it with its history).
crashes() { [ -s "$work/crashes.txt" ] && cat "$work/crashes.txt" || echo "(no server container restarted)"; }
cleanup() { stop_sampler; stop_catcher; rm -rf "$work"; }
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
            - { name: RAMP, value: "${PEAK_RAMP}s" }
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
k6_result() { # name timeout-in-seconds -> the summary JSON in $work/<name>.json
  # Ends as soon as the Job succeeds or fails (k6 crashed), not at the timeout.
  local deadline=$(( $(date +%s) + $2 )) st=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    st=$(kubectl -n $NS get job "$1" -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null || true)
    case "$st" in 1/*|*/1) break ;; esac
    sleep 5
  done
  case "$st" in 1/*) ;; */1) echo "::warning::k6 ($1) failed" ;; *) echo "::warning::k6 ($1) still running after $2 s" ;; esac
  kubectl -n $NS logs job/"$1" > "$work/$1.log" 2>&1 || true
  { grep '^DRILL-SUMMARY ' "$work/$1.log" || true; } | tail -1 | cut -d' ' -f2- > "$work/$1.json"
  [ -s "$work/$1.json" ] || { tail -40 "$work/$1.log"; fail "k6 ($1) gave no summary"; }
  # Failed requests by kind, with the first and last second each was seen (to set them against the rollout's times).
  grep 'msg="Request Failed"' "$work/$1.log" | sed -E 's/^time="([^"]*)".*error="(.*)"$/\1 \2/; s/[0-9]+(\.[0-9]+){3}(:[0-9]+)?/IP/g' \
    | awk -v name="$1" '{ t = $1; $1 = ""; k = $0; n[k]++; if (!(k in f)) f[k] = t; l[k] = t }
           END { for (k in n) printf "k6 %s: %d failed, %s to %s:%s\n", name, n[k], f[k], l[k], k }' \
    || true
  cat "$work/$1.json"
}
# requests failed dropped p95 p99 of a k6 summary, 0 for a missing figure (no request recorded).
k6_figures() { jq -r '"\(.requests // 0) \(.failed // 0) \(.dropped // 0) \(.p95 // 0) \(.p99 // 0)"' "$work/$1.json"; }
server_pods() { kubectl -n $NS get pods -l app.kubernetes.io/component=server -o json; }

# Best effort: a slow API server (the node is saturated) must not end the catcher, so no -e/pipefail in it.
( set +e +o pipefail; touch "$work/crashes.txt"
  while [ ! -e "$work/stop-catcher" ]; do
    kubectl -n $NS get pods -l app.kubernetes.io/component=server -o json 2>/dev/null | jq -r '.items[] | .metadata.name as $p
      | .status.containerStatuses[]? | select(.restartCount > 0) | "\($p) \(.name) \(.restartCount)"' 2>/dev/null \
    | while read -r pod c n; do
        grep -q "^== $pod $c restart $n " "$work/crashes.txt" && continue
        { echo "== $pod $c restart $n $(date -u +%H:%M:%S)"
          kubectl -n $NS get pod "$pod" -o json | jq -c --arg c "$c" '.status.containerStatuses[] | select(.name == $c) | .lastState.terminated
            | {reason, exitCode, signal, startedAt, finishedAt}' 2>/dev/null || true
          kubectl -n $NS logs "$pod" -c "$c" --previous --tail=60 2>&1 || true
        } >> "$work/crashes.txt"
      done
    sleep 3
  done ) &
catcher=$!

echo "== 1. A peak from two replicas: the HPA must follow"
kubectl -n $NS wait hpa/$REL-server --for=jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' \
  --timeout 3m >/dev/null 2>&1 || echo "::warning::the HPA had no CPU metric yet before the peak"
# One sample every 5 s: seconds since the start, desired and current replicas, ready server pods.
peak_start=$(date +%s)
echo "peak starts at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
# A sample is written only when both reads succeed, with 0 for a missing field: four columns, always.
( while [ ! -e "$work/stop" ]; do
    h=$(kubectl -n $NS get hpa $REL-server -o json 2>/dev/null \
      | jq -r '"\(.status.desiredReplicas // 0) \(.status.currentReplicas // 0)"' 2>/dev/null || true)
    r=$(kubectl -n $NS get pods -l app.kubernetes.io/component=server -o json 2>/dev/null \
      | jq '[.items[] | select(.metadata.deletionTimestamp == null and any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' 2>/dev/null || true)
    [ -z "$h" ] || [ -z "$r" ] || echo "$(( $(date +%s) - peak_start )) $h $r"
    sleep 5
  done ) > "$work/hpa.log" 2>/dev/null &
sampler=$!
k6_job k6-peak peak "$PEAK_RATE" "${PEAK_HOLD}s"
k6_result k6-peak $(( PEAK_RAMP + PEAK_HOLD + 180 ))
stop_sampler
cat "$work/hpa.log"
read -r requests failed dropped p95 p99 < <(k6_figures k6-peak)
expected=$(( (10 + PEAK_RATE) * PEAK_RAMP / 2 + PEAK_RATE * PEAK_HOLD ))
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
[ "$requests" -ge $(( expected * 95 / 100 )) ] || fail "only $requests of the $expected requests of the peak were sent ($dropped dropped by k6)"
[ "$peak_restarts" = 0 ] || fail "$peak_restarts container restarts during the peak (OOM or a probe gave up)"
echo "peak: the HPA went to $max_desired replicas ($max_ready ready), $requests requests, none failed"

echo "== 2. A version rollout under steady load (the HPA may move meanwhile)"
before=$(server_pods | jq -r '[.items[].metadata.name] | sort | join(" ")')
k6_job k6-rollout steady "$ROLLOUT_RATE" "${ROLLOUT_LOAD}s"
sleep "$ROLLOUT_LEAD"
# A crash between the peak and the upgrade is not the rollout's: say so before the upgrade starts.
pre_restarts=$(server_pods | jq '[.items[].status.containerStatuses[]?.restartCount] | add // 0')
[ "$pre_restarts" = 0 ] || fail "$pre_restarts container restarts after the peak, before the rollout began"
start=$(date +%s)
echo "rollout starts at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
helm upgrade $REL charts/ostrom -n $NS "${real[@]}" --set-string server.podAnnotations.drill-rollout=2 \
  --wait --timeout 5m || fail "the upgrade under load"
kubectl -n $NS rollout status deploy/$REL-server --timeout 5m || fail "the rollout under load"
rolled=$(( $(date +%s) - start ))
echo "rollout ends at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
k6_result k6-rollout $(( ROLLOUT_LOAD + 120 ))
server_pods > "$work/after.json"
after=$(jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name] | sort | join(" ")' "$work/after.json")
for p in $before; do case " $after " in *" $p "*) fail "pod $p was not replaced by the upgrade" ;; esac; done
restarts=$(jq '[.items[].status.containerStatuses[]?.restartCount] | add // 0' "$work/after.json")
read -r requests failed dropped p95 p99 < <(k6_figures k6-rollout)
{
  printf '| rollout at %s req/s | %s | %s | %s | %.1f | %.1f | rollout %s s, %s restarts |\n' \
    "$ROLLOUT_RATE" "$requests" "$failed" "$dropped" "$p95" "$p99" "$rolled" "$restarts"
  echo
} >> "$SUMMARY"
[ "$failed" = 0 ] || fail "$failed requests failed during the rollout"
[ "$requests" -ge $(( ROLLOUT_RATE * ROLLOUT_LOAD * 95 / 100 )) ] || fail "only $requests requests sent during the rollout ($dropped dropped by k6)"
[ "$restarts" = 0 ] || fail "$restarts container restarts during the rollout (a probe gave up)"
[ "$rolled" -le $(( ROLLOUT_LOAD - ROLLOUT_LEAD - ROLLOUT_TAIL )) ] \
  || fail "the rollout took ${rolled}s: it did not end ${ROLLOUT_TAIL}s before the load (${ROLLOUT_LOAD}s, started after ${ROLLOUT_LEAD}s)"
echo "rollout under load: $requests requests, none failed, every pod replaced in ${rolled}s"

stop_catcher
helm uninstall $REL -n $NS --wait
kubectl delete namespace $NS --wait=false
echo "scale drill: ok"
