#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Local demo: what a running cloud session's containers can reach (journey.mjs runs it, OSTROM_DEMO_SESSION_CHECK).
# Given SESSION_ID, checks on the engine that:
#   - the session runs as three containers, the agent host and the check host (UID 1001) and the runner (UID 1000),
#     TeamCode's image contract since ostrom-server#494, on ostrom-sessions only (the check host runs the hooks'
#     checks, `isolated_runner`, ostrom-server#130);
#   - the agent's container does not mount the check socket's volume, so it cannot ask a check of its own (the
#     `-bin` volume of the delivered `ostrom` binary, read-only in all three by design, is not a socket: left out);
#   - from the agent's container, the server answers; the database and the Docker engine proxy do not resolve; this
#     machine's published ports and the internet do not answer.
set -eu
hex=$(printf %s "$SESSION_ID" | tr -d '-')
# The delivery container (`…-bin`) copies the `ostrom` binary into its volume and exits: not one of the three.
ids=$(docker ps --filter "label=ostrom.run/session=$hex" --format '{{.ID}} {{.Names}}' | grep -v -- '-bin$' | cut -d' ' -f1)
count=$(printf '%s\n' "$ids" | grep -c . || true)
[ "$count" = 3 ] || { echo "expected 3 containers for the session (agent, check host, runner), found $count"; exit 1; }
for id in $ids; do
  networks=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$id")
  [ "$networks" = "ostrom-sessions " ] || { echo "container $id on: $networks"; exit 1; }
done
agent=$(docker ps -q --filter "label=ostrom.run/session=$hex" --filter "name=-agent")
[ "$(docker exec "$agent" id -u)" = 1001 ] || { echo "the agent does not run as 1001"; exit 1; }
checks=$(docker ps -q --filter "label=ostrom.run/session=$hex" --filter "name=-checks")
[ -n "$checks" ] || { echo "no check host container"; exit 1; }
[ "$(docker exec "$checks" id -u)" = 1001 ] || { echo "the check host does not run as 1001"; exit 1; }
# The check socket's volume is the one the check host and the runner share; the agent must not mount it.
# The runner's container is the execution's own name, without a suffix: the one that is neither of the others.
runner=$(printf '%s\n' "$ids" | grep -vx -e "$agent" -e "$checks")
# The user the engine started the runner as (its image need not have `id`).
[ "$(docker inspect -f '{{.Config.User}}' "$runner" | cut -d: -f1)" = 1000 ] || { echo "the runner does not run as 1000"; exit 1; }
volumes() { docker inspect -f '{{range .Mounts}}{{if .Name}}{{.Name}}{{"\n"}}{{end}}{{end}}' "$1" | grep -v -- '-bin$' | sort -u; }
shared=$(volumes "$checks" | while read -r v; do volumes "$runner" | grep -qx "$v" && echo "$v"; done)
[ -n "$shared" ] || { echo "the check host and the runner share no volume: no check socket found"; exit 1; }
for v in $shared; do
  if volumes "$agent" | grep -qx "$v"; then echo "the agent mounts the check socket ($v)"; exit 1; fi
done
# The delivered binary's volume, when there is one (ostrom-server#557), is read-only in each of the three.
for id in $ids; do
  rw=$(docker inspect -f '{{range .Mounts}}{{if .RW}}{{.Name}}{{"\n"}}{{end}}{{end}}' "$id" | grep -- '-bin$' || true)
  [ -z "$rw" ] || { echo "container $id mounts the delivered binary read-write ($rw)"; exit 1; }
done
docker exec "$agent" sh -c 'curl -fsS -m 5 http://server:8080/health' | grep -q '"status":"ok"' || { echo "the agent cannot reach the server"; exit 1; }
for host in postgres docker-api; do
  if docker exec "$agent" getent hosts "$host" > /dev/null 2>&1; then echo "the agent resolves $host"; exit 1; fi
done
# Nothing outside the network: this machine's published ports (Caddy, so the Mailpit inbox) nor the internet.
for url in http://host.docker.internal/ http://1.1.1.1/; do
  if docker exec "$agent" curl -s -o /dev/null -m 5 "$url"; then echo "the agent reaches $url"; exit 1; fi
done
echo "3 containers (agent, check host, runner) on ostrom-sessions only, agent and check host UID 1001, runner UID 1000, the check socket not in the agent's mounts; server reachable; postgres, docker-api, the host and the internet unreachable"
