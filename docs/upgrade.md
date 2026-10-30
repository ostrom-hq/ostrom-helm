# Upgrade

Versions follow semver; the chart's `appVersion` is the Ostrom version it was tested with. Read the release notes:
a release that adds database migrations says so.

## Kubernetes

```sh
helm diff upgrade ostrom oci://ghcr.io/ostrom-hq/charts/ostrom --version <new> -n ostrom -f values-mine.yaml   # optional, helm-diff plugin
helm upgrade ostrom oci://ghcr.io/ostrom-hq/charts/ostrom --version <new> -n ostrom -f values-mine.yaml --atomic --timeout 10m
helm test ostrom -n ostrom
```

- Rolling updates never take a replica away before its replacement is ready (`maxUnavailable: 0`), and the PDBs keep
  one replica up during node drains.
- **Migrations**: with `migrations.initContainer: true` (default), `ostrom-server migrate` runs in an init
  container of each new server pod, with the database owner's credentials, before the server starts (the serving
  container never receives them). Set it to `false` with a server version that has no `migrate` subcommand yet, or
  if you migrate another way.
- Take a backup before any upgrade that changes the database ([backup-restore.md](backup-restore.md)).
- Rollback: `helm rollback ostrom <revision> -n ostrom`. A rollback does not undo migrations: restore the backup if
  the old version cannot read the new schema.
- Pin images by digest in production (`server.image.digest`…) and verify their signature before
  ([images.md](images.md)).

## 0.1.x → 0.2.x

0.2.0 replaces the single PostgreSQL user (a superuser named after `postgresql.username`) by four roles, created by
an init script that only runs on an empty data directory. Go through a dump and a restore:

1. Dump both databases with the 0.1.x user (`pg_dump -U ostrom -Fc ostrom`, same for `polis`), and keep the Secrets
   (`<release>-signing-key`, `<release>-secrets-key`, `<release>-polis`) as in [backup-restore.md](backup-restore.md).
2. Scale the StatefulSet to 0, empty its volume (or delete the PVC `data-<release>-postgresql-0`), delete Secret
   `<release>-postgresql` (its `password` was the superuser's), then `helm upgrade` to 0.2.x: initdb creates the roles
   and new passwords.
3. Restore with `--no-owner --role=ostrom` and `--role=polis` ([backup-restore.md](backup-restore.md#restore)): the
   owner owns the tables again and the serving role gets its rights through the default privileges.

An install without data only needs step 2. With an external database, create the serving role and add
`externalDatabase.migrationUsername` and the `migration-password` key ([install-kubernetes.md](install-kubernetes.md#external-postgresql)).

## Docker Compose

```sh
cd compose
sed -i.bak 's/^OSTROM_VERSION=.*/OSTROM_VERSION=<new>/' .env
docker compose pull && docker compose up -d --wait
```
