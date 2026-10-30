# Images and signatures

| Image | What | Base |
|---|---|---|
| `ghcr.io/ostrom-hq/ostrom-server` | the native server binary | `gcr.io/distroless/cc-debian12:nonroot` |
| `ghcr.io/ostrom-hq/ostrom-web` | the console (static files + nginx) | `nginxinc/nginx-unprivileged` (alpine) |
| `ghcr.io/ostrom-hq/ostrom-site` | the site (Next.js standalone) | `gcr.io/distroless/nodejs24-debian12:nonroot` |
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
