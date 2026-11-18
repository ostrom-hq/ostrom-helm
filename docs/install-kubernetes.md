# Install on Kubernetes with Helm

Requirements: Kubernetes 1.29+ (native sidecars, used by cloud sessions), Helm 3.14+, an ingress controller (the chart defaults to the `nginx` class), a
default StorageClass (or `postgresql.persistence.storageClass`), and a CNI that enforces NetworkPolicy (Cilium,
Calico, kindnet ≥ 0.24…). cert-manager is optional.

The chart only creates namespaced objects: it never touches anything outside its namespace.

## 1. Namespace

```sh
kubectl create namespace ostrom
kubectl label namespace ostrom pod-security.kubernetes.io/enforce=restricted
```

## 2. Image pull secret (only for a private mirror of the images)

The images on `docker.io/ostromhq` are public: skip this step unless you pull from a private mirror.

```sh
kubectl -n ostrom create secret docker-registry mirror \
  --docker-server=<registry host> --docker-username=<user> --docker-password=<token>
```

## 3. TLS

Pick one:

- **cert-manager**: `--set ingress.certManager.clusterIssuer=letsencrypt` (an issuer you already have);
- **an existing certificate** (e.g. a Cloudflare origin certificate for `example.com, *.example.com`):
  `kubectl -n ostrom create secret tls ostrom-tls --cert=origin.pem --key=origin-key.pem` and
  `--set ingress.tls.secretName=ostrom-tls`.

## 4. Settings

`values-mine.yaml`:

```yaml
global:
  imageTag: "<ostrom version>"   # or pin each image: server.image.digest: sha256:…
  # imagePullSecrets: [mirror]   # only for a private mirror; docker.io/ostromhq is public
  urls: { api: https://api.example.com, app: https://app.example.com, site: https://example.com }
ingress:
  hosts: { api: api.example.com, app: app.example.com, site: example.com, siteAliases: [www.example.com], sso: sso.example.com }
  tls: { secretName: ostrom-tls }
networkPolicy:
  ingressController:            # where YOUR ingress controller runs
    namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: ingress-nginx } }
    podSelector: { matchLabels: { app.kubernetes.io/name: ingress-nginx } }
  kubeApi: { cilium: true }     # Cilium; otherwise kubeApi.cidrs: [<API server IP>/32]
server:
  existingSecret: ostrom-server # OAuth, Stripe, Resend… (keys = environment variable names)
```

Secrets the server needs (GitHub, Google, Resend, Stripe…) go into a Secret you create yourself, keys being the
environment variable names (list in [values.md](values.md#server-environment)):

```sh
kubectl -n ostrom create secret generic ostrom-server --from-env-file=server.env
```

## 5. Install

```sh
helm install ostrom oci://registry-1.docker.io/ostromhq/ostrom --version <chart version> -n ostrom -f values-mine.yaml
# or from a clone: helm install ostrom ./charts/ostrom -n ostrom -f values-mine.yaml
helm test ostrom -n ostrom
```

The chart generates once, and keeps across upgrades and uninstalls (`helm.sh/resource-policy: keep`): the
passwords of the four database roles (Secret `<release>-postgresql`), the **instance signing key** (Secret
`ostrom-signing-key`, signs every receipt — back it up), the **secrets key** (Secret `ostrom-secrets-key`, seals the
org secrets, the same for every replica — back it up), and the Ory Polis keys. A chart rendered without cluster
access (`helm template`, Argo CD, Flux) cannot find the kept Secrets: create the signing key and the secrets key
yourself and set `server.signingKey.existingSecret` and `server.secretsKey.existingSecret`.

## 6. DNS

Point `api.`, `app.` and the site host at the ingress controller's address (and `sso.` only with
`polis.enabled: true`; SAML is coming soon).

## 7. First owner

The instance is closed to sign-up: nobody gets an account until its first owner does.
Print their one-time setup link:

```sh
kubectl -n ostrom exec deploy/ostrom-server -- ostrom-server bootstrap
```

It works once, for an hour (run the command again for a new one), and only while the instance has no account. The
person opens it, signs in with GitHub (or Google, or an e-mail link) and creates the organization; from then on,
owners and admins invite people from the console. The link is printed on the command's output only, never in the
server's logs; until it is used, the server logs a warning that says to run the command. To let anyone who signs in
get an account and create organizations instead, an administrator sets the console's sign-up to open (Admin, sign-up).

## External PostgreSQL

```yaml
postgresql: { enabled: false }
externalDatabase:
  url: postgresql://db.example.com:5432/ostrom
  username: ostrom_app               # owns nothing, NOSUPERUSER NOBYPASSRLS
  migrationUsername: ostrom          # owner of the database, for `ostrom-server migrate`
  existingSecret: ostrom-db          # keys `password` and `migration-password`
  polisExistingSecret: ostrom-polis-db  # key `url`: postgres://user:pass@db.example.com:5432/polis
```

The server's egress allows the internet minus the private ranges in `networkPolicy.egress.deniedCidrs`. A database
on a private range gets one rule of its own, its address and its port only; never remove a range from the list nor
turn the NetworkPolicies off for it, which opens the whole range (or everything):

```yaml
networkPolicy:
  server:
    extraEgress:
      - to: [{ ipBlock: { cidr: 10.20.0.15/32 } }]
        ports: [{ protocol: TCP, port: 5432 }]
```

The same goes for an in-cluster OTLP collector (a `namespaceSelector` and `podSelector` in `to`) or an egress proxy,
and for Ory Polis's database (`networkPolicy.polis.extraEgress`) when Polis is on.
If the database runs as pods of another namespace of the same cluster, `networkPolicy.ciliumEgressDeny` (Cilium, off
by default) denies it too: keep that off, or move the database out of the cluster.

### TLS to an external database

The server's JDBC driver (pgjdbc) encrypts on its own when the database offers TLS (`sslmode=prefer`), but it checks
no certificate, and the server does not pass TLS settings yet: `OSTROM_DATABASE_URL` takes no query string (so no
`?sslmode=`), and the server sets no `sslmode` or `sslrootcert`. With
`externalDatabase.tls.enabled`, the chart puts a TLS proxy in the server pod, on the model of Cloud SQL's
auth proxy: PgBouncer (`ghcr.io/cloudnative-pg/pgbouncer`, pinned by digest) as a native sidecar, which starts
before `migrate` and lives with the pod. It dials the database in TLS and checks its certificate; the server and
`migrate` talk to it in clear on the pod's loopback only (`127.0.0.1:6432`), never over the network.

```yaml
externalDatabase:
  url: postgresql://ostrom.cluster-x.eu-west-3.rds.amazonaws.com:5432/ostrom
  username: ostrom_app
  migrationUsername: ostrom
  existingSecret: ostrom-db            # keys password and migration-password
  tls:
    enabled: true
    mode: verify-full                  # verify-full, verify-ca, or require (encrypted, not verified)
    ca: { configMapName: rds-ca, key: global-bundle.pem }   # or secretName
    host: ""                           # empty: the host of url
```

- `verify-full` (default) checks that the certificate is signed by the CA and names the host; `verify-ca` only the
  signature; `require` encrypts without checking anything (never in production: the NOTES say so).
- The proxy asks every client for its password (SCRAM) and logs in to the database with it. The owner's password is
  in the proxy's memory for `migrate` (an in-memory volume, never in the server container); with
  `migrations.initContainer: false`, the proxy only knows the serving role's.
- The proxy serves the one database of `url`, nothing else on the server. `url` takes a host name (the one the
  certificate names, or set `host`), not an IPv6 literal.
- PgBouncer cannot pass on the session settings the server sends when it connects (its startup `options`): the
  proxy drops them. Set them on the roles once, or a stuck query or lock holds a connection for good:

  ```sql
  ALTER ROLE ostrom_app SET statement_timeout = '10s';
  ALTER ROLE ostrom_app SET lock_timeout = '5s';
  ALTER ROLE ostrom_app SET idle_in_transaction_session_timeout = '15s';
  ALTER ROLE ostrom SET lock_timeout = '3s';          -- the owner, for `migrate`
  ```
- Session pooling, one server connection per client connection: the server's prepared statements and the migration
  lock need it. Pool size: `server.database.maxConnections` + 2.
- A database that only accepts TLS (`hostssl`, RDS with `rds.force_ssl=1`, Cloud SQL, Azure) works this way; the CI
  proves it on kind against a PostgreSQL that rejects any plain connection.
- The proxy is the way to a verified connection until the server passes `sslmode` and `sslrootcert` to pgjdbc; then
  the sidecar goes and `externalDatabase.tls` keeps its meaning.
- Ory Polis (off by default) connects with its own driver, not through this proxy (the NOTES remind it).

Without `externalDatabase.tls`, the server encrypts only if the database offers TLS, and never checks who answers (a
man in the middle is not detected); against a database without TLS everything crosses the network in the clear (the
password does not: SCRAM). The chart's own PostgreSQL stays in the
release namespace, behind its NetworkPolicy.

Create the two roles yourself before installing: the owner (`CREATE DATABASE … OWNER ostrom`) and the serving role
(`NOSUPERUSER NOBYPASSRLS`, `CONNECT` on the database, `USAGE` on the schema, and `ALTER DEFAULT PRIVILEGES FOR
ROLE ostrom … GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES` and `USAGE, SELECT ON SEQUENCES`). The script the
chart runs on its own PostgreSQL, `10-roles.sh` in `templates/postgresql.yaml`, is the reference.

## Cloud sessions

Off by default. With `cloudSessions.enabled: true` (and `server.replicas: 1`), the server's ServiceAccount gets a
**Role** in the release namespace (pods, pods/log, per-session Secrets and PVCs, the sessions' NetworkPolicies, events)
and creates one pod per session from the `ostrom-runner` image. Session pods have no Kubernetes token and reach DNS,
this release's server and the public internet only. Read [values.md](values.md#cloud-sessions) before turning them on.
