# Sizing

Targets of the server (a native binary, no JVM): API p95 under 50 ms at nominal load, start under 200 ms, a few tens
of MB of RAM at rest. They are goals, not yet measured on a release: size from the table, then adjust on your own
metrics.

Measured on the chart (ostrom-e2e `chart-load.yml`, kind, ingress-nginx, 2 server replicas, built-in PostgreSQL, runs
[41053122493](https://github.com/ostrom-hq/ostrom-e2e/actions/runs/41053122493) and [41055002838](https://github.com/ostrom-hq/ostrom-e2e/actions/runs/41055002838)), 0 errors and 0 restarts:

| Load through the ingress | p95 | p99 | Peak per server pod | PostgreSQL | ingress-nginx |
|---|---|---|---|---|---|
| `/health` + `/api/v1/instance`, 100 req/s | 2.9 ms | 5.4 ms | 130-194m, 90-114 MiB | 107-145m, 65-82 MiB | 28-44m, 45 MiB |
| token reads (`/auth/me`, orgs, members), 100 req/s | 5.4-6.9 ms | 8.7-12.1 ms | (same window) | | |
| organization rename (a write), 5 req/s | 17.0 ms | 23.7 ms | | | |

Peaks come from `kubectl top` (15 s windows): short bursts go higher. The server requests below cover them.

| Team | Server | Web, site | PostgreSQL | Cloud sessions |
|---|---|---|---|---|
| up to 50 people | 2 × (100m CPU, 128 Mi request / 256 Mi limit) | 2 × default | 100m / 256 Mi, 10 Gi disk | 250m / 512 Mi each, limit 2 CPU / 2 Gi |
| 50-500 | 3 × (200m, 128 Mi / 512 Mi), HPA 3-10 | 2-4 | 500m / 1 Gi, 50 Gi, `max_connections` ≥ replicas × `server.database.maxConnections` + 20 | same; size the nodes for the sessions the organizations' plans allow |
| 500+ | HPA 4-20, external managed PostgreSQL with backups and a replica | 3-6 | managed | dedicated nodes for sessions, a PriorityClass below your workloads (`cloudSessions.runner.priorityClassName`) |

Rules of thumb:

- **Connections**: every server replica opens up to `server.database.maxConnections` (10). Keep
  `replicas × 10 + Polis (≈10) + 20` under PostgreSQL's `max_connections` (200 by default here).
- **Cloud sessions** dominate the footprint: one agent session ≈ 0.25-2 CPU and 0.5-2 GiB while it works. Plan
  nodes for (sessions the plans allow at once) × limits, and keep sessions on their own nodes in a shared cluster.
- **HPA** needs metrics-server. Without it keep `autoscaling.enabled: false` and fixed replicas.
- **Disk**: PostgreSQL grows with receipts and audit events (≈ 1-2 KB per gated action). 20 Gi holds tens of millions.
- **Docker Compose**: 2 vCPU / 4 GB for up to ~50 people, without cloud sessions.
