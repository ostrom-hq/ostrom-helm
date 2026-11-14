# Images and signatures

| Image | What | Base |
|---|---|---|
| `docker.io/ostromhq/ostrom-server` | the native server binary | `gcr.io/distroless/cc-debian12:nonroot` |
| `docker.io/ostromhq/ostrom-web` | the console (static files + nginx) | `nginxinc/nginx-unprivileged` (alpine) |
| `docker.io/ostromhq/ostrom-site` | the site (Next.js static export + nginx) | `nginxinc/nginx-unprivileged` (alpine) |
| `docker.io/ostromhq/ostrom-runner` | cloud sessions: the `ostrom` CLI, Claude Code, Codex, git | `debian:12-slim` |

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
cosign verify --key cosign.pub --insecure-ignore-tlog docker.io/ostromhq/ostrom-server:0.1.0
docker buildx imagetools inspect docker.io/ostromhq/ostrom-server:0.1.0 --format '{{ json .SBOM }}' | head
```

The chart is published as an OCI artifact, `oci://registry-1.docker.io/ostromhq/ostrom`, signed the same way.

## Third-party images

The chart also runs four images it does not build. Each is **pinned by the digest of its multi-arch index** by
default, so a tag rewritten upstream never reaches your cluster:

| Value | Image | Runs |
|---|---|---|
| `postgresql.image` | `docker.io/library/postgres:17.6` | PostgreSQL, its backup CronJob, the roles Job and the database `helm test`: they hold the superuser password |
| `polis.image` | `docker.io/boxyhq/jackson:26.2.0` | Ory Polis (off by default) |
| `tests.image` | `docker.io/curlimages/curl:8.11.1` | the `helm test` pod |
| `externalDatabase.tls.proxy.image` | `ghcr.io/cloudnative-pg/pgbouncer:1.26.1-202610291052-trixie` | the TLS proxy to an external database (off by default), with the passwords of the serving role and the owner |

`postgresql.image`, `polis.image` and `externalDatabase.tls.proxy.image` take `repository`, `tag` and `digest` (`sha256:` and 64 hex characters); they
render as `repository:tag@digest`, the runtime pulls the digest and the tag stays readable. `digest: ""` follows the
tag. `tests.image` is one full reference (`repository:tag@digest`), checked the same way.

- **Another version**: set the tag **and** its digest, or `digest: ""`. A tag alone (`postgresql.image.tag: "16"`)
  is refused: with the chart's digest it would run 17.6 without a word, and PostgreSQL 17 does not start on a 16
  data directory.
- **A mirror**: set `repository` (or the full `tests.image`) and keep the digest only if the mirror holds the same
  multi-arch index, byte for byte (`skopeo copy --all`, `crane copy`). A mirror filled by `docker pull`, `tag` and
  `push` serves another digest: set that one, or `digest: ""`.
- `global.imagePullPolicy` applies to every image of the chart, these included (`Always` behind a mirror that you
  trust more than the node's cache).
- Renovate moves the tags and the digests together, in `values.yaml` and `compose/docker-compose.yml` in one pull
  request; the chart's table of its own pins (`ostrom.thirdPartyPins`, `_helpers.tpl`, a `# renovate:` comment per
  line) moves with them, or the unit tests fail.
