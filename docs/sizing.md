# Sizing

Measured budgets the server is tested against in CI: API p95 < 50 ms at nominal load, start < 200 ms. The server is
a native binary (no JVM): it idles around 20-40 MB of RAM.

| Team | Server | Web, site | PostgreSQL | Cloud sessions |
|---|---|---|---|---|
| up to 50 people | 2 × (50m CPU, 64 Mi request / 256 Mi limit) | 2 × default | 100m / 256 Mi, 10 Gi disk | 250m / 512 Mi each, limit 2 CPU / 2 Gi |
| 50-500 | 3 × (200m, 128 Mi / 512 Mi), HPA 3-10 | 2-4 | 500m / 1 Gi, 50 Gi, `max_connections` ≥ replicas × `server.database.maxConnections` + 20 | same; set `cloudSessions.runner.maxConcurrent` to what the nodes hold |
| 500+ | HPA 4-20, external managed PostgreSQL with backups and a replica | 3-6 | managed | dedicated node pool (`cloudSessions.runner.nodeSelector` / `tolerations`) |

Rules of thumb:

- **Connections**: every server replica opens up to `server.database.maxConnections` (10). Keep
  `replicas × 10 + Polis (≈10) + 20` under PostgreSQL's `max_connections` (200 by default here).
- **Cloud sessions** dominate the footprint: one agent session ≈ 0.25-2 CPU and 0.5-2 GiB while it works. Plan
  nodes for `maxConcurrent × limits`, and keep sessions on their own nodes in a shared cluster.
- **HPA** needs metrics-server. Without it keep `autoscaling.enabled: false` and fixed replicas.
- **Disk**: PostgreSQL grows with receipts and audit events (≈ 1-2 KB per gated action). 20 Gi holds tens of millions.
- **Docker Compose**: 2 vCPU / 4 GB for up to ~50 people, without cloud sessions.
