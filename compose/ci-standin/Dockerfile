# CI only: the shape of the ostrom-server image (same binary path, same ENTRYPOINT) around a fake CLI, so that the
# Compose test runs the `command` of docker-compose.yml exactly as the real image would.
FROM docker.io/library/busybox:1.37
COPY --chmod=0755 ostrom-server /usr/local/bin/ostrom-server
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/ostrom-server"]
