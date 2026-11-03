# Sizing

Targets of the server (a native binary, no JVM): API p95 under 50 ms at nominal load, start under 200 ms, a few tens
of MB of RAM at rest. They are goals, not yet measured on a release: size from the table, then adjust on your own
metrics.

Measured on the chart (ostrom-e2e `chart-load.yml`, kind, ingress-nginx, 2 server replicas, built-in PostgreSQL,
ostrom-server main of 02/11/2026: runs [41507938323](https://github.com/ostrom-hq/ostrom-e2e/actions/runs/41507938323),
[41519346164](https://github.com/ostrom-hq/ostrom-e2e/actions/runs/41519346164) and
[41530106515](https://github.com/ostrom-hq/ostrom-e2e/actions/runs/41530106515)), 0 restarts:

| Load through the ingress | p95 | p99 | Peak per server pod | PostgreSQL | ingress-nginx |
|---|---|---|---|---|---|
| `/health` + `/api/v1/instance`, 100 req/s | 4.4 ms | 6.9 ms | 134-240m, 128-165 MiB | 128-245m, 77-82 MiB | 25-33m, 41 MiB |
| `/auth/me` with a token, 40 req/s | 7.9 ms | 11.4 ms | (same passes) | | |
| organizations with a token, 60 req/s | 11.4 ms | 16.6 ms | | | |
| organization rename (a write), 5 req/s | 25.9 ms | 35.5 ms | | | |
| gate question, then its yes (60 req/s in all) | 19.0 ms, 25.9 ms | 34.4 ms, 43.4 ms | | | |

p95 and p99 are those of run 41530106515; the peaks, the range over the three runs. Peaks come from `kubectl top` (15 s windows): short bursts go higher. The
requests below cover them. The server's memory limit is 512 MiB: at 256 MiB, run
[41628103773](https://github.com/ostrom-hq/ostrom-e2e/actions/runs/41628103773) lost both replicas to the kernel's OOM
killer (exit 137), once in the race of 100 simultaneous yes and once with 200 open model streams. That run measured
111-116 MiB at rest and about 2.4 MiB per open stream: the gateway's default cap of 100 open calls per replica
(`OSTROM_GATEWAY_MAX_OPEN_CALLS`) fits in about 355 MiB, and lowering the limit means lowering that cap with it.

Startup and drains are measured by the chart's CI on kind with the real server (`ci/perf-drill.sh`, figures in the
job summary): a server pod must be ready within 30 s of its init containers (the `migrate` step), and a node drain
of a two-replica release keeps a ready server all along (the PodDisruptionBudget refuses the last eviction). Run
[41534671735](https://github.com/ostrom-hq/ostrom-helm/actions/runs/41534671735), seconds from the pod's creation on a
fresh install:

| Pod | Scheduled | Initialized | Started | Ready |
|---|---|---|---|---|
| PostgreSQL (empty data directory, initdb) | 4 | 4 | 5 | 7 |
| server × 2 (init: waits for PostgreSQL, then `migrate`) | 0 | 9 | 10 | 11 |

The server itself is ready 2 s after its init containers. The drain of the same run: 85 samples of the Service, 84
with one ready endpoint and 1 with two, never zero; the eviction of the last pod refused by the budget.

| Team | Server | Web, site | PostgreSQL | Cloud sessions |
|---|---|---|---|---|
| up to 50 people | 2 × (250m CPU, 192 Mi request / 512 Mi limit) | 2 × default | 250m / 256 Mi, 10 Gi disk | 250m / 512 Mi each, limit 2 CPU / 2 Gi |
| 50-500 | 3 × (250m, 192 Mi / 512 Mi), HPA 3-10 | 2-4 | 500m / 1 Gi, 50 Gi, `max_connections` ≥ replicas × `server.database.maxConnections` + 20 | same; size the nodes for the sessions the organizations' plans allow |
| 500+ | HPA 4-20, external managed PostgreSQL with backups and a replica | 3-6 | managed | dedicated nodes for sessions, a PriorityClass below your workloads (`cloudSessions.runner.priorityClassName`) |

Rules of thumb:

- **Connections**: every server replica opens up to `server.database.maxConnections` (10). Keep
  `replicas × 10 + Polis (≈10) + 20` under PostgreSQL's `max_connections` (200 by default here).
- **Cloud sessions** dominate the footprint: one agent session ≈ 0.25-2 CPU and 0.5-2 GiB while it works. Plan
  nodes for (sessions the plans allow at once) × limits, and keep sessions on their own nodes in a shared cluster.
- **HPA** needs metrics-server. Without it keep `autoscaling.enabled: false` and fixed replicas.
- **Disk**: PostgreSQL grows with receipts and audit events (≈ 1-2 KB per gated action). 20 Gi holds tens of millions.
- **Docker Compose**: 2 vCPU / 4 GB for up to ~50 people, without cloud sessions.
