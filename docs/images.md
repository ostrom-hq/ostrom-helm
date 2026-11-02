# Images and signatures

| Image | What | Base |
|---|---|---|
| `ghcr.io/ostrom-hq/ostrom-server` | the native server binary | `gcr.io/distroless/cc-debian12:nonroot` |
| `ghcr.io/ostrom-hq/ostrom-web` | the console (static files + nginx) | `nginxinc/nginx-unprivileged` (alpine) |
| `ghcr.io/ostrom-hq/ostrom-site` | the site (Next.js static export + nginx) | `nginxinc/nginx-unprivileged` (alpine) |
| `ghcr.io/ostrom-hq/ostrom-runner` | cloud sessions: the `ostrom` CLI, Claude Code, Codex, git | `debian:12-slim` |

All are built for `linux/amd64` and `linux/arm64`, tagged `<version>`, `<major>.<minor>` and `latest` on a release
(`edge` from `main`), carry an SPDX SBOM and SLSA provenance as attestations, and are **signed with cosign** by
digest. The signing key is Ostrom's (not keyless while the repositories are private):

```
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAENbn5GmwW348HxCtTPQbNfcvHmSZG
G+IBNKubzv51TIua776a3875eoe5isQYKYmVwe5yTUU0v2k8Pu7WXQWoBg==
-----END PUBLIC KEY-----
```

Verify before deploying:

```sh
cosign verify --key cosign.pub --insecure-ignore-tlog ghcr.io/ostrom-hq/ostrom-server:0.1.0
docker buildx imagetools inspect ghcr.io/ostrom-hq/ostrom-server:0.1.0 --format '{{ json .SBOM }}' | head
```

The chart is published as an OCI artifact, `oci://ghcr.io/ostrom-hq/charts/ostrom`, signed the same way.

## Third-party images

The chart also runs three images it does not build. Each is **pinned by the digest of its multi-arch index** by
default, so a tag rewritten upstream never reaches your cluster:

| Value | Image | Runs |
|---|---|---|
| `postgresql.image` | `docker.io/library/postgres:17.6` | PostgreSQL, its backup CronJob, the roles Job and the database `helm test`: they hold the superuser password |
| `polis.image` | `docker.io/boxyhq/jackson:26.2.0` | Ory Polis (off by default) |
| `tests.image` | `docker.io/curlimages/curl:8.11.1` | the `helm test` pod |

`postgresql.image` and `polis.image` take `repository`, `tag` and `digest` (`sha256:` and 64 hex characters); the
digest wins over the tag, and `digest: ""` follows the tag. `tests.image` is one full reference. To pull them from
your own mirror, set `repository` (or the full `tests.image`) to the mirror and keep the digest: a mirror serves the
same digest. `global.imagePullPolicy` applies to every image of the chart, these included (`Always` behind a mirror
that you trust more than the node's cache). Renovate moves the tags and the digests together.
