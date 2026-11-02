# Values

The defaults are in [`charts/ostrom/values.yaml`](../charts/ostrom/values.yaml), each key commented. The main groups:

| Group | What |
|---|---|
| `global` | image registry, tag and pull secrets; public URLs (`urls.api`, `urls.app`, `urls.site`) |
| `server` | replicas, resources, probes, HPA, PDB, `config` (non-secret env), `secretEnv` / `existingSecret` (secret env), signing key, secrets key |
| `migrations` | `initContainer: true` runs `ostrom-server migrate` before each pod starts |
| `observability` | `otel` (OTLP/HTTP endpoint and headers), `langfuse`, `posthog` |
| `web`, `site` | the console (nginx) and the site (Next.js) |
| `postgresql` / `externalDatabase` | built-in StatefulSet with optional daily `pg_dump`, or your own database |
| `polis` | Ory Polis, the SAML ↔ OIDC bridge. **Coming soon**: off by default (`polis.enabled: false`), the server has no SAML code yet |
| `cloudSessions` | runner image, resources, deadline; `allowedOrgs` (S2-10); RBAC of the controller |
| `ingress` | class, hosts, TLS secret or cert-manager issuer, API annotations (streaming, body size) |
| `networkPolicy` | ingress controller location, DNS, denied egress CIDRs, the server's internet and extra egress rules, Kubernetes API access |

## Guardrails

`charts/ostrom/values.schema.json` refuses, before anything renders:

- an unknown top-level key (`networkPolicyy`: a typo would keep the default without a word);
- a security context below the Pod Security Standard `restricted` plus a read-only root: `podSecurityContext` keeps
  `runAsNonRoot: true` and a `RuntimeDefault` (or `Localhost`) seccomp profile; `containerSecurityContext` keeps
  `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `drop: [ALL]`, no added capability, never
  `privileged`; `server.runAsUser` is never 0;
- a malformed image digest, an unknown `global.imagePullPolicy`, an external database URL with a query string (the
  server refuses it at start).

The two security contexts are the server's, the console's and the site's; the other pods (PostgreSQL, its Jobs, Ory
Polis, the tests) have theirs written in the chart, which no value changes. The CI then checks the pods of four
renders (default, the CI stand-in, an external database with Polis and autoscaling, cloud sessions with Cilium and
backups) with the Kyverno CLI (`ci/policy-check.sh`, `ci/policies/restricted.yaml`): `restricted`, a read-only root
(Ory Polis excepted), requests and a memory limit, no branch-like tag (`latest`, `edge`, `main`…) nor a missing one,
and no Kubernetes token but on the server with cloud sessions. One failure fails the run. Session pods are created by
the server at run time, not rendered by the chart: this check does not see them. Install in a namespace
labelled `pod-security.kubernetes.io/enforce=restricted` all the same: the chart is tested there.

## Server environment

The chart sets these for the server (ConfigMap `<release>-server`, Secret `<release>-server`):

| Variable | From |
|---|---|
| `OSTROM_HOST`, `OSTROM_PORT`, `OSTROM_LOG_LEVEL` | `server.port`, `server.logLevel` |
| `OSTROM_DATABASE_URL`, `OSTROM_DATABASE_USER`, `OSTROM_DATABASE_PASSWORD`, `OSTROM_DATABASE_MAX_CONNECTIONS` | the serving role: `postgresql.username` or `externalDatabase.username` |
| `OSTROM_DATABASE_MIGRATION_URL`, `OSTROM_DATABASE_MIGRATION_USER`, `OSTROM_DATABASE_MIGRATION_PASSWORD` | the owner, in the `migrate` init container only: `postgresql.ownerUsername` or `externalDatabase.migrationUsername` |
| `OSTROM_SIGNING_KEY_FILE` | the mounted instance key, `/var/run/ostrom/signing/instance-key.pem` |
| `OSTROM_SECRETS_KEY` | key `secrets-key` of the generated Secret `<release>-secrets-key`, or of `server.secretsKey.existingSecret` |
| `OSTROM_PUBLIC_URL` | `global.urls.api` |
| `OSTROM_CONSOLE_URL` | `global.urls.app`: device-login page, sign-in redirects, and the only origin a browser session may change state from |
| `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_EXPORTER_OTLP_PROTOCOL` (always `http/protobuf`), `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`, `OTEL_TRACES_SAMPLER_ARG` | `observability.otel.*` (`tracesSampleRatio` for the last) |
| `OSTROM_LANGFUSE_HOST`, `OSTROM_LANGFUSE_PUBLIC_KEY`, `OSTROM_LANGFUSE_SECRET_KEY` | `observability.langfuse.*` |
| `OSTROM_POSTHOG_HOST`, `OSTROM_POSTHOG_API_KEY` | `observability.posthog.*` |
| `OSTROM_RUNNERS_DRIVER` (`kubernetes`), `OSTROM_RUNNERS_SERVER_URL`, `OSTROM_RUNNERS_IMAGE`, `OSTROM_RUNNERS_WORKSPACE_SIZE`, `OSTROM_RUNNERS_KUBERNETES_{NAMESPACE,STORAGE_CLASS,IMAGE_PULL_SECRET,PRIORITY_CLASS,SERVER_SELECTOR}` | `cloudSessions.*`, only when `cloudSessions.enabled` |
| `OSTROM_RUNNERS_ALLOWED_ORGS` | `cloudSessions.allowedOrgs`, only when `cloudSessions.enabled`: organization ids, or `["*"]`; **empty (the default) refuses every organization** (403), audit S2-10. How many sessions run at once comes from each organization's plan |
| `OSTROM_POD_NAME` | the pod name (downward API) |
| `OSTROM_TRUSTED_PROXIES` | `server.trustedProxies`: CIDRs (comma separated) of the ingress controller's pods and of the nodes, whose forwarded client address the server believes; unset by default |
| `OSTROM_SHUTDOWN_DELAY_SECONDS` | `server.shutdownDelaySeconds` (0 to 10, default 5): after SIGTERM, `/ready` answers 503 this long before the server stops, so the Service drops the pod first; readiness probes `/ready`, liveness and startup `/health` |

A secret never goes in `server.config` (a ConfigMap), `server.extraEnv` with a plain `value`, `web.config` (served to
every browser) or `site.env`: the chart refuses a key that looks like one (`SECRET`, `PASSWORD`, `TOKEN`, `CREDENTIAL`,
`API_KEY`, `PRIVATE_KEY`, `LICENSE_KEY`, or ending in `_KEY`; not a path `_FILE`, an address `_URL`, the runners'
pull Secret name, nor PostHog's public project key), and any value that carries a credential whatever its name: a
URL with a password (`redis://:pw@…`, `externalDatabase.url` included) or a token in a query string. A setting the
check takes for a secret by mistake goes in `server.secretEnv` or `server.existingSecret`: it is the same
environment variable. Kubernetes' `view` role reads ConfigMaps and pod specs, never Secrets. Ory Polis's external
database URL (`externalDatabase.polisUrl`) goes into Secret `<release>-polis-db`, and a change of it rolls the Polis
pods. Not checked: a ConfigMap of yours given in `server.extraEnvFrom`. The CI renders the chart with a witness in
every secret input and fails if one shows up outside a Secret, or never reaches one (`ci/secrets-in-render.sh`).

Everything else goes through `server.config` (plain) or `server.existingSecret` / `server.secretEnv` (secret),
whose keys are environment variable names, e.g. `OSTROM_GITHUB_CLIENT_ID`, `OSTROM_GITHUB_CLIENT_SECRET`,
`OSTROM_GOOGLE_CLIENT_ID`, `OSTROM_GOOGLE_CLIENT_SECRET`, `OSTROM_RESEND_API_KEY`, `OSTROM_MAIL_FROM`,
`OSTROM_STRIPE_SECRET_KEY`, `OSTROM_STRIPE_WEBHOOK_SECRET`, `OSTROM_LICENSE_KEY`. The server documents its own keys in
`ostrom-server/docs/MODULES.md`.

The GitHub App's keys (its id, private key and webhook secret) are coming soon: the server of `main` does not read
them yet (ostrom-server#44).

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
| `ostrom_tenant` | `NOLOGIN`: the role the server switches to (`SET LOCAL ROLE`) for row-level security | granted to `ostrom_app`; the owner administers it |
| `ostrom_router` | `NOLOGIN`: owns the cross-organization functions (`SECURITY DEFINER`, ostrom-server `docs/tenancy.md`), no table | the owner administers it; never granted to `ostrom_app` |

Since server 4e4137d (S2-43) the server does not migrate and refuses to start if the migrations are not applied, or
if its role is a superuser, `BYPASSRLS`, owns a table or is a member of the owner. The migrations create
`ostrom_tenant`, so the owner has `CREATEROLE` (since PostgreSQL 16 it only administers the roles it creates). This
block ends the init script of a new database, and a `pre-upgrade` Job (`templates/database-roles-job.yaml`, as
`postgres`, idempotent) replays it before every upgrade, for a database created by an older chart:

```sql
SELECT 'CREATE ROLE ostrom_tenant NOLOGIN NOSUPERUSER NOBYPASSRLS'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ostrom_tenant') \gexec
ALTER ROLE :"owner" CREATEROLE;
GRANT ostrom_tenant TO :"owner" WITH ADMIN OPTION;
GRANT ostrom_tenant TO :"app";
SELECT 'CREATE ROLE ostrom_router NOLOGIN NOSUPERUSER NOBYPASSRLS'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ostrom_router') \gexec
GRANT ostrom_router TO :"owner" WITH ADMIN OPTION;
\connect :"db"
GRANT USAGE ON SCHEMA public TO ostrom_tenant;
-- AUDIT-RLS R8: the migrations' history is written by its owner alone. Any other role (the serving role, ostrom_tenant
-- that it inherits, PUBLIC) holding more than SELECT, on the table or a column, loses it all and keeps SELECT.
DO $lock$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT quote_ident(c.relname) AS tbl,
      CASE WHEN g.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(g.grantee)) END AS name,
      bool_or(g.privilege_type = 'SELECT' AND NOT g.on_column) AS reads
    FROM pg_class c
    CROSS JOIN LATERAL (
      SELECT a.grantee, a.privilege_type, false AS on_column FROM aclexplode(c.relacl) a
      UNION ALL
      SELECT a.grantee, a.privilege_type, true FROM pg_attribute t, aclexplode(t.attacl) a WHERE t.attrelid = c.oid
    ) g
    WHERE c.relkind = 'r' AND c.relnamespace = 'public'::regnamespace AND c.relname LIKE '\_migrations\_%'
      AND g.grantee <> c.relowner
    GROUP BY c.relname, g.grantee
    HAVING bool_or(g.privilege_type <> 'SELECT' OR g.on_column)
  LOOP
    EXECUTE format('REVOKE ALL ON public.%s FROM %s CASCADE', r.tbl, r.name);
    IF r.reads THEN
      EXECUTE format('GRANT SELECT ON public.%s TO %s', r.tbl, r.name);
    END IF;
  END LOOP;
END
$lock$;
```

(`psql -v ON_ERROR_STOP=1 -v owner=ostrom -v app=ostrom_app -v db=ostrom`). Never give the serving role
`CREATEROLE`, membership of the owner nor `ostrom_router`.

`helm test` checks it on the live database (`templates/tests/test-database.yaml`): the serving role is neither
superuser nor `BYPASSRLS`, cannot create or alter a table, reads what the owner creates, reads the migrations' history and writes none of it
(directly, through `ostrom_tenant` or `PUBLIC`, AUDIT-RLS R8); Polis cannot open the `ostrom` database.

With `postgresql.enabled: false`, create the same roles on your server (the block above included: the chart runs no
Job against an external database) and give both: `externalDatabase.username`
(serving) and `externalDatabase.migrationUsername` (owner), passwords in `externalDatabase.existingSecret` under
`password` and `migration-password`.

## Availability

- **Spread over nodes.** By default, server, web and site prefer one pod per node (`podAntiAffinity` on
  `kubernetes.io/hostname`, preferred, so a one-node cluster still schedules them). An `affinity` in the values replaces this
  default; add `topologySpreadConstraints` to spread over zones too.
- **PodDisruptionBudget**, `minAvailable: 1`. It is rendered only when the fewest replicas that can run (`replicas`, or
  `autoscaling.minReplicas` with the HPA) are two or more: with one, the budget would block every node drain. The
  chart refuses a `minAvailable` equal to or above that number, for the same reason. The CI drains the node of a two-replica
  release on kind (`ci/perf-drill.sh`): one server pod is evicted, the other is refused by the budget, and the Service
  keeps a ready endpoint all along.
- **HPA**, `autoscaling.enabled` (needs metrics-server). The Deployment then has no `replicas`, so an upgrade never resets
  the HPA's count. The server's `autoscaling.behavior` scales up at once and down by one pod a minute, after 5 minutes
  of low load; any [HPA `behavior`](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/#configurable-scaling-behavior)
  goes there, for web and site too. Cloud sessions need exactly one server replica and no HPA (the chart refuses otherwise).
## Dashboards and alerts

The server sends its metrics, traces and logs over OTLP (`observability.otel`). Point it at your OpenTelemetry
Collector or at any OTLP backend; once the metrics reach Prometheus under the usual OTLP names
(`http_server_request_duration_seconds`, …), the chart can add:

- `monitoring.dashboards.enabled`: a ConfigMap with the dashboard "Ostrom — API" (requests per route, 5xx ratio,
  p50/p95/p99, requests in flight, CPU, memory, dropped telemetry). It has a `datasource` variable and a `job` variable.
  The `grafana_dashboard: "1"` label is the one the Grafana sidecar of kube-prometheus-stack watches.
- `monitoring.prometheusRule.enabled`: a PrometheusRule (Prometheus Operator) with four alerts, matching the API budget of
  50 ms at p95:
  - 5xx above 2 % for 5 minutes;
  - p95 above 250 ms for 10 minutes;
  - no metric from the server for 10 minutes;
  - dropped telemetry (`info`).
  Without the operator the chart refuses it; with `helm template`, pass
  `--api-versions monitoring.coreos.com/v1/PrometheusRule`.

The series are selected by `job="ostrom/<prefix>-server"`: the server's `service.namespace` is `ostrom`, and the
`service.name` comes from `observability.otel.serviceNamePrefix`. Set `monitoring.job` if your collector labels them
otherwise. Gates, sessions and inference cost are declared by the server but not recorded yet in this version, so
neither the dashboard nor the alerts use them.

## Cloud sessions

Off by default (`cloudSessions.enabled: false`): a session runs code its user chose, in a pod of your cluster.
Turn them on only where that is acceptable (dedicated nodes, a sandboxed runtime). With them on:

- the server needs exactly one replica (the chart refuses more): the terminal relay lives in memory;
- the server's ServiceAccount gets a **Role** in the release namespace (pods, their logs, per-session Secrets and
  PVCs, the sessions' NetworkPolicies); nothing cluster-wide;
- session pods (labels `app.kubernetes.io/managed-by: ostrom`, `ostrom.run/session`) reach DNS, the server and the
  public internet only; with Cilium, `networkPolicy.ciliumEgressDeny.enabled` adds a namespace-wide deny that no
  allow rule can reopen (see below);
- `cloudSessions.runner.priorityClassName` names an existing PriorityClass, lower than your other workloads (the
  chart creates none: it is a cluster-wide object).

## Network isolation

Every pod of the release is denied in and out by default; each part gets only what it needs: the ingress controller
in, DNS out, the server to PostgreSQL (and Polis), web to the server, the site nothing.

- `networkPolicy.server.allowInternet` (default `true`): the server reaches the internet minus
  `networkPolicy.egress.deniedCidrs` and `extraDeniedCidrs` (the private ranges, the metadata service). `false`: no
  internet for the server, only PostgreSQL, Polis, DNS and `networkPolicy.server.extraEgress`, where you list the
  CIDRs of the providers you use (GitHub, your model provider, e-mail, billing). It is the server's only: Ory Polis
  (identity providers' metadata) and cloud-session pods (agent code) keep their own internet egress.
- `networkPolicy.server.extraEgress`, `networkPolicy.polis.extraEgress`: NetworkPolicy `egress` rules added to the
  server or to Polis, for what lives on a private range (an external database, an in-cluster collector, a proxy).
  Each names its destination (`to`) and its `ports`. The chart refuses the mistakes that open everything or close to
  it: a rule without `to` or `ports`, an ipBlock wider than /16 (IPv6: /48), a peer that selects every namespace
  (`namespaceSelector: {}`) or every pod (`podSelector: {}`). It is a guard against accidents, not a policy engine:
  what you list is what opens.
- `tests.networkPolicyEnforced` (default `true`): `helm test` tries PostgreSQL (the server, with an external
  database) from a pod no policy allows, and fails if it gets through. A CNI that ignores NetworkPolicy (flannel
  alone, some managed networks) installs the chart without a word: this test is what tells you. It runs after the
  other tests, which reach the same target from an allowed pod, and it fails too when the name does not resolve,
  so a target that is down or misnamed never passes for a blocked one.

## Cilium egress deny (shared clusters)

`networkPolicy.ciliumEgressDeny.enabled: true` renders one namespaced `CiliumNetworkPolicy` that applies to every pod
of the release namespace, session pods and any pod created later included, and only denies (it allows nothing, and
turns no default deny on):

| Denied | Value |
|---|---|
| The cloud metadata service `169.254.169.254` and `networkPolicy.egress.extraDeniedCidrs` | always |
| Every pod of another namespace, cluster DNS excepted | `otherNamespaces.enabled` (default `true`) |
| The nodes (`host`, `remote-node`: kubelet, NodePorts) | `otherNamespaces.denyNodes` (default `true`) |

The endpoint rules matter: Cilium turns the address of a Service or of an in-cluster LoadBalancer into its backend
pods before applying policy, so a CIDR rule alone does not stop a pod from reaching another tenant's load balancer.
Cluster DNS is recognised by `otherNamespaces.dns` (namespace `kube-system`, label `k8s-app` in `kube-dns`,
`coredns`): adjust it if your DNS pods are labelled otherwise, or name resolution stops. With a control plane
running on the nodes, set `denyNodes: false` before turning cloud sessions on (the server needs the API).

Checked on a production cluster (Cilium 1.17, 30/10/2026), with a pod of the namespace that no NetworkPolicy
selects: internet open; metadata service, the extra CIDRs, another namespace's LoadBalancer and ClusterIP Services,
a node's kubelet: blocked. Without the endpoint rules, the LoadBalancer, the Service and the kubelet were open.

## Cloudflare Authenticated Origin Pulls

`ingress.cloudflareOriginPulls.enabled: true` (ingress-nginx) makes every Ingress of the release require Cloudflare's
origin-pull client certificate: the chart puts Cloudflare's public CA (`files/cloudflare-origin-pull-ca.pem`) in Secret
`<release>-cloudflare-origin-pull-ca` and sets the `auth-tls-*` annotations on its own Ingresses only; nothing changes
on the shared controller. Turn it on once the hosts are proxied by Cloudflare and "Authenticated Origin Pulls" is on
for the zone (SSL/TLS → Origin Server): until then, every request gets a 400.

## Request body size of the API

The API Ingress allows 16 MiB (`ingress.apiAnnotations`); the server refuses more than 1 MiB on most routes (S2-46).
Publishing an artifact sends its files base64 in JSON (up to about 27.7 MiB on the server): `/api/v1/artifacts` has its
own Ingress, `<release>-api-artifacts`, with `ingress.artifactsBodySize` (32m). Set it to "" to drop that Ingress.

## One origin for the browser

The console reads its session's CSRF token from a cookie of its own origin, so the browser must reach the API there.
The chart routes `<ingress.hosts.app>/api/v1` to the server (Ingress `<release>-api`, with the API annotations) and
everything else on that host to the console; `<ingress.hosts.api>` keeps the whole API for non-browser clients (CLI,
tokens, webhooks). Both hosts reach the same Service. The server accepts state changes from a browser session only
from `OSTROM_CONSOLE_URL`'s origin. The Compose install does the same in its Caddyfile.
