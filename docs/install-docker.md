# Install with Docker Compose

One machine with Docker Engine 24+ and Compose v2. 2 vCPU and 4 GB of RAM are enough for a team of 50.

```sh
git clone https://github.com/ostrom-hq/ostrom-helm && cd ostrom-helm/compose
./install.sh
```

`install.sh` writes `.env` once (mode 600) with fresh secrets — the PostgreSQL password and the three Ory Polis
keys — then runs `docker compose up -d --wait`. Run it again any time: it keeps `.env`.

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
# BYOK: the model that extracts workflows and policies from text
OSTROM_EXTRACTION_PROVIDER=openrouter
OSTROM_EXTRACTION_BASE_URL=https://openrouter.ai/api/v1
OSTROM_EXTRACTION_MODEL=anthropic/claude-sonnet-4.5
OSTROM_EXTRACTION_API_KEY=sk-or-...
# OpenTelemetry (OTLP/HTTP)
OTEL_EXPORTER_OTLP_ENDPOINT=https://otlp.example.com
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic ...
```

The full list of server keys is in [values.md](values.md#server-environment).

## Version

`OSTROM_VERSION` in `.env` picks the image tag (`latest` by default). Pin it in production, e.g. `OSTROM_VERSION=0.1.0`,
then `docker compose pull && docker compose up -d`. See [upgrade.md](upgrade.md).

Cloud sessions (agents running on the server) need Kubernetes: they are off in the Compose install.
