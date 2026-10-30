#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Plays docs/secret-rotation.md on kind with the page's own commands: rotates the four PostgreSQL passwords
# (role first, then the Secret, then the restart) and the instance signing key. It then checks that the chart's
# tests pass with the new passwords, the old serving-role password is refused, and the next `helm upgrade` keeps
# the new key.
# Usage: ci/secret-rotation-drill.sh   (needs kubectl on a cluster, helm, openssl; the chart's stand-in values)
set -euo pipefail
cd "$(dirname "$0")/.."

REL=ostrom
NS=ostrom-rotation
POD=$REL-postgresql-0
values=(-f charts/ostrom/ci/standin-values.yaml --set ingress.enabled=false)

fail() { echo "FAIL: $*" >&2; kubectl get all,secrets -n $NS -o wide >&2 || true; exit 1; }
secret_key() { kubectl -n $NS get secret "$1" -o jsonpath="{.data.$2}" | base64 -d; }

kubectl create namespace $NS
kubectl label namespace $NS pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest
helm install $REL charts/ostrom -n $NS "${values[@]}" --wait --timeout 10m

echo "== PostgreSQL passwords: role, then Secret, then restart (the page's commands)"
old_app=$(secret_key $REL-postgresql password)
for pair in password:ostrom_app owner-password:ostrom polis-password:polis postgres-password:postgres; do
  key=${pair%%:*}
  role=${pair#*:}
  NEW=$(openssl rand -hex 24)
  kubectl -n $NS exec -i $POD -- psql -U postgres -v ON_ERROR_STOP=1 -v pw="$NEW" <<SQL
ALTER ROLE $role PASSWORD :'pw';
SQL
  kubectl -n $NS patch secret $REL-postgresql --type merge -p "{\"stringData\":{\"$key\":\"$NEW\"}}"
done
kubectl -n $NS rollout restart deploy/$REL-server deploy/$REL-polis
kubectl -n $NS rollout status deploy/$REL-server --timeout 5m
kubectl -n $NS rollout status deploy/$REL-polis --timeout 5m
# Over TCP the pod asks for the password (scram), as it does for the server.
if kubectl -n $NS exec $POD -- env PGPASSWORD="$old_app" psql -h 127.0.0.1 -U ostrom_app -d ostrom -Atc "SELECT 1" 2>/dev/null; then
  fail "the old serving-role password still works"
fi

echo "== Instance signing key (the page's commands)"
work=$(mktemp -d)
openssl genpkey -algorithm ed25519 -out "$work/instance-key.pem"
kubectl -n $NS create secret generic $REL-signing-key --from-file=instance-key.pem="$work/instance-key.pem" \
  --dry-run=client -o yaml | kubectl -n $NS apply -f -
kubectl -n $NS rollout restart deploy/$REL-server
kubectl -n $NS rollout status deploy/$REL-server --timeout 5m
want=$(sha256sum < "$work/instance-key.pem")

echo "== The next upgrade keeps everything, and the chart's tests pass"
helm upgrade $REL charts/ostrom -n $NS "${values[@]}" --wait --timeout 10m || fail "upgrade after the rotation"
[ "$(secret_key $REL-signing-key 'instance-key\.pem' | sha256sum)" = "$want" ] || fail "helm upgrade replaced the rotated signing key"
helm test $REL -n $NS --timeout 5m || fail "helm test with the rotated passwords"

helm uninstall $REL -n $NS --wait
kubectl delete namespace $NS --wait=false
echo "secret rotation drill: ok"
