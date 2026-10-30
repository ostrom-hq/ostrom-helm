# Upgrade

Versions follow semver; the chart's `appVersion` is the Ostrom version it was tested with. Read the release notes:
a release that adds database migrations says so.

## Kubernetes

```sh
helm repo update   # or: helm pull oci://ghcr.io/ostrom-hq/charts/ostrom --version <new>
helm diff upgrade ostrom oci://ghcr.io/ostrom-hq/charts/ostrom --version <new> -n ostrom -f values-mine.yaml   # optional, helm-diff plugin
helm upgrade ostrom oci://ghcr.io/ostrom-hq/charts/ostrom --version <new> -n ostrom -f values-mine.yaml --atomic --timeout 10m
helm test ostrom -n ostrom
```

- Rolling updates never take a replica away before its replacement is ready (`maxUnavailable: 0`), and the PDBs keep
  one replica up during node drains.
- **Migrations**: `ostrom-server migrate` runs in an init container of each new server pod, with the database
  owner's credentials, before the server starts (the serving container never receives them). The migrator takes a
  lock, so concurrent pods wait for each other. `migrations.initContainer: false` turns it off if you migrate
  another way.
- Take a backup before any upgrade that changes the database ([backup-restore.md](backup-restore.md)).
- Rollback: `helm rollback ostrom <revision> -n ostrom`. A rollback does not undo migrations: restore the backup if
  the old version cannot read the new schema.
- Pin images by digest in production (`server.image.digest`…) and verify their signature before
  ([images.md](images.md)).

## Docker Compose

```sh
cd compose
sed -i.bak 's/^OSTROM_VERSION=.*/OSTROM_VERSION=<new>/' .env
docker compose pull && docker compose up -d --wait
```
