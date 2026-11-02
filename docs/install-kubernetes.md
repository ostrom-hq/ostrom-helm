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

## 2. Image pull secret (while the images are private)

```sh
kubectl -n ostrom create secret docker-registry ghcr \
  --docker-server=ghcr.io --docker-username=<github user> --docker-password=<token with read:packages>
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
  imagePullSecrets: [ghcr]
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
helm install ostrom oci://ghcr.io/ostrom-hq/charts/ostrom --version <chart version> -n ostrom -f values-mine.yaml
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

The same goes for an in-cluster OTLP collector (a `namespaceSelector` and `podSelector` in `to`) or an egress proxy.
If the database runs as pods of another namespace of the same cluster, `networkPolicy.ciliumEgressDeny` (Cilium, off
by default) denies it too: keep that off, or move the database out of the cluster.

### Traffic to the database is not encrypted

The server's PostgreSQL driver has no TLS today: it cannot connect with `sslmode=require` and refuses a URL with a
query string. Everything between the server and PostgreSQL crosses the network in the clear (the password does not:
SCRAM). A managed database that forces TLS (RDS PostgreSQL 15 and later, `rds.force_ssl=1` by default) refuses the
server. Until the driver supports it:

- keep the database in the release namespace (the chart's own PostgreSQL), or on a network you trust;
- encrypt the pod network: Cilium or Calico with WireGuard, or the mTLS of a service mesh (Linkerd, Istio) between
  the server and the database;
- on a managed database, allow non-TLS connections from the cluster's addresses only.

Create the two roles yourself before installing: the owner (`CREATE DATABASE … OWNER ostrom`) and the serving role
(`NOSUPERUSER NOBYPASSRLS`, `CONNECT` on the database, `USAGE` on the schema, and `ALTER DEFAULT PRIVILEGES FOR
ROLE ostrom … GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES` and `USAGE, SELECT ON SEQUENCES`). The script the
chart runs on its own PostgreSQL, `10-roles.sh` in `templates/postgresql.yaml`, is the reference.

## Cloud sessions

Off by default. With `cloudSessions.enabled: true` (and `server.replicas: 1`), the server's ServiceAccount gets a
**Role** in the release namespace (pods, pods/log, per-session Secrets and PVCs, the sessions' NetworkPolicies, events)
and creates one pod per session from the `ostrom-runner` image. Session pods have no Kubernetes token and reach DNS,
this release's server and the public internet only. Read [values.md](values.md#cloud-sessions) before turning them on.
