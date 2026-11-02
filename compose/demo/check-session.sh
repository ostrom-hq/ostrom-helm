#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Local demo: what a running cloud session's containers can reach (journey.mjs runs it, OSTROM_DEMO_SESSION_CHECK).
# Given SESSION_ID, checks on the engine that:
#   - the session runs as two containers, the agent host (UID 1000) and the runner (UID 1001), on ostrom-sessions only;
#   - from the agent's container, the server answers; the database and the Docker engine proxy do not resolve; this
#     machine's published ports and the internet do not answer.
set -eu
hex=$(printf %s "$SESSION_ID" | tr -d '-')
ids=$(docker ps -q --filter "label=ostrom.run/session=$hex")
count=$(printf '%s\n' "$ids" | grep -c . || true)
[ "$count" = 2 ] || { echo "expected 2 containers for the session, found $count"; exit 1; }
for id in $ids; do
  networks=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$id")
  [ "$networks" = "ostrom-sessions " ] || { echo "container $id on: $networks"; exit 1; }
done
agent=$(docker ps -q --filter "label=ostrom.run/session=$hex" --filter "name=-agent")
[ "$(docker exec "$agent" id -u)" = 1000 ] || { echo "the agent does not run as 1000"; exit 1; }
docker exec "$agent" sh -c 'curl -fsS -m 5 http://server:8080/health' | grep -q '"status":"ok"' || { echo "the agent cannot reach the server"; exit 1; }
for host in postgres docker-api; do
  if docker exec "$agent" getent hosts "$host" > /dev/null 2>&1; then echo "the agent resolves $host"; exit 1; fi
done
# Nothing outside the network: this machine's published ports (Caddy, so the Mailpit inbox) nor the internet.
for url in http://host.docker.internal/ http://1.1.1.1/; do
  if docker exec "$agent" curl -s -o /dev/null -m 5 "$url"; then echo "the agent reaches $url"; exit 1; fi
done
echo "2 containers on ostrom-sessions only, agent UID 1000, server reachable; postgres, docker-api, the host and the internet unreachable"
