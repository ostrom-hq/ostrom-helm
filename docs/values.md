# Values

The defaults are in [`charts/ostrom/values.yaml`](../charts/ostrom/values.yaml), each key commented. The main groups:

| Group | What |
|---|---|
| `global` | image registry, tag and pull secrets; public URLs (`urls.api`, `urls.app`, `urls.site`) |
| `server` | replicas, resources, probes, HPA, PDB, `config` (non-secret env), `secretEnv` / `existingSecret` (secret env), signing key, secrets key |
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
| `OSTROM_DATABASE_URL`, `OSTROM_DATABASE_USER`, `OSTROM_DATABASE_PASSWORD`, `OSTROM_DATABASE_MAX_CONNECTIONS` | the serving role: `postgresql.username` or `externalDatabase.username` |
| `OSTROM_DATABASE_MIGRATION_URL`, `OSTROM_DATABASE_MIGRATION_USER`, `OSTROM_DATABASE_MIGRATION_PASSWORD` | the owner, in the `migrate` init container only: `postgresql.ownerUsername` or `externalDatabase.migrationUsername` |
| `OSTROM_SIGNING_KEY_FILE` | the mounted instance key, `/var/run/ostrom/signing/instance-key.pem` |
| `OSTROM_SECRETS_KEY` | key `secrets-key` of the generated Secret `<release>-secrets-key`, or of `server.secretsKey.existingSecret` |
| `OSTROM_PUBLIC_URL`, `OSTROM_API_URL`, `OSTROM_APP_URL`, `OSTROM_CONSOLE_URL`, `OSTROM_SITE_URL` | `global.urls.*` |
| `OSTROM_EXTRACTION_PROVIDER`, `OSTROM_EXTRACTION_BASE_URL`, `OSTROM_EXTRACTION_MODEL`, `OSTROM_EXTRACTION_API_KEY` | `byok.extraction.*` |
| `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_EXPORTER_OTLP_PROTOCOL` (always `http/protobuf`), `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`, `OTEL_TRACES_SAMPLER_ARG` | `observability.otel.*` (`tracesSampleRatio` for the last) |
| `OSTROM_LANGFUSE_HOST`, `OSTROM_LANGFUSE_PUBLIC_KEY`, `OSTROM_LANGFUSE_SECRET_KEY` | `observability.langfuse.*` |
| `OSTROM_POSTHOG_HOST`, `OSTROM_POSTHOG_API_KEY` | `observability.posthog.*` |
| `OSTROM_SAML_POLIS_URL`, `OSTROM_SAML_POLIS_EXTERNAL_URL`, `OSTROM_SAML_POLIS_API_KEY` | `polis.*` |
| `OSTROM_RUNNERS_DRIVER` (`kubernetes`), `OSTROM_RUNNERS_SERVER_URL`, `OSTROM_RUNNERS_IMAGE`, `OSTROM_RUNNERS_WORKSPACE_SIZE`, `OSTROM_RUNNERS_KUBERNETES_{NAMESPACE,STORAGE_CLASS,IMAGE_PULL_SECRET,PRIORITY_CLASS,SERVER_SELECTOR}`, `OSTROM_CLOUD_MAX_CONCURRENT` | `cloudSessions.*`, only when `cloudSessions.enabled` |
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

## Database roles

The built-in PostgreSQL starts with four roles (`templates/postgresql.yaml`, the same script as
`compose/postgres-init/10-roles.sh`), following CONVENTIONS section 16.1:

| Role | Can | Used by |
|---|---|---|
| `postgres` | everything | initdb, backups, restores; never given to Ostrom |
| `ostrom` (`postgresql.ownerUsername`) | owns the `ostrom` database and its tables | `ostrom-server migrate`, in the init container only |
| `ostrom_app` (`postgresql.username`) | read and write rows; owns nothing, `NOSUPERUSER NOBYPASSRLS` | the server: row-level security always applies |
| `polis` | its own `polis` database only | Ory Polis |

`helm test` checks it on the live database (`templates/tests/test-database.yaml`): the serving role is neither
superuser nor `BYPASSRLS`, cannot create or alter a table, reads what the owner creates; Polis cannot open
the `ostrom` database.

With `postgresql.enabled: false`, create the same roles on your server and give both: `externalDatabase.username`
(serving) and `externalDatabase.migrationUsername` (owner), passwords in `externalDatabase.existingSecret` under
`password` and `migration-password`.

## Cloud sessions

Off by default (`cloudSessions.enabled: false`): a session runs code its user chose, in a pod of your cluster.
Turn them on only where that is acceptable (dedicated nodes, a sandboxed runtime). With them on:

- the server needs exactly one replica (the chart refuses more): the terminal relay lives in memory;
- the server's ServiceAccount gets a **Role** in the release namespace (pods, their logs, per-session Secrets and
  PVCs, the sessions' NetworkPolicies); nothing cluster-wide;
- session pods (labels `app.kubernetes.io/managed-by: ostrom`, `ostrom.run/session`) reach DNS, the server and the
  public internet only; with Cilium, `networkPolicy.ciliumEgressDeny.enabled` adds a namespace-wide deny of
  `networkPolicy.egress.extraDeniedCidrs` and the metadata service that no allow rule can reopen;
- `cloudSessions.runner.priorityClassName` names an existing PriorityClass, lower than your other workloads (the
  chart creates none: it is a cluster-wide object).
