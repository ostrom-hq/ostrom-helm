#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# The local demo stack (docker-compose.demo.yml): Ostrom whole on this machine, no real outside service.
# Usage: demo/demo.sh up | journey | down | logs
#   up       fresh secrets in .env (install.sh), then the stack; Stripe's test mode too when OSTROM_DEMO_STRIPE_KEY_FILE
#            names a test key file (mode 600, outside git)
#   journey  the customer's journey against it (journey.mjs), report in demo-report.md
#   down     stops it and removes its containers, volumes and the cloud sessions' containers and volumes
set -eu
cd "$(dirname "$0")/.."
files="-f docker-compose.yml -f demo/docker-compose.demo.yml"
if [ -n "${OSTROM_DEMO_STRIPE_KEY_FILE:-}" ]; then files="$files -f demo/docker-compose.demo-stripe.yml"; fi
# shellcheck disable=SC2086
dc() { docker compose $files "$@"; }
case "${1:-up}" in
  up)
    ./install.sh --no-start
    dc up -d --wait
    echo "Console http://app.localhost · API http://api.localhost · mails http://mail.localhost · GitHub (fake) http://github.localtest.me"
    ;;
  journey) node demo/journey.mjs ;;
  # Every service but the Stripe CLI's, whose log holds its webhook signing secret.
  logs)
    # shellcheck disable=SC2046 # one service name per word
    dc logs --no-color --tail "${2:-200}" $(dc config --services | grep -v '^stripe-')
    ;;
  down)
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
    ;;
  *) echo "usage: demo/demo.sh up|journey|down|logs" >&2; exit 2 ;;
esac
