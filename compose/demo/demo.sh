#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# The local demo stack (docker-compose.demo.yml): Ostrom whole on this machine, no real outside service.
# Usage: ./demo up | journey | down | logs        (from the repository's root; compose/demo/demo.sh is the same)
#   up       checks this machine (Docker running, its memory, the ports, ghcr.io), takes the images of main (the last
#            ones published: OSTROM_DEMO_IMAGES=pinned takes docker-compose.yml's pins instead), fresh secrets in .env
#            (install.sh), then the stack, waits until it answers and prints its addresses and how to sign in. Stripe's
#            test mode too when OSTROM_DEMO_STRIPE_KEY_FILE names a test key file (mode 600, outside git)
#   journey  the customer's journey against it (journey.mjs, with check-session.sh and teamcode/check.sh), report in
#            compose/demo-report.md; needs Node 22 or later
#   down     stops it and removes its containers, volumes and the cloud sessions' containers and volumes
# OSTROM_SERVER_IMAGE, OSTROM_WEB_IMAGE and OSTROM_RUNNER_IMAGE, when set, win over the images `up` would take.
set -eu
cd "$(dirname "$0")/.."
files="-f docker-compose.yml -f demo/docker-compose.demo.yml"
if [ -n "${OSTROM_DEMO_STRIPE_KEY_FILE:-}" ]; then files="$files -f demo/docker-compose.demo-stripe.yml"; fi
# shellcheck disable=SC2086
dc() { docker compose $files "$@"; }
die() { echo "demo: $*" >&2; exit 1; }

# The images `up` took, for the commands that follow it on the same stack (journey, logs, down). Gitignored.
images_file=demo/.images.env
REGISTRY=ghcr.io/ostrom-hq
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

# The private packages of ghcr.io/ostrom-hq: a member of the org reads them once logged in with a token that has
# read:packages. With the GitHub CLI already allowed to, the login is done here; otherwise the two commands to type.
login_help() {
  cat >&2 << 'EOF'
demo: cannot read ghcr.io/ostrom-hq (the images are private packages of the organization). Once, as a member of
ostrom-hq, with the GitHub CLI (brew install gh):
  gh auth refresh -h github.com -s read:packages
  gh auth token | docker login ghcr.io -u "$(gh api user -q .login)" --password-stdin
then run this again. Without the GitHub CLI: a classic token with read:packages (github.com/settings/tokens), given
to `docker login ghcr.io -u <your login> --password-stdin`.
EOF
  exit 1
}

gh_login() {
  command -v gh > /dev/null 2>&1 || return 1
  gh auth status -h github.com 2>&1 | grep -qE "(read|write):packages" || return 1
  echo "Logging Docker in to ghcr.io with the GitHub CLI's token (read:packages)" >&2
  gh auth token -h github.com | docker login ghcr.io -u "$(gh api user -q .login)" --password-stdin > /dev/null
}

# pull IMAGE [PLATFORM]: pulls it; refused by ghcr.io, logs in once with the GitHub CLI and tries again, or explains.
pull() {
  err=$(docker pull -q ${2:+--platform "$2"} "$1" 2>&1 > /dev/null) && return 0
  case "$1" in
    ghcr.io/*)
      if printf %s "$err" | grep -qiE 'denied|unauthorized|authentication required' && gh_login; then
        err=$(docker pull -q ${2:+--platform "$2"} "$1" 2>&1 > /dev/null) && return 0
      fi
      echo "$err" >&2
      login_help
      ;;
  esac
  die "could not pull $1: $err"
}

# The image's digest in its repository (what Compose then runs), and the commit it was built from when it says.
digest_of() { docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$1" | grep -m1 "^${1%%[:@]*}@"; }
# Only for Ostrom's published images: one built here may carry its base image's revision label.
revision_of() {
  r=
  case "$1" in ghcr.io/*) r=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$1" 2> /dev/null || true) ;; esac
  case "$r" in
    '' | '<no value>') case "$1" in *@sha256:*) echo "sha256:$(echo "${1##*@sha256:}" | cut -c1-12)" ;; *) echo "$1" ;; esac ;;
    *) echo "commit $(echo "$r" | cut -c1-7)" ;;
  esac
}
# main's last published image of a repository: `edge`, which moves to the head of main once its Image run is done.
main_image() { pull "$REGISTRY/$1:edge"; digest_of "$REGISTRY/$1:edge"; }
# shellcheck disable=SC2016 # the line is written for the shell that sources the file
keep() { [ -z "$2" ] || printf ': "${%s:=%s}"; export %s\n' "$1" "$2" "$1"; }

# Server, console and session images: OSTROM_*_IMAGE when set; otherwise main's last published images (the runner's
# `latest`, pushed from main), or the pins of docker-compose.yml with OSTROM_DEMO_IMAGES=pinned. Each is pulled here,
# resolved to its digest and written down for the next commands.
choose_images() {
  mode=${OSTROM_DEMO_IMAGES:-main}
  case "$mode" in main | pinned) ;; *) die "OSTROM_DEMO_IMAGES is main (default) or pinned, not $mode" ;; esac
  if [ "$mode" = main ]; then
    [ -n "${OSTROM_SERVER_IMAGE:-}" ] || OSTROM_SERVER_IMAGE=$(main_image ostrom-server) || exit 1
    [ -n "${OSTROM_WEB_IMAGE:-}" ] || OSTROM_WEB_IMAGE=$(main_image ostrom-web) || exit 1
  fi
  export OSTROM_SERVER_IMAGE="${OSTROM_SERVER_IMAGE:-}" OSTROM_WEB_IMAGE="${OSTROM_WEB_IMAGE:-}"
  # Everything Compose runs from ghcr.io (the pins, or what was just chosen), then the sessions' image. The runner is
  # built for linux/amd64 only: on Apple silicon, Docker Desktop runs it under Rosetta (or QEMU). The other images
  # are multi-arch (linux/amd64 and linux/arm64) and run natively.
  for image in $(dc config --images | grep '^ghcr.io/' | sort -u); do pull "$image"; done
  OSTROM_RUNNER_IMAGE=${OSTROM_RUNNER_IMAGE:-$DEFAULT_RUNNER_IMAGE}
  pull "$OSTROM_RUNNER_IMAGE" linux/amd64
  case "$OSTROM_RUNNER_IMAGE" in *@sha256:*) ;; *) OSTROM_RUNNER_IMAGE=$(digest_of "$OSTROM_RUNNER_IMAGE") ;; esac
  export OSTROM_RUNNER_IMAGE
  arch=$(docker run --rm --platform linux/amd64 --entrypoint sh "$OSTROM_RUNNER_IMAGE" -c 'uname -m' 2>&1) || arch=failed
  [ "$arch" = x86_64 ] || die "this Docker cannot run linux/amd64 containers ($arch), which cloud sessions need: Docker Desktop > Settings > General > « Use Rosetta for x86_64/amd64 emulation on Apple Silicon », then Apply & restart"
  {
    echo "# Written by demo.sh up on $(date -u +%Y-%m-%dT%H:%M:%SZ): the images of this stack."
    keep OSTROM_SERVER_IMAGE "$OSTROM_SERVER_IMAGE"
    keep OSTROM_WEB_IMAGE "$OSTROM_WEB_IMAGE"
    keep OSTROM_RUNNER_IMAGE "$OSTROM_RUNNER_IMAGE"
  } > "$images_file"
}

# Port 80 for Caddy (the demo's names have no port), 443, and 3307 for the fake TeamCode base, unless this stack
# already holds them.
ports() {
  [ -z "$(dc ps -q caddy 2> /dev/null)" ] || return 0
  command -v nc > /dev/null 2>&1 || return 0
  for port in "${OSTROM_HTTP_PORT:-80}" "${OSTROM_HTTPS_PORT:-443}" 3307; do
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
  # shellcheck disable=SC2046 # one id per word
  docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' $(dc ps -q) $(docker ps -q --filter label=app.kubernetes.io/managed-by=ostrom) 2> /dev/null |
    awk '{ u = $2; n = u + 0; if (u ~ /GiB/) n *= 1024; else if (u ~ /KiB/) n /= 1024; else if (u !~ /MiB/) n /= 1048576
           t += n; printf "  %-34s %s\n", $1, u } END { printf "  %-34s %.0f MiB\n", "total", t }' || true
}

case "${1:-up}" in
  up)
    need_docker
    memory
    ./install.sh --no-start
    hosts
    choose_images
    ports
    names || true
    dc up -d --wait
    healthy
    echo
    echo "Ostrom's demo is up: server $(revision_of "$(dc config --images | grep -m1 ostrom-server)"), console $(revision_of "$(dc config --images | grep -m1 ostrom-web)"), cloud sessions $(revision_of "$OSTROM_RUNNER_IMAGE")"
    echo "Memory used now:"
    memory_used
    cat << EOF

  Console      $SCHEME://$APP_HOST
               « Sign up » with any e-mail address: the sign-in link arrives in the inbox below. Or « Continue with
               GitHub »: the fake GitHub signs you in as the login you type (alice and rev are the fake TeamCode
               team's members, for the import). No real account anywhere.
  Inbox        $SCHEME://$MAIL_HOST
  API          $SCHEME://$API_HOST
  Fake GitHub  http://github.localtest.me
  TeamCode     mysql://teamcode_ro@127.0.0.1:3307/teamcode, password demo-teamcode-ro, key compose/demo/teamcode/key.txt

Next: ./demo journey (the customer's journey, report in compose/demo-report.md), then ./demo down.
EOF
    ;;
  journey)
    command -v node > /dev/null 2>&1 || die "the journey needs Node 22 or later (brew install node)"
    [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 22 ] || die "the journey needs Node 22 or later, not $(node -v)"
    # shellcheck source=/dev/null
    [ ! -f "$images_file" ] || . "./$images_file"
    hosts
    names || exit 1
    OSTROM_DEMO_SESSION_CHECK=${OSTROM_DEMO_SESSION_CHECK-demo/check-session.sh} \
      OSTROM_DEMO_TEAMCODE_CHECK=${OSTROM_DEMO_TEAMCODE_CHECK-demo/teamcode/check.sh} \
      OSTROM_DEMO_RUNNER_IMAGE=${OSTROM_DEMO_RUNNER_IMAGE:-${OSTROM_RUNNER_IMAGE:-}} node demo/journey.mjs
    ;;
  # Every service but the Stripe CLI's, whose log holds its webhook signing secret.
  logs)
    # shellcheck source=/dev/null
    [ ! -f "$images_file" ] || . "./$images_file"
    # shellcheck disable=SC2046 # one service name per word
    dc logs --no-color --tail "${2:-200}" $(dc config --services | grep -v '^stripe-')
    ;;
  down)
    # shellcheck source=/dev/null
    [ ! -f "$images_file" ] || . "./$images_file"
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
  *) echo "usage: ./demo up|journey|down|logs" >&2; exit 2 ;;
esac
