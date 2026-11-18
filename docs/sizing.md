# Sizing

The server runs on the JVM (ostrom-server `docs/decisions/0001`, as TeamCode): about 3 s to start, about 225 MiB at
rest and 340 MiB under a steady 200 req/s with a 256 MiB heap, a p99 of 6.8 ms there (ostrom-server#394, run
43444036220, on one runner). The chart's defaults follow: 512 Mi requested, 1 Gi limit, the heap at 70 % of the limit
(`server.javaToolOptions`). The ingress and startup tables below are those of the earlier native binary, to be taken
again on the JVM image; the scaling drill already runs on it.

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
requests below covered them for the native binary (256 MiB limit then).

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

Scaling is measured the same way (`ci/scale-drill.sh`, HPA 2-4, k6 in the namespace on the server's Service, one
2-vCPU kind node shared with PostgreSQL and k6). There are two passes:
- a peak ramps from 10 to 120 requests/s: the HPA must add replicas that become ready and serve, with no failed
  request and no restart;
- a version rollout runs under 50 requests/s: it must lose no request (the server's shutdown delay drains each old
  pod), with no container restart.

What the drill proves:
- the mechanism: the HPA scales up, the new pods become ready and take traffic, and the probes and the rolling
  update hold under load;
- nothing more. The CI's requests are below the defaults, so its HPA reacts sooner than yours, and its threshold is
  not yours.

Run [44350369154](https://github.com/ostrom-hq/ostrom-helm/actions/runs/44350369154), the JVM server (ostrom-server
main, built with jib), probe timeouts explicit, CI requests 50m / 64Mi:

| Pass | Requests | Failed | Replicas |
|---|---|---|---|
| peak to 120 req/s | 19 949 | 0 | the HPA went to 4, all 4 ready, no restart |
| rollout under 50 req/s | 12 000 | 0 | every pod replaced in 41 s, no restart |

Latencies (p95, p99) and the HPA's timings are in that run's job summary. On the earlier native binary (run
41549988209) the rollout pass lost 198 requests to a server container that exited by itself between the peak and the
upgrade; the JVM image does not reproduce it. The drill still records the last termination and the previous logs of
any restart, and a crash before the rollout starts is reported as such.

What it does not prove:
- **300 requests/s is not held on this runner.** On the first run (41545347185, native binary), still with
  Kubernetes' 1 s probe timeouts:
  - 7 100 of 12 013 requests failed;
  - the four replicas went into CrashLoopBackOff;
  - the node itself was saturated.
- No conclusion on real capacity follows from either figure. One node with 2 vCPU says nothing about a cluster
  where replicas get their own CPU.

| Team | Server | Web, site | PostgreSQL | Cloud sessions |
|---|---|---|---|---|
| up to 50 people | 2 × (250m CPU, 512 Mi request / 1 Gi limit) | 2 × default | 250m / 256 Mi, 10 Gi disk | 250m / 512 Mi each, limit 2 CPU / 2 Gi |
| 50-500 | 3 × (250m, 512 Mi / 1 Gi), HPA 3-10 on CPU | 2-4 | 500m / 1 Gi, 50 Gi, `max_connections` ≥ ((HPA max + 1) × (`server.database.maxConnections` + 1) + 20) / 0.8 | same; size the nodes for the sessions the organizations' plans allow |
| 500+ | HPA 4-20, external managed PostgreSQL with backups and a replica | 3-6 | managed | dedicated nodes for sessions, a PriorityClass below your workloads (`cloudSessions.runner.priorityClassName`) |

Rules of thumb:

- **Connections**: every server replica opens up to `server.database.maxConnections` (10, 2 to 64), its one
  JDBC pool, plus one listening connection. The budget (ostrom-server docs/MODULES.md, "Database connections"):
  `(most replicas + 1 surge) × (maxConnections + 1) + 2 migrate + Polis (10 a replica) + 1 backup + 1 exporter +
  3 reserved` at most 80 % of PostgreSQL's `max_connections` (200 by default here): 128 of 160 with the defaults and an
  HPA of 10. The chart refuses to render the bundled PostgreSQL over it; size an external database's the same way.
- **Cloud sessions** dominate the footprint: one agent session ≈ 0.25-2 CPU and 0.5-2 GiB while it works. Plan
  nodes for (sessions the plans allow at once) × limits, and keep sessions on their own nodes in a shared cluster.
- **HPA** needs metrics-server. Without it keep `autoscaling.enabled: false` and fixed replicas.
- **Disk**: PostgreSQL grows with receipts and audit events (≈ 1-2 KB per gated action). 20 Gi holds tens of millions.
- **Docker Compose**: 2 vCPU / 4 GB for up to ~50 people, without cloud sessions.
