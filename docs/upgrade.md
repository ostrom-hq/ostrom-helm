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
- **Migrations**: the server applies them at start. Until the server serializes migrations itself, upgrade a
  release that adds migrations with one replica first (`--set server.replicas=1`, then back), or set
  `migrations.initContainer: true` once the server ships `ostrom-server migrate`.
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
