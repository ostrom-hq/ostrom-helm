#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# The real `ostrom-server migrate` against the chart's database roles, on kind (image built from ostrom-server main
# and loaded as $SERVER_IMAGE):
#   A. install (first migration), then upgrade and restart (second migration: a no-op that must still pass);
#   B. a database where ostrom_router already exists but the owner does not administer it (created by another
#      tool, or by an older chart): the pre-upgrade roles Job must give the owner ADMIN on it before the server's
#      orgs migration hands its functions over (GRANT ostrom_router TO CURRENT_USER, ALTER FUNCTION … OWNER).
# Each scenario ends with the cross-organization functions owned by ostrom_router and the chart's tests passing.
# Usage: SERVER_IMAGE=ostrom-server:chart-ci ci/migrate-drill.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SERVER_IMAGE:?SERVER_IMAGE (repository:tag of the loaded server image) is required}"
REL=ostrom
POD=$REL-postgresql-0
real=(-f charts/ostrom/ci/standin-values.yaml --set ingress.enabled=false --set polis.enabled=false
      --set server.image.repository="${SERVER_IMAGE%:*}" --set server.image.tag="${SERVER_IMAGE##*:}"
      --set-json 'server.args=[]' --set migrations.initContainer=true)

fail() { echo "FAIL: $*" >&2; kubectl get all,jobs -n "$NS" -o wide >&2 || true
  for p in $(kubectl get pods -n "$NS" -o name); do kubectl logs -n "$NS" "$p" --all-containers --tail=40 >&2 || true; done; exit 1; }
psql_su() { kubectl -n "$NS" exec -i $POD -- psql -U postgres -d ostrom -v ON_ERROR_STOP=1 -Atc "$1"; }
restricted_ns() {
  kubectl create namespace "$1"
  kubectl label namespace "$1" pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest
}
migrated() {
  # Every server pod's init container ran `migrate` and exited 0.
  for p in $(kubectl -n "$NS" get pods -l app.kubernetes.io/component=server -o name); do
    [ "$(kubectl -n "$NS" get "$p" -o jsonpath='{.status.initContainerStatuses[?(@.name=="migrate")].state.terminated.exitCode}')" = 0 ] \
      || fail "$p: migrate did not exit 0"
    kubectl -n "$NS" logs "$p" -c migrate --tail=5
  done
  [ "$(psql_su "SELECT count(*) FROM pg_proc WHERE proname LIKE 'orgs\_%' AND pg_get_userbyid(proowner) <> 'ostrom_router' AND prosecdef")" = 0 ] \
    || fail "a SECURITY DEFINER function of orgs is not owned by ostrom_router"
  [ "$(psql_su "SELECT count(*) FROM pg_proc WHERE proname = 'orgs_create_organization' AND pg_get_userbyid(proowner) = 'ostrom_router'")" = 1 ] \
    || fail "orgs_create_organization missing or not owned by ostrom_router"
  helm test $REL -n "$NS" --timeout 5m || fail "helm test"
}

echo "== A. Migrate on install, then again after an upgrade"
NS=ostrom-migrate-a
restricted_ns $NS
helm install $REL charts/ostrom -n $NS "${real[@]}" --wait --timeout 10m || fail "install with the real server"
migrated
helm upgrade $REL charts/ostrom -n $NS "${real[@]}" --wait --timeout 10m || fail "upgrade"
kubectl -n $NS rollout restart deploy/$REL-server
kubectl -n $NS rollout status deploy/$REL-server --timeout 5m || fail "second migration"
migrated
helm uninstall $REL -n $NS --wait
kubectl delete namespace $NS --wait=false

echo "== B. ostrom_router already there, not administered by the owner"
NS=ostrom-migrate-b
restricted_ns $NS
helm install $REL charts/ostrom -n $NS "${real[@]}" --set server.enabled=false --wait --timeout 10m || fail "database only"
psql_su "REVOKE ostrom_router FROM ostrom" >/dev/null
[ "$(psql_su "SELECT count(*) FROM pg_auth_members WHERE roleid = 'ostrom_router'::regrole AND member = 'ostrom'::regrole")" = 0 ] \
  || fail "the setup did not remove the owner's membership"
helm upgrade $REL charts/ostrom -n $NS "${real[@]}" --wait --timeout 10m || fail "upgrade over the pre-existing role"
[ "$(psql_su "SELECT bool_or(admin_option) FROM pg_auth_members WHERE roleid = 'ostrom_router'::regrole AND member = 'ostrom'::regrole")" = t ] \
  || fail "the roles Job did not give the owner ADMIN on ostrom_router"
migrated
helm uninstall $REL -n $NS --wait
kubectl delete namespace $NS --wait=false
echo "migrate drill: ok"
