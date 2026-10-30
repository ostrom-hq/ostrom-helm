# Backup and restore

Names below assume the release is called `ostrom` (objects are then `ostrom-…`; another release name `x` gives
`x-ostrom-…`).

Three things hold the state of an Ostrom instance:

1. **PostgreSQL** — databases `ostrom` and `polis`;
2. **the instance signing key** — Secret `<release>-signing-key` (Kubernetes) or the `server-data` volume,
   file `instance-key.pem` (Compose). Every receipt is verified with it: losing it means old receipts can no longer
   be checked against this instance's key;
3. **the generated secrets** — Secrets `<release>-postgresql` and `<release>-polis` (Kubernetes) or `.env`
   (Compose). `db-encryption-key` of Polis decrypts the SSO connections stored in its database.

## Kubernetes

### Automatic logical backups

```yaml
postgresql:
  backup: { enabled: true, schedule: "17 3 * * *", keep: 14, persistence: { size: 20Gi } }
```

A CronJob dumps every database (`pg_dump -Fc`) and the roles (`pg_dumpall --globals-only`) to the PVC
`<release>-postgresql-backup` (kept on uninstall), in a folder per run, and deletes runs older than `keep` days.
With a StorageClass in `WaitForFirstConsumer` mode (kind, many clouds), the backup PVC stays `Pending` until the
first backup runs, and `helm install --wait` waits for it: run the first backup right after installing
(`kubectl create job --from=cronjob/…`, below), or enable backups in a second `helm upgrade`.

Copy them off the cluster too (the PVC lives in the same failure domain):

```sh
NS=ostrom; REL=ostrom
kubectl -n $NS create job --from=cronjob/$REL-postgresql-backup backup-now
kubectl -n $NS wait --for=condition=complete job/backup-now --timeout=10m
kubectl -n $NS run backup-copy --rm -i --restart=Never --image=busybox:1.37 \
  --overrides='{"spec":{"securityContext":{"runAsUser":999,"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"busybox:1.37","command":["tar","czf","-","-C","/b","."],"stdin":true,"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"volumeMounts":[{"name":"b","mountPath":"/b"}]}],"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"'$REL'-postgresql-backup"}}]}}' \
  > ostrom-backups-$(date +%F).tgz
```

### Keys and secrets

```sh
kubectl -n ostrom get secret ostrom-signing-key ostrom-postgresql ostrom-polis -o yaml > ostrom-secrets.yaml
```

Store that file encrypted (age, sops, a password manager): it contains the keys.

### Restore

1. Fresh namespace: apply `ostrom-secrets.yaml` first (strip `resourceVersion`, `uid`, `creationTimestamp`), then
   `helm install` with the same release name: the chart reuses the existing Secrets.
2. Stop writers: `kubectl -n ostrom scale deploy -l app.kubernetes.io/instance=ostrom --replicas=0`
   (the PostgreSQL StatefulSet stays up).
3. Restore each database:

```sh
POD=ostrom-postgresql-0
kubectl -n ostrom cp ./2026-10-30/ostrom.dump $POD:/tmp/ostrom.dump
kubectl -n ostrom exec $POD -- pg_restore -U postgres -d ostrom --clean --if-exists --no-owner --role=ostrom /tmp/ostrom.dump
kubectl -n ostrom cp ./2026-10-30/polis.dump $POD:/tmp/polis.dump
kubectl -n ostrom exec $POD -- pg_restore -U postgres -d polis --clean --if-exists --no-owner --role=polis /tmp/polis.dump
```

4. `helm upgrade ostrom … --reuse-values` (scales back up), then `helm test ostrom -n ostrom`.

Restore test: CI restores nothing yet; do a restore drill into a scratch namespace once per quarter.

## Docker Compose

```sh
cd compose
docker compose exec -T postgres pg_dump -U postgres -Fc ostrom > ostrom-$(date +%F).dump
docker compose exec -T postgres pg_dump -U postgres -Fc polis  > polis-$(date +%F).dump
docker compose cp server:/var/lib/ostrom/instance-key.pem ./instance-key.pem   # keep with .env, encrypted
cp .env env-backup
```

Restore: `docker compose up -d postgres`, then
`docker compose exec -T postgres pg_restore -U postgres -d ostrom --clean --if-exists --no-owner --role=ostrom < ostrom-….dump`
(same for `polis`), copy `instance-key.pem` back with `docker compose cp`, and `docker compose up -d`.
