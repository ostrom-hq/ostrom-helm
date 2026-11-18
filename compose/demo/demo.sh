#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# The local demo stack (docker-compose.demo.yml): Ostrom whole on this machine, no real outside service.
# Usage: ./demo up | bootstrap | journey | down | logs        (from the repository's root; compose/demo/demo.sh is the same)
#   up       checks this machine (Docker running, its memory, the ports), takes the images of main (the last
#            ones published: OSTROM_DEMO_IMAGES=pinned takes docker-compose.yml's pins instead), fresh secrets in .env
#            (install.sh), then the stack, waits until it answers and prints its addresses and how to sign in. Stripe's
#            test mode too when OSTROM_DEMO_STRIPE_KEY_FILE names a test key file (mode 600, outside git)
#   bootstrap  prints the first owner's one-time setup link (the instance is invite-only until it is used)
#   journey  the customer's journey against it (journey.mjs, with check-session.sh and teamcode/check.sh), report in
#            compose/demo-report.md; needs Node 22 or later
#   down     stops it and removes its containers, volumes and the cloud sessions' containers and volumes
# OSTROM_SERVER_IMAGE, OSTROM_WEB_IMAGE and OSTROM_RUNNER_IMAGE, when set, win over the images `up` would take.
set -eu
cd "$(dirname "$0")/.."
# The images `up` took, for the commands that follow it on the same stack (journey, logs, down). Gitignored.
images_file=demo/.images.env
# Those commands run the stack `up` composed, Stripe's overlay included, whatever this shell has set.
# shellcheck source=/dev/null
case "${1:-up}" in up) ;; *) [ ! -f "$images_file" ] || . "./$images_file" ;; esac
files="-f docker-compose.yml -f demo/docker-compose.demo.yml"
if [ -n "${OSTROM_DEMO_STRIPE_KEY_FILE:-}" ]; then files="$files -f demo/docker-compose.demo-stripe.yml"; fi
# shellcheck disable=SC2086
dc() { docker compose $files "$@"; }
die() { echo "demo: $*" >&2; exit 1; }

REGISTRY=docker.io/ostromhq
DEFAULT_RUNNER_IMAGE=$REGISTRY/ostrom-runner:latest
# Below this, Docker's memory (Docker Desktop: Settings > Resources > Memory) does not hold the stack and a session.
MIN_MEMORY_MIB=${OSTROM_DEMO_MIN_MEMORY_MIB:-3072}

need_docker() {
  command -v docker > /dev/null 2>&1 || die "Docker is required: Docker Desktop on a Mac (https://www.docker.com/products/docker-desktop/), Docker Engine on Linux"
  docker info > /dev/null 2>&1 || die "Docker is not running: start Docker Desktop (or the Docker service), then run this again"
  v=$(docker compose version --short 2> /dev/null | sed 's/^v//') || true
  major=${v%%.*}; rest=${v#*.}; minor=${rest%%.*}
  case "$major$minor" in '' | *[!0-9]*) die "Docker Compose v2.24 or later is required (docker compose version)" ;; esac
  [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 24 ]; } ||
    die "Docker Compose $v is too old: 2.24 or later is required (update Docker Desktop)"
}

memory() {
  mem=$(docker info --format '{{.MemTotal}}')
  mib=$((mem / 1048576))
  [ "$mib" -ge "$MIN_MEMORY_MIB" ] ||
    die "Docker has ${mib} MiB of memory, the demo needs ${MIN_MEMORY_MIB} MiB: Docker Desktop > Settings > Resources > Memory, 4 GB or more, then Apply & restart"
  echo "Docker: $(docker info --format '{{.OperatingSystem}}, {{.Architecture}}'), ${mib} MiB of memory"
}

# pull IMAGE: pulls it, or says why not (the images on docker.io/ostromhq are public: no login).
pull() {
  err=$(docker pull -q "$1" 2>&1 > /dev/null) && return 0
  die "could not pull $1: $err"
}

# The image's digest in its repository (what Compose then runs), and the commit it was built from when it says.
# Docker lists a docker.io image's digests under its short name (ostromhq/x@sha256:...): matched with or without the
# prefix, given back under the name asked for.
digest_of() {
  name=${1%%[:@]*}; short=${name#docker.io/}; short=${short#library/}
  docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$1" |
    sed -n "s|^\(docker\.io/\)\{0,1\}$short@|$name@|p" | head -n 1 | grep . || die "no digest for $1 (an image built here, not pulled?)"
}
# Only for Ostrom's published images: one built here may carry its base image's revision label.
revision_of() {
  r=
  case "$1" in docker.io/ostromhq/*) r=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$1" 2> /dev/null || true) ;; esac
  case "$r" in
    '' | '<no value>') case "$1" in *@sha256:*) echo "sha256:$(echo "${1##*@sha256:}" | cut -c1-12)" ;; *) echo "$1" ;; esac ;;
    *) echo "commit $(echo "$r" | cut -c1-7)" ;;
  esac
}
# main's last published image of a repository: the server's `latest` and the console's `edge`, which move to the head of
# main once its image run is done.
main_image() { pull "$REGISTRY/$1:$2"; digest_of "$REGISTRY/$1:$2"; }
# shellcheck disable=SC2016 # the line is written for the shell that sources the file
keep() { [ -z "$2" ] || printf ': "${%s:=%s}"; export %s\n' "$1" "$2" "$1"; }

# Server, console and session images: OSTROM_*_IMAGE when set; otherwise main's last published images (the runner's
# `latest`, pushed from main), or the pins of docker-compose.yml with OSTROM_DEMO_IMAGES=pinned. Each is pulled here,
# resolved to its digest and written down for the next commands.
choose_images() {
  mode=${OSTROM_DEMO_IMAGES:-main}
  case "$mode" in main | pinned) ;; *) die "OSTROM_DEMO_IMAGES is main (default) or pinned, not $mode" ;; esac
  if [ "$mode" = main ]; then
    [ -n "${OSTROM_SERVER_IMAGE:-}" ] || OSTROM_SERVER_IMAGE=$(main_image ostrom-server latest) || exit 1
    [ -n "${OSTROM_WEB_IMAGE:-}" ] || OSTROM_WEB_IMAGE=$(main_image ostrom-web edge) || exit 1
  fi
  export OSTROM_SERVER_IMAGE="${OSTROM_SERVER_IMAGE:-}" OSTROM_WEB_IMAGE="${OSTROM_WEB_IMAGE:-}"
  # Everything Compose runs from docker.io/ostromhq (the pins, or what was just chosen), then the sessions' runner
  # image. All are multi-arch (linux/amd64 and linux/arm64) and run natively, on Apple silicon too.
  for image in $(dc config --images | grep '^docker.io/ostromhq/' | sort -u); do pull "$image"; done
  OSTROM_RUNNER_IMAGE=${OSTROM_RUNNER_IMAGE:-$DEFAULT_RUNNER_IMAGE}
  pull "$OSTROM_RUNNER_IMAGE"
  case "$OSTROM_RUNNER_IMAGE" in *@sha256:*) ;; *) OSTROM_RUNNER_IMAGE=$(digest_of "$OSTROM_RUNNER_IMAGE") ;; esac
  export OSTROM_RUNNER_IMAGE
  {
    echo "# Written by demo.sh up on $(date -u +%Y-%m-%dT%H:%M:%SZ): the images of this stack."
    keep OSTROM_SERVER_IMAGE "$OSTROM_SERVER_IMAGE"
    keep OSTROM_WEB_IMAGE "$OSTROM_WEB_IMAGE"
    keep OSTROM_RUNNER_IMAGE "$OSTROM_RUNNER_IMAGE"
    keep OSTROM_DEMO_STRIPE_KEY_FILE "${OSTROM_DEMO_STRIPE_KEY_FILE:-}"
  } > "$images_file"
}

# Port 80 for Caddy (the demo's names have no port, so no other port will do), 443, and 3307 for the fake TeamCode
# base, unless this stack already holds them (an earlier `up`, whole or cut short).
ports() {
  case "${OSTROM_HTTP_PORT:-80}/${OSTROM_HTTPS_PORT:-443}" in 80/443) ;; *) die "the demo's addresses have no port: it runs on ports 80 and 443 only (unset OSTROM_HTTP_PORT and OSTROM_HTTPS_PORT)" ;; esac
  [ -z "$(dc ps -q 2> /dev/null)" ] || return 0
  command -v nc > /dev/null 2>&1 || return 0
  for port in 80 443 3307; do
    if nc -z -w 1 127.0.0.1 "$port" 2> /dev/null; then
      die "port $port of this machine is taken (\`lsof -nP -iTCP:$port -sTCP:LISTEN\` says by what): stop it, then run this again"
    fi
  done
}

# The demo's names must answer this machine: macOS and most Linux resolve *.localhost themselves, github.localtest.me
# comes from public DNS. The fix when they do not: one line in /etc/hosts.
names() {
  command -v node > /dev/null 2>&1 || return 0
  bad=$(node -e 'const dns = require("node:dns");
Promise.all(process.argv.slice(1).map((h) => dns.promises.lookup(h, { all: true })
  .then((a) => (a.some((x) => x.address === "127.0.0.1" || x.address === "::1") ? "" : h), () => h)))
  .then((r) => console.log(r.filter(Boolean).join(" ")));' "$API_HOST" "$APP_HOST" "$MAIL_HOST" github.localtest.me)
  [ -z "$bad" ] && return 0
  echo "demo: these names do not answer 127.0.0.1 on this machine: $bad. Add them once:" >&2
  echo "  echo '127.0.0.1 $bad' | sudo tee -a /etc/hosts" >&2
  return 1
}

hosts() {
  # shellcheck source=/dev/null
  . ./.env
  SCHEME=${OSTROM_SCHEME:-http}; API_HOST=${OSTROM_API_HOST:-api.localhost}; APP_HOST=${OSTROM_APP_HOST:-app.localhost}
  MAIL_HOST=${OSTROM_MAIL_HOST:-mail.localhost}
}

# Until the server is ready behind Caddy and the console answers (curl resolves *.localhost itself).
healthy() {
  for _ in $(seq 1 90); do
    if curl -fsS -m 5 "$SCHEME://$API_HOST/ready" 2> /dev/null | grep -q '"status":"ready"' &&
      curl -fsS -m 5 -o /dev/null "$SCHEME://$APP_HOST/"; then
      return 0
    fi
    sleep 2
  done
  dc ps >&2
  die "the stack did not become ready in 3 minutes: ./demo logs shows why"
}

# The memory each container of the stack and of the cloud sessions uses now, and their total.
memory_used() {
  ids="$(dc ps -q) $(docker ps -q --filter label=app.kubernetes.io/managed-by=ostrom)"
  # Without an id, docker stats would list every container of this machine.
  [ -n "$(echo "$ids" | tr -d ' ')" ] || return 0
  # shellcheck disable=SC2086 # one id per word
  docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' $ids 2> /dev/null |
    awk '{ u = $2; n = u + 0; if (u ~ /GiB/) n *= 1024; else if (u ~ /KiB/) n /= 1024; else if (u !~ /MiB/) n /= 1048576
           t += n; printf "  %-34s %s\n", $1, u } END { printf "  %-34s %.0f MiB\n", "total", t }' || true
}

case "${1:-up}" in
  up)
    need_docker
    memory
    ./install.sh --no-start
    hosts
    ports
    choose_images
    names || true
    dc up -d --wait
    healthy
    echo
    images=$(dc config --images)
    echo "Ostrom's demo is up: server $(revision_of "$(echo "$images" | grep -m1 -E '/ostrom-server[:@]')"), console $(revision_of "$(echo "$images" | grep -m1 -E '/ostrom-web[:@]')"), cloud sessions $(revision_of "$OSTROM_RUNNER_IMAGE")"
    echo "Memory used now:"
    memory_used
    cat << EOF

  Console      $SCHEME://$APP_HOST
               Invite-only: ./demo bootstrap prints the first owner's one-time setup link. Open it, then « Continue
               with GitHub » (the fake GitHub signs you in as the login you type; alice and rev are the fake TeamCode
               team's members, for the import) or an e-mail link (in the inbox below). Invite the others from the
               console. No real account anywhere.
  Inbox        $SCHEME://$MAIL_HOST
  API          $SCHEME://$API_HOST
  Fake GitHub  http://github.localtest.me
  TeamCode     mysql://teamcode_ro@127.0.0.1:3307/teamcode, password demo-teamcode-ro, key compose/demo/teamcode/key.txt

Next: ./demo journey (the customer's journey, report in compose/demo-report.md), then ./demo down.
EOF
    ;;
  bootstrap)
    dc exec -T server ostrom-server bootstrap
    ;;
  journey)
    command -v node > /dev/null 2>&1 || die "the journey needs Node 22 or later (brew install node)"
    [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 22 ] || die "the journey needs Node 22 or later, not $(node -v)"
    hosts
    names || exit 1
    OSTROM_DEMO_SESSION_CHECK=${OSTROM_DEMO_SESSION_CHECK-demo/check-session.sh} \
      OSTROM_DEMO_TEAMCODE_CHECK=${OSTROM_DEMO_TEAMCODE_CHECK-demo/teamcode/check.sh} \
      OSTROM_DEMO_RUNNER_IMAGE=${OSTROM_DEMO_RUNNER_IMAGE:-${OSTROM_RUNNER_IMAGE:-}} node demo/journey.mjs
    ;;
  # Every service but the Stripe CLI's, whose log holds its webhook signing secret.
  logs)
    # shellcheck disable=SC2046 # one service name per word
    dc logs --no-color --tail "${2:-200}" $(dc config --services | grep -v '^stripe-')
    ;;
  down)
    if [ -n "$(dc ps -q 2> /dev/null)" ]; then
      echo "Memory used before stopping:"
      memory_used
    fi
    # First the cloud sessions' containers, which the server created through the engine (label managed-by): they sit
    # on ostrom-sessions, which Compose cannot remove while they are attached.
    ids=$(docker ps -aq --filter label=app.kubernetes.io/managed-by=ostrom)
    # shellcheck disable=SC2086 # one id per word
    [ -z "$ids" ] || docker rm -f $ids > /dev/null
    dc down --volumes --remove-orphans
    vols=$(docker volume ls -q --filter label=app.kubernetes.io/managed-by=ostrom)
    # shellcheck disable=SC2086 # one name per word
    [ -z "$vols" ] || docker volume rm $vols > /dev/null
    # The Stripe volume (the test key and webhook secret) even when this down runs without the Stripe file.
    docker volume rm -f ostrom_stripe > /dev/null
    rm -f "$images_file"
    ;;
  *) echo "usage: ./demo up|bootstrap|journey|down|logs" >&2; exit 2 ;;
esac
