# Values

The defaults are in [`charts/ostrom/values.yaml`](../charts/ostrom/values.yaml), each key commented. The main groups:

| Group | What |
|---|---|
| `global` | image registry, tag and pull secrets; public URLs (`urls.api`, `urls.app`, `urls.site`) |
| `server` | replicas, resources, probes, HPA, PDB, `config` (non-secret env), `secretEnv` / `existingSecret` (secret env), signing key |
| `migrations` | `initContainer: true` runs `ostrom-server migrate` before each pod starts |
| `byok.extraction` | provider, base URL, model and key of the model that extracts workflows and policies (BYOK) |
| `observability` | `otel` (OTLP/HTTP endpoint and headers), `langfuse`, `posthog` |
| `web`, `site` | the console (nginx) and the site (Next.js) |
| `postgresql` / `externalDatabase` | built-in StatefulSet with optional daily `pg_dump`, or your own database |
| `polis` | Ory Polis, the SAML ↔ OIDC bridge |
| `cloudSessions` | runner image, resources, deadline, concurrency; RBAC of the controller |
| `ingress` | class, hosts, TLS secret or cert-manager issuer, API annotations (streaming, body size) |
| `networkPolicy` | ingress controller location, DNS, denied egress CIDRs, Kubernetes API access |

## Server environment

The chart sets these for the server (ConfigMap `<release>-server`, Secret `<release>-server`):

| Variable | From |
|---|---|
| `OSTROM_HOST`, `OSTROM_PORT`, `OSTROM_LOG_LEVEL` | `server.port`, `server.logLevel` |
| `OSTROM_DATABASE_URL`, `OSTROM_DATABASE_USER`, `OSTROM_DATABASE_PASSWORD`, `OSTROM_DATABASE_MAX_CONNECTIONS` | `postgresql.*` or `externalDatabase.*` |
| `OSTROM_SIGNING_KEY_FILE` | the mounted instance key, `/var/run/ostrom/signing/instance-key.pem` |
| `OSTROM_PUBLIC_URL`, `OSTROM_API_URL`, `OSTROM_APP_URL`, `OSTROM_SITE_URL` | `global.urls.*` |
| `OSTROM_EXTRACTION_PROVIDER`, `OSTROM_EXTRACTION_BASE_URL`, `OSTROM_EXTRACTION_MODEL`, `OSTROM_EXTRACTION_API_KEY` | `byok.extraction.*` |
| `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_EXPORTER_OTLP_PROTOCOL` (always `http/protobuf`), `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`, `OTEL_TRACES_SAMPLER_ARG` | `observability.otel.*` (`tracesSampleRatio` for the last) |
| `OSTROM_LANGFUSE_HOST`, `OSTROM_LANGFUSE_PUBLIC_KEY`, `OSTROM_LANGFUSE_SECRET_KEY` | `observability.langfuse.*` |
| `OSTROM_POSTHOG_HOST`, `OSTROM_POSTHOG_API_KEY` | `observability.posthog.*` |
| `OSTROM_SAML_POLIS_URL`, `OSTROM_SAML_POLIS_EXTERNAL_URL`, `OSTROM_SAML_POLIS_API_KEY` | `polis.*` |
| `OSTROM_CLOUD_SESSIONS_ENABLED`, `OSTROM_CLOUD_NAMESPACE`, `OSTROM_CLOUD_RUNNER_IMAGE`, `OSTROM_CLOUD_RUNNER_SERVICE_ACCOUNT`, `OSTROM_CLOUD_RUNNER_LABELS`, `OSTROM_CLOUD_RUNNER_{CPU,MEMORY}_{REQUEST,LIMIT}`, `OSTROM_CLOUD_RUNNER_DEADLINE_SECONDS`, `OSTROM_CLOUD_MAX_CONCURRENT`, `OSTROM_CLOUD_IMAGE_PULL_SECRETS` | `cloudSessions.*` |
| `OSTROM_POD_NAME` | the pod name (downward API) |

Everything else goes through `server.config` (plain) or `server.existingSecret` / `server.secretEnv` (secret),
whose keys are environment variable names, e.g. `OSTROM_GITHUB_APP_ID`, `OSTROM_GITHUB_CLIENT_SECRET`,
`OSTROM_GITHUB_WEBHOOK_SECRET`, `OSTROM_GITHUB_APP_PRIVATE_KEY`, `OSTROM_GOOGLE_CLIENT_ID`,
`OSTROM_GOOGLE_CLIENT_SECRET`, `OSTROM_RESEND_API_KEY`, `OSTROM_EMAIL_FROM`, `OSTROM_STRIPE_SECRET_KEY`,
`OSTROM_STRIPE_WEBHOOK_SECRET`. The server documents its own keys in `ostrom-server/docs/MODULES.md`.

## Web console runtime settings

The web image writes `/config.js` at start (`window.__OSTROM_CONFIG__`) from `OSTROM_API_URL`, `OSTROM_APP_URL`,
`OSTROM_SITE_URL`, `OSTROM_POSTHOG_HOST`, `OSTROM_POSTHOG_API_KEY` and any `web.config` key: one image for every
deployment, never a secret in it.
