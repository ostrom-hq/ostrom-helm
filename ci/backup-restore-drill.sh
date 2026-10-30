#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Restore drill of docs/backup-restore.md, on kind, with the commands of that page: install, write data, back up with
# the chart's CronJob, copy the backups and the secrets off the cluster, then restore everything into a fresh
# namespace and check that the data, the roles and the keys came back. Any step of the page that does not work
# fails this script, so the page stays true.
# Usage: ci/backup-restore-drill.sh   (needs kubectl on a cluster, helm, yq; the chart's stand-in values)
set -euo pipefail
cd "$(dirname "$0")/.."

REL=ostrom
A=ostrom-drill-a
B=ostrom-drill-b
POD=$REL-postgresql-0
work=$(mktemp -d)
values=(-f charts/ostrom/ci/standin-values.yaml --set ingress.enabled=false --set tests.enabled=true)

fail() { echo "FAIL: $*" >&2; for ns in $A $B; do kubectl get all,pvc,secrets -n "$ns" -o wide >&2 || true; done; exit 1; }
psql_in() { kubectl -n "$1" exec "$POD" -- psql -U postgres -v ON_ERROR_STOP=1 -Atc "$3" -d "$2"; }
restricted_ns() {
  kubectl create namespace "$1"
  kubectl label namespace "$1" pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest
}

echo "== 1. An instance with data, in namespace $A"
restricted_ns $A
helm install $REL charts/ostrom -n $A "${values[@]}" --wait --timeout 10m
# The backup PVC binds on first use (WaitForFirstConsumer): backups are turned on by an upgrade (the page says so).
helm upgrade $REL charts/ostrom -n $A "${values[@]}" --set postgresql.backup.enabled=true --timeout 10m
# Data written by the owner, the way migrations write; RLS-free on purpose: the drill checks the bytes come back.
psql_in $A ostrom "SET ROLE ostrom; CREATE TABLE drill_marker (id int PRIMARY KEY, note text); INSERT INTO drill_marker VALUES (42, 'before the disaster');"
psql_in $A polis "SET ROLE polis; CREATE TABLE drill_polis (x int); INSERT INTO drill_polis VALUES (7);"
signing_a=$(kubectl -n $A get secret $REL-signing-key -o jsonpath='{.data}' | sha256sum)
secrets_a=$(kubectl -n $A get secret $REL-secrets-key -o jsonpath='{.data}' | sha256sum)

echo "== 2. Backup now (the page's commands)"
NS=$A
kubectl -n $NS create job --from=cronjob/$REL-postgresql-backup backup-now
kubectl -n $NS wait --for=condition=complete job/backup-now --timeout=10m || fail "backup job"
kubectl -n $NS run backup-copy --restart=Never --image=busybox:1.37 \
  --overrides='{"spec":{"securityContext":{"runAsUser":999,"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"busybox:1.37","command":["sleep","3600"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"volumeMounts":[{"name":"b","mountPath":"/b","readOnly":true}]}],"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"'$REL'-postgresql-backup","readOnly":true}}]}}'
kubectl -n $NS wait --for=condition=Ready pod/backup-copy --timeout=5m || fail "backup copy pod"
kubectl -n $NS exec backup-copy -- tar czf - -C /b . > "$work/ostrom-backups.tgz" || fail "copy of the backups off the cluster"
kubectl -n $NS delete pod backup-copy --wait=false
mkdir -p "$work/backups" && tar xzf "$work/ostrom-backups.tgz" -C "$work/backups"
run=$(find "$work/backups" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)
ls -la "$run"
for f in ostrom.dump polis.dump globals.sql; do [ -s "$run/$f" ] || fail "no $f in the backup"; done

echo "== 3. Keys and secrets (the page's command)"
kubectl -n $NS get secret $REL-signing-key $REL-secrets-key $REL-postgresql $REL-polis -o yaml > "$work/ostrom-secrets.yaml"

echo "== 4. Disaster: namespace $A is gone"
helm uninstall $REL -n $A --wait
kubectl delete namespace $A --wait=true --timeout=5m

echo "== 5. Restore into the fresh namespace $B (the page's steps)"
restricted_ns $B
# Step 1: the Secrets first, stripped as the page says, then the same release name.
NS=$B yq 'del(.items[].metadata.resourceVersion, .items[].metadata.uid, .items[].metadata.creationTimestamp, .items[].metadata.namespace)
    | .items[].metadata.annotations["meta.helm.sh/release-namespace"] = strenv(NS)' "$work/ostrom-secrets.yaml" \
  | kubectl -n $B apply -f - || fail "applying the secrets"
helm install $REL charts/ostrom -n $B "${values[@]}" --wait --timeout 10m || fail "install over the restored secrets"
# Step 2: stop the writers; PostgreSQL stays up.
kubectl -n $B scale deploy -l app.kubernetes.io/instance=$REL --replicas=0
# Step 3: each database.
kubectl -n $B cp "$run/ostrom.dump" $POD:/tmp/ostrom.dump
kubectl -n $B exec $POD -- pg_restore -U postgres -d ostrom --clean --if-exists --no-owner --role=ostrom /tmp/ostrom.dump
kubectl -n $B cp "$run/polis.dump" $POD:/tmp/polis.dump
kubectl -n $B exec $POD -- pg_restore -U postgres -d polis --clean --if-exists --no-owner --role=polis /tmp/polis.dump
# Step 4: scale back up, then the chart's tests.
helm upgrade $REL charts/ostrom -n $B --reuse-values --wait --timeout 10m
helm test $REL -n $B --timeout 5m || fail "helm test after the restore"

echo "== 6. Checks"
[ "$(psql_in $B ostrom "SELECT note FROM drill_marker WHERE id = 42")" = "before the disaster" ] || fail "ostrom data not restored"
[ "$(psql_in $B ostrom "SELECT tableowner FROM pg_tables WHERE tablename = 'drill_marker'")" = ostrom ] || fail "restored table not owned by the owner"
[ "$(psql_in $B polis "SELECT x FROM drill_polis")" = 7 ] || fail "polis data not restored"
[ "$(kubectl -n $B get secret $REL-signing-key -o jsonpath='{.data}' | sha256sum)" = "$signing_a" ] || fail "signing key changed"
[ "$(kubectl -n $B get secret $REL-secrets-key -o jsonpath='{.data}' | sha256sum)" = "$secrets_a" ] || fail "secrets key changed"
# The serving role still cannot bypass row-level security after a restore.
[ "$(psql_in $B ostrom "SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = 'ostrom_app'")" = f ] || fail "serving role too strong"

helm uninstall $REL -n $B --wait
kubectl delete namespace $B --wait=false
echo "restore drill: ok"
