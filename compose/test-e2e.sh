#!/bin/sh
# End-to-end test of the Compose install: fresh .env, everything up, each host answers through Caddy,
# secrets are kept on a second run, and the data survives a restart.
# Usage: ./test-e2e.sh [extra compose file]   (CI passes docker-compose.ci.yml while the images are private)
set -eu
cd "$(dirname "$0")"
extra=${1:-}
if [ -n "$extra" ]; then export COMPOSE_FILE="docker-compose.yml:$extra"; fi
export OSTROM_HTTP_PORT="${OSTROM_HTTP_PORT:-8088}"
fail() { echo "FAIL: $*" >&2; docker compose ps -a >&2; docker compose logs --no-color --tail 80 >&2; exit 1; }
get() { curl -fsS --retry 30 --retry-all-errors --retry-delay 2 -H "Host: $1" "http://127.0.0.1:${OSTROM_HTTP_PORT}$2"; }

rm -f .env
./install.sh || fail "install.sh"
grep -Eq '^POSTGRES_PASSWORD=[A-Za-z0-9]{32}$' .env || fail "no generated database password"
[ "$(stat -c %a .env 2>/dev/null || stat -f %Lp .env)" = "600" ] || fail ".env is not private"

get api.localhost /health | grep -q '"status":"ok"' || fail "server through Caddy"
get app.localhost / >/dev/null || fail "console through Caddy"
get sso.localhost /api/health | grep -qi 'version\|healthy\|ok' || fail "Ory Polis through Caddy"

before=$(grep POSTGRES_PASSWORD .env)
./install.sh --no-start
[ "$(grep POSTGRES_PASSWORD .env)" = "$before" ] || fail "second install changed the secrets"

docker compose exec -T postgres psql -U ostrom -d ostrom -c "CREATE TABLE IF NOT EXISTS e2e_marker(x int); INSERT INTO e2e_marker VALUES (42);" >/dev/null
docker compose exec -T postgres psql -U ostrom -lqt | cut -d'|' -f1 | grep -qw polis || fail "polis database missing"
docker compose restart
docker compose up -d --wait
[ "$(docker compose exec -T postgres psql -U ostrom -d ostrom -Atc 'SELECT x FROM e2e_marker')" = "42" ] || fail "data lost on restart"
get api.localhost /health >/dev/null || fail "server after restart"

echo "compose e2e: ok"
