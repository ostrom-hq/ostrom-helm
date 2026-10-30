# ostrom-helm

Everything to run Ostrom yourself: the Helm chart `ostrom` (Kubernetes) and a Docker Compose stack (one machine).

| | |
|---|---|
| [`charts/ostrom`](charts/ostrom) | Server, web console, site, PostgreSQL, Ory Polis (SAML), cloud-session controller RBAC, ingress, NetworkPolicy, HPA, PDB |
| [`compose/`](compose) | Self-hosting in one command: `./compose/install.sh` |
| [`docs/`](docs) | [Docker](docs/install-docker.md) · [Kubernetes](docs/install-kubernetes.md) · [Values](docs/values.md) · [Backup and restore](docs/backup-restore.md) · [Upgrade](docs/upgrade.md) · [Sizing](docs/sizing.md) · [Images and signatures](docs/images.md) |

The chart creates **namespaced objects only** (no ClusterRole, CRD, webhook or namespace; CI checks it), reuses the
cluster's ingress controller and, if present, cert-manager, and runs every pod non-root, without capabilities, with a
read-only root filesystem (except Ory Polis, whose Next.js runtime writes next to itself) under the `restricted` Pod
Security standard.

Tests (CI, every PR): `helm lint --strict`, `helm unittest`, kubeconform on Kubernetes 1.29 and 1.31, `ct install`
on kind (install, `helm test`, upgrade, uninstall) in a `restricted` namespace, and an end-to-end test of the
Compose install.

License: AGPL-3.0 (see [LICENSE](LICENSE)).
