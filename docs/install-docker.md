# Install with Docker Compose

One machine with Docker Engine 24+ and Compose v2. 2 vCPU and 4 GB of RAM are enough for a team of 50.

```sh
git clone https://github.com/ostrom-hq/ostrom-helm && cd ostrom-helm/compose
./install.sh
```

`install.sh` writes `.env` once (mode 600) with fresh secrets — the passwords of the four database roles
(`postgres`, the owner `ostrom` who migrates, the serving role `ostrom_app`, `polis`) and the three Ory Polis keys —
then runs `docker compose up -d --wait`. Run it again any time: it keeps the values already in `.env` and only adds
the missing ones. A one-shot `migrate` service applies the schema with the owner's credentials before the server
starts; the server itself connects as `ostrom_app`, which owns nothing and cannot bypass row-level security.

By default everything answers on plain HTTP under `*.localhost`: console `http://app.localhost`, API
`http://api.localhost`, SAML bridge `http://sso.localhost`.

## On a real domain, with HTTPS

Point three DNS records at the machine (`api.`, `app.`, `sso.`), then before the first `./install.sh`:

```sh
export OSTROM_SCHEME=https OSTROM_API_HOST=api.example.com OSTROM_APP_HOST=app.example.com OSTROM_SSO_HOST=sso.example.com
./install.sh
```

(or edit those four lines in `.env` and `docker compose up -d`). Caddy obtains and renews the certificates; ports
80 and 443 must be reachable.

## Settings

Anything the server reads (`OSTROM_*`) can go in `compose/server.env` (optional, `KEY=value` lines), for example:

```sh
# OpenTelemetry (OTLP/HTTP)
OTEL_EXPORTER_OTLP_ENDPOINT=https://otlp.example.com
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic ...
```

The full list of server keys is in [values.md](values.md#server-environment).

## Version

No release tag exists yet: `docker-compose.yml` pins the server and the console by digest, to a signed multi-arch build
of `main`. To run another build, set `OSTROM_SERVER_IMAGE` and `OSTROM_WEB_IMAGE` in `.env` (by digest, e.g.
`ghcr.io/ostrom-hq/ostrom-server@sha256:…`), then `docker compose pull && docker compose up -d`. To build the server
yourself instead, in a clone of `ostrom-server`: `ci/build-linux.sh` (it leaves the native binary in
`dist/ostrom-server`), then `docker build -t ostrom-server:local .`, and `OSTROM_SERVER_IMAGE=ostrom-server:local`. See [upgrade.md](upgrade.md).

Cloud sessions (agents running on the server) need Kubernetes: they are off in the Compose install.
