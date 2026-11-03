#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# The real `ostrom-server migrate` against the chart's database roles, on kind (image built from ostrom-server main
# and loaded as $SERVER_IMAGE):
#   A. install (first migration), then upgrade and restart (second migration: a no-op that must still pass); before
#      the upgrade, a history planted writable (as an older server left it, plus ostrom_tenant, PUBLIC and a column
#      grant) that no migration touches: the pre-upgrade roles Job alone must lock it (AUDIT-RLS R8);
#   B. a database where ostrom_router already exists but the owner does not administer it (created by another
#      tool, or by an older chart): the pre-upgrade roles Job must give the owner ADMIN on it before the server's
#      orgs migration hands its functions over (GRANT ostrom_router TO CURRENT_USER, ALTER FUNCTION … OWNER).
#   C. an external PostgreSQL that accepts TLS only (`hostssl`, its certificate signed by a CA of the test):
#      with externalDatabase.tls the server migrates and serves (/ready) through the proxy sidecar, over TLS;
#      without it, the JVM server's driver (pgjdbc, `sslmode=prefer` by default) still encrypts, unverified, and no
#      connection is in clear (AUDIT-SECU-HELM-2 H1).
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
histories="relkind = 'r' AND relnamespace = 'public'::regnamespace AND relname LIKE 'flyway\_%'"
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
  # The member search's function has its own owner (ostrom-server orgs migration 7, docs/tenancy.md).
  [ "$(psql_su "SELECT count(*) FROM pg_proc WHERE proname LIKE 'orgs\_%' AND prosecdef AND pg_get_userbyid(proowner) <> CASE proname WHEN 'orgs_search_members' THEN 'ostrom_member_search' ELSE 'ostrom_router' END")" = 0 ] \
    || fail "a SECURITY DEFINER function of orgs is not owned by ostrom_router (ostrom_member_search for the member search)"
  [ "$(psql_su "SELECT count(*) FROM pg_proc WHERE proname = 'orgs_create_organization' AND pg_get_userbyid(proowner) = 'ostrom_router'")" = 1 ] \
    || fail "orgs_create_organization missing or not owned by ostrom_router"
  # AUDIT-RLS R8: histories exist, ostrom_app reads them, and no role but the owner writes one.
  [ "$(psql_su "SELECT count(*) FROM pg_class WHERE $histories")" -gt 0 ] || fail "no migrations' history"
  [ "$(psql_su "SELECT count(*) FROM pg_class WHERE $histories AND NOT has_table_privilege('ostrom_app', oid, 'SELECT')")" = 0 ] \
    || fail "ostrom_app cannot read a migrations' history"
  writable=$(psql_su "SELECT string_agg(relname || ':' || r, ' ') FROM pg_class, unnest(ARRAY['ostrom_app', 'ostrom_tenant', 'public']) r
    WHERE $histories AND (has_table_privilege(r, oid, 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
      OR has_any_column_privilege(r, oid, 'INSERT, UPDATE, REFERENCES'))")
  [ -z "$writable" ] || fail "a migrations' history is writable: $writable"
  helm test $REL -n "$NS" --timeout 5m || fail "helm test"
}

echo "== A. Migrate on install, then again after an upgrade"
NS=ostrom-migrate-a
restricted_ns $NS
helm install $REL charts/ostrom -n $NS "${real[@]}" --wait --timeout 10m || fail "install with the real server"
migrated
# A history no migration touches, writable as an older server left it (the owner's default privileges), and more.
psql_su "SET ROLE ostrom; CREATE TABLE flyway_legacy (version int, checksum text); RESET ROLE;
  GRANT INSERT ON flyway_legacy TO ostrom_tenant; GRANT UPDATE (checksum) ON flyway_legacy TO PUBLIC" >/dev/null
[ "$(psql_su "SELECT has_table_privilege('ostrom_app', 'flyway_legacy', 'INSERT')")" = t ] || fail "the planted history is not writable"
helm upgrade $REL charts/ostrom -n $NS "${real[@]}" --wait --timeout 10m || fail "upgrade"
[ "$(psql_su "SELECT has_table_privilege('ostrom_app', 'flyway_legacy', 'SELECT')")" = t ] || fail "the roles Job took the read away"
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
echo "== C. External PostgreSQL that accepts TLS only"
NS=ostrom-migrate-c
restricted_ns $NS
tls=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=drill-ca" -keyout "$tls/ca.key" -out "$tls/ca.crt" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=pg-tls" -keyout "$tls/tls.key" -out "$tls/tls.csr" 2>/dev/null
printf 'subjectAltName=DNS:pg-tls,DNS:pg-tls.%s.svc,DNS:pg-tls.%s.svc.cluster.local\n' $NS $NS > "$tls/ext"
openssl x509 -req -in "$tls/tls.csr" -CA "$tls/ca.crt" -CAkey "$tls/ca.key" -CAcreateserial -days 1 \
  -extfile "$tls/ext" -out "$tls/tls.crt" 2>/dev/null
kubectl -n $NS create secret generic pg-tls-cert --from-file="$tls/tls.crt" --from-file="$tls/tls.key"
kubectl -n $NS create secret generic pg-tls-ca --from-file=ca.crt="$tls/ca.crt"
rm -rf "$tls"
kubectl -n $NS apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata: { name: pg-tls }
data:
  pg_hba.conf: |
    local all all trust
    hostssl all all all scram-sha-256
    hostnossl all all all reject
  10-roles.sql: |
    CREATE ROLE ostrom_owner LOGIN NOSUPERUSER NOCREATEDB CREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD 'owner_pw';
    CREATE ROLE ostrom_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD 'app_pw';
    CREATE ROLE ostrom_tenant NOLOGIN NOSUPERUSER NOBYPASSRLS;
    GRANT ostrom_tenant TO ostrom_owner WITH ADMIN OPTION;
    GRANT ostrom_tenant TO ostrom_app;
    CREATE ROLE ostrom_router NOLOGIN NOSUPERUSER NOBYPASSRLS;
    GRANT ostrom_router TO ostrom_owner WITH ADMIN OPTION;
    CREATE ROLE ostrom_member_search NOLOGIN NOSUPERUSER NOBYPASSRLS;
    GRANT ostrom_member_search TO ostrom_owner WITH ADMIN OPTION;
    -- The server's session settings, which the TLS proxy drops (docs/install-kubernetes.md).
    ALTER ROLE ostrom_app SET statement_timeout = '10s';
    ALTER ROLE ostrom_app SET lock_timeout = '5s';
    ALTER ROLE ostrom_app SET idle_in_transaction_session_timeout = '15s';
    ALTER ROLE ostrom_owner SET lock_timeout = '3s';
    CREATE DATABASE ostrom OWNER ostrom_owner;
    \connect ostrom
    ALTER SCHEMA public OWNER TO ostrom_owner;
    REVOKE ALL ON SCHEMA public FROM PUBLIC;
    GRANT USAGE ON SCHEMA public TO ostrom_app, ostrom_tenant;
    ALTER DEFAULT PRIVILEGES FOR ROLE ostrom_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ostrom_app;
    ALTER DEFAULT PRIVILEGES FOR ROLE ostrom_owner IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO ostrom_app;
    ALTER DEFAULT PRIVILEGES FOR ROLE ostrom_owner IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO ostrom_app;
---
apiVersion: v1
kind: Pod
metadata: { name: pg-tls, labels: { app: pg-tls } }
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 999
    runAsGroup: 999
    fsGroup: 999
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: postgres
      image: docker.io/library/postgres:17.6@sha256:00bc86618629af00d2937fdc5a5d63db3ff8450acf52f0636ec813c7f4902929
      args: ["-c", "ssl=on", "-c", "ssl_cert_file=/tls/tls.crt", "-c", "ssl_key_file=/tls/tls.key",
             "-c", "hba_file=/etc/pg/pg_hba.conf", "-c", "log_connections=on"]
      env:
        - { name: POSTGRES_PASSWORD, value: drill-superuser }
        - { name: PGDATA, value: /var/lib/postgresql/data/pgdata }
      ports: [{ containerPort: 5432 }]
      readinessProbe:
        exec: { command: ["pg_isready", "-h", "127.0.0.1", "-U", "postgres"] }
        periodSeconds: 2
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: [ALL] }
      resources:
        requests: { cpu: 50m, memory: 128Mi }
        limits: { memory: 512Mi }
      volumeMounts:
        - { name: data, mountPath: /var/lib/postgresql/data }
        - { name: run, mountPath: /var/run/postgresql }
        - { name: init, mountPath: /docker-entrypoint-initdb.d/10-roles.sql, subPath: 10-roles.sql }
        - { name: hba, mountPath: /etc/pg }
        - { name: cert, mountPath: /tls }
  volumes:
    - { name: data, emptyDir: {} }
    - { name: run, emptyDir: {} }
    - { name: init, configMap: { name: pg-tls } }
    - { name: hba, configMap: { name: pg-tls, items: [{ key: pg_hba.conf, path: pg_hba.conf }] } }
    # Owned by root, group postgres (fsGroup), 0640: what PostgreSQL accepts for a key it does not own.
    - { name: cert, secret: { secretName: pg-tls-cert, defaultMode: 0640 } }
---
apiVersion: v1
kind: Service
metadata: { name: pg-tls }
spec:
  selector: { app: pg-tls }
  ports: [{ port: 5432 }]
YAML
kubectl -n $NS wait --for=condition=Ready pod/pg-tls --timeout=180s || fail "the TLS-only PostgreSQL did not start"
pg_tls() { kubectl -n $NS exec pg-tls -- psql -U postgres -d ostrom -v ON_ERROR_STOP=1 -Atc "$1"; }
external=(--set postgresql.enabled=false
  --set "externalDatabase.url=postgresql://pg-tls.$NS.svc.cluster.local:5432/ostrom"
  --set externalDatabase.username=ostrom_app --set externalDatabase.password=app_pw
  --set externalDatabase.migrationUsername=ostrom_owner --set externalDatabase.migrationPassword=owner_pw
  --set-json 'networkPolicy.server.extraEgress=[{"to":[{"podSelector":{"matchLabels":{"app":"pg-tls"}}}],"ports":[{"protocol":"TCP","port":5432}]}]')
echo "-- C1. without externalDatabase.tls: pgjdbc's default sslmode=prefer encrypts (the certificate unverified)"
helm install $REL charts/ostrom -n $NS "${real[@]}" "${external[@]}" --wait --timeout 10m \
  || fail "install without the proxy against a TLS-only PostgreSQL"
[ "$(pg_tls "SELECT count(*) FROM pg_stat_activity a JOIN pg_stat_ssl s USING (pid) WHERE a.usename = 'ostrom_app' AND s.ssl")" -gt 0 ] \
  || fail "no TLS connection of the serving role without the proxy"
[ "$(pg_tls "SELECT count(*) FROM pg_stat_activity a JOIN pg_stat_ssl s USING (pid) WHERE a.usename = 'ostrom_app' AND NOT s.ssl")" = 0 ] \
  || fail "a plain connection of the serving role without the proxy"
echo "encrypted without the proxy, unverified: externalDatabase.tls is what checks the certificate"
helm uninstall $REL -n $NS --wait
echo "-- C2. with externalDatabase.tls (verify-full, the test CA): migrates and serves"
helm install $REL charts/ostrom -n $NS "${real[@]}" "${external[@]}" \
  --set externalDatabase.tls.enabled=true --set externalDatabase.tls.ca.secretName=pg-tls-ca \
  --wait --timeout 10m || fail "install through the TLS proxy"
kubectl -n $NS rollout status deploy/$REL-server --timeout 5m || fail "the server is not ready (/ready) through the proxy"
[ "$(pg_tls "SELECT count(*) FROM pg_class WHERE $histories")" -gt 0 ] || fail "no migration through the proxy"
[ "$(pg_tls "SELECT count(*) FROM pg_stat_activity a JOIN pg_stat_ssl s USING (pid) WHERE a.usename = 'ostrom_app' AND s.ssl")" -gt 0 ] \
  || fail "no TLS connection of the serving role"
[ "$(pg_tls "SELECT count(*) FROM pg_stat_activity a JOIN pg_stat_ssl s USING (pid) WHERE a.usename = 'ostrom_app' AND NOT s.ssl")" = 0 ] \
  || fail "a plain connection of the serving role"
helm test $REL -n "$NS" --timeout 5m || fail "helm test through the proxy"
helm uninstall $REL -n $NS --wait
kubectl delete namespace $NS --wait=false
echo "migrate drill: ok"
