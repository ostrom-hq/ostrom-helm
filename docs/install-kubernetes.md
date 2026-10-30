# Install on Kubernetes with Helm

Requirements: Kubernetes 1.27+, Helm 3.14+, an ingress controller (the chart defaults to the `nginx` class), a
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
  imageTag: "0.1.0"
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
helm install ostrom oci://ghcr.io/ostrom-hq/charts/ostrom --version 0.1.0 -n ostrom -f values-mine.yaml
# or from a clone: helm install ostrom ./charts/ostrom -n ostrom -f values-mine.yaml
helm test ostrom -n ostrom
```

The chart generates once, and keeps across upgrades and uninstalls (`helm.sh/resource-policy: keep`): the
PostgreSQL password, the **instance signing key** (Secret `ostrom-signing-key`, signs every receipt — back it up),
and the Ory Polis keys.

## 6. DNS

Point `api.`, `app.`, `sso.` and the site host at the ingress controller's address.

## External PostgreSQL

```yaml
postgresql: { enabled: false }
externalDatabase:
  url: postgresql://db.example.com:5432/ostrom
  username: ostrom
  existingSecret: ostrom-db          # key `password`
  polisExistingSecret: ostrom-polis-db  # key `url`: postgres://user:pass@db.example.com:5432/polis
```

Add the database's address to nothing: the server's egress allows the internet, minus the private ranges in
`networkPolicy.egress.deniedCidrs`. If your database is on a private range, remove that range from the list or set
`networkPolicy.enabled: false`.

## Cloud sessions

With `cloudSessions.enabled` (default), the server's ServiceAccount gets a **Role** in the release namespace
(pods, pods/log, pods/attach, secrets create/delete, jobs, events) and creates one pod per session from the
`ostrom-runner` image. Session pods have no Kubernetes token and a NetworkPolicy that lets them reach the
internet and this release's server, nothing else in the cluster (no private range, no metadata endpoint).
