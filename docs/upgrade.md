# Upgrade

Versions follow semver; the chart's `appVersion` is the Ostrom version it was tested with. Read the release notes:
a release that adds database migrations says so.

## Kubernetes

```sh
helm diff upgrade ostrom oci://registry-1.docker.io/ostromhq/ostrom --version <new> -n ostrom -f values-mine.yaml   # optional, helm-diff plugin
helm upgrade ostrom oci://registry-1.docker.io/ostromhq/ostrom --version <new> -n ostrom -f values-mine.yaml --atomic --timeout 10m
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

## Next release

- The images and the chart move to Docker Hub: `global.imageRegistry` defaults to `docker.io/ostromhq` (it was
  `ghcr.io/ostrom-hq`), the server's image included, and the chart is `oci://registry-1.docker.io/ostromhq/ostrom`. The
  images are public: drop an `imagePullSecrets` entry kept for ghcr. A mirror keeps setting `global.imageRegistry`.

## 0.2.x → 0.3.x

Needs a server image from main 4e4137d or later (it has `ostrom-server migrate` and no longer migrates itself). Keep
`migrations.initContainer: true`. Before the upgrade, a `pre-upgrade` Job adds `ostrom_tenant` and `CREATEROLE` for the
owner on the existing database ([values.md](values.md#database-roles)); no dump nor restore. Readiness moves to
`/ready`; set `server.trustedProxies` to your ingress pods' and nodes' CIDRs. An external database: play the SQL of
[values.md](values.md#database-roles) as its administrator first.

### 0.3.1 → 0.3.2

- The MCP stdio host is deployed by default (`mcp.enabled: true`): a Deployment, Service, ServiceAccount and
  NetworkPolicy `<release>-ostrom-mcp`, and a Secret of the same name holding its token (generated once, kept across
  upgrades and on uninstall). The server gets `OSTROM_MCP_HOST_URL` and `OSTROM_MCP_HOST_TOKEN`, so it needs a server
  image that reads them (the host's image is `ostrom-mcp-host`, at the server's tag). `mcp.enabled: false` renders
  nothing. With `--reuse-values`, pass `--reset-then-reuse-values` to take the block.

### 0.3.0 → 0.3.1

- Kubernetes 1.29 or later (`kubeVersion`): cloud-session pods use native sidecars.
- The server's ConfigMap keeps only what the server reads: `OSTROM_API_URL`, `OSTROM_APP_URL`, `OSTROM_SITE_URL`,
  `OSTROM_EXTRACTION_*`, `OSTROM_SAML_POLIS_*` and `OSTROM_CLOUD_MAX_CONCURRENT` are gone, with `byok.*` and
  `cloudSessions.runner.maxConcurrent` (remove them from your values; they are ignored). <!-- docs-truth: ignore (variables removed) -->
- Third-party images pinned by digest ([images.md](images.md#third-party-images)): the image of PostgreSQL changes
  from `postgres:17.6` to `postgres:17.6@sha256:…`, so its StatefulSet restarts once at the upgrade (same version; with one
  replica, the server waits for it). A values file that sets `postgresql.image.tag` or `polis.image.tag` now also
  sets the matching `digest`, or `digest: ""`: a tag alone is refused. With `helm upgrade --reuse-values`, the old
  values have no digest and the images stay on their tag: pass `--reset-then-reuse-values` to take the pins.
- `values.schema.json` refuses an unknown top-level key and a security context below `restricted`: a values file
  with a leftover key (one the chart never read) now stops the upgrade with `additional properties ... not allowed`.
  Remove the key; with `--reuse-values`, the stored values are checked too.
- The migrations' histories (Flyway's `flyway_<module>`) are written by the owner alone (AUDIT-RLS R8): the pre-upgrade
  Job takes the write off every other role and keeps their read, and `helm test` checks it. An external database:
  play the end of the block in [values.md](values.md#database-roles) once (a server with ostrom-server#144 also does
  it at every `migrate`).
- `cloudSessions.allowedOrgs` (S2-10): with sessions on, list the organizations they are open to; empty refuses all.
- The console's host serves `/api/v1` from the server (one origin for the browser). A pre-upgrade Job adds the
  `ostrom_router` role.
- Request bodies (S2-46): `/api/v1/artifacts` and `/api/v1/inference` take 32m, `/api/v1/import` 8m, each on its own
  Ingress on both hosts (`ingress.bodySizes`); every other API route keeps 16m. Needs a server image from main 62052a9
  (#50) or later, which reads those sizes.
- Ory Polis is off by default (SAML is coming soon; the server has no SAML code yet): the upgrade removes its
  Deployment, Service and `sso.` Ingress. Its database and Secret stay; set `polis.enabled: true` to keep it running.

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
# by digest: OSTROM_SERVER_IMAGE and OSTROM_WEB_IMAGE (docker-compose.yml pins a signed build of main by default)
sed -i.bak 's|^OSTROM_SERVER_IMAGE=.*|OSTROM_SERVER_IMAGE=docker.io/ostromhq/ostrom-server@sha256:<new>|' .env
docker compose pull && docker compose up -d --wait
```
