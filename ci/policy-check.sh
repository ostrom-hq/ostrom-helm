#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# The pods the chart renders hold the Pod Security Standard `restricted` and the chart's own rules
# (ci/policies/restricted.yaml: read-only root, requests and a memory limit, no moving tag, no Kubernetes token),
# on every value set given. Blocking: one failure fails the run (AUDIT-SECU-HELM-2 M6).
# Usage: ci/policy-check.sh <name> [helm template flags…]   (needs helm, yq v4 and kyverno on PATH or in $KYVERNO)
set -euo pipefail
cd "$(dirname "$0")/.."

name=$1; shift
kyverno=${KYVERNO:-kyverno}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

helm template o charts/ostrom -n ostrom "$@" > "$work/render.yaml"
# Each controller as the Pod it creates (name kind-name, the template's labels and spec), plus the Pods themselves.
# shellcheck disable=SC2016 # $cron, $tpl and $pod are yq variables, not shell ones.
yq '
  select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "Job" or .kind == "CronJob" or .kind == "Pod")
  | (select(.kind == "CronJob") | .spec.jobTemplate.spec.template) as $cron
  | (select(.kind != "CronJob" and .kind != "Pod") | .spec.template) as $tpl
  | ($cron // $tpl // .) as $pod
  | {"apiVersion": "v1", "kind": "Pod",
     "metadata": {"name": ((.kind | downcase) + "-" + .metadata.name), "namespace": "ostrom",
                  "labels": ($pod.metadata.labels // .metadata.labels)},
     "spec": $pod.spec}
' "$work/render.yaml" > "$work/pods.yaml"
count=$(yq '.metadata.name' "$work/pods.yaml" | grep -cv '^---$' || true)
[ "$count" -gt 0 ] || { echo "::error::[$name] no pod rendered"; exit 1; }
echo "[$name] $count pods: $(yq '.metadata.name' "$work/pods.yaml" | grep -v '^---$' | tr '\n' ' ')"
if ! "$kyverno" apply ci/policies/restricted.yaml --resource "$work/pods.yaml" 2> "$work/err" > "$work/out"; then
  grep -v '^Warning' "$work/err" || true
  cat "$work/out"
  echo "::error::[$name] a pod breaks the restricted policy"
  exit 1
fi
grep -E '^pass:' "$work/out" || cat "$work/out"
