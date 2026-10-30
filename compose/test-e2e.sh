#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
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
for k in POSTGRES_PASSWORD OSTROM_OWNER_PASSWORD OSTROM_APP_PASSWORD POLIS_DB_PASSWORD; do
  grep -Eq "^$k=[A-Za-z0-9]{32}\$" .env || fail "no generated $k"
done
[ "$(stat -c %a .env 2>/dev/null || stat -f %Lp .env)" = "600" ] || fail ".env is not private"

get api.localhost /health | grep -q '"status":"ok"' || fail "server through Caddy"
get app.localhost / >/dev/null || fail "console through Caddy"
get app.localhost /api/v1/health | grep -q '"status":"ok"' || fail "API on the console's origin through Caddy"
# Ory Polis is off by default (SAML coming soon): not even created without the `sso` profile.
if docker compose ps -a --format '{{.Service}}' | grep -qx polis; then fail "Polis runs without the sso profile"; fi

before=$(sha256sum .env 2>/dev/null || shasum -a 256 .env)
./install.sh --no-start
[ "$(sha256sum .env 2>/dev/null || shasum -a 256 .env)" = "$before" ] || fail "second install changed .env"

# The roles: the server's cannot bypass row-level security nor create anything; the owner migrates.
# shellcheck source=/dev/null
. ./.env
app() { docker compose exec -T -e PGPASSWORD="$OSTROM_APP_PASSWORD" postgres psql -h 127.0.0.1 -U ostrom_app -d ostrom -v ON_ERROR_STOP=1 -Atc "$1"; }
owner() { docker compose exec -T -e PGPASSWORD="$OSTROM_OWNER_PASSWORD" postgres psql -h 127.0.0.1 -U ostrom -d ostrom -v ON_ERROR_STOP=1 -Atc "$1"; }
[ "$(app "SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user")" = f ] || fail "serving role too strong"
if app "CREATE TABLE e2e_forbidden (x int)" 2>/dev/null; then fail "serving role created a table"; fi
owner "CREATE TABLE IF NOT EXISTS e2e_marker(x int); INSERT INTO e2e_marker VALUES (42);" >/dev/null
docker compose exec -T postgres psql -U postgres -lqt | cut -d'|' -f1 | grep -qw polis || fail "polis database missing"
docker compose restart
docker compose up -d --wait
[ "$(app 'SELECT x FROM e2e_marker')" = "42" ] || fail "data lost on restart"
get api.localhost /health >/dev/null || fail "server after restart"

# The option: the `sso` profile starts Polis behind its own host.
COMPOSE_PROFILES=sso docker compose up -d --wait || fail "up with the sso profile"
get sso.localhost /api/health | grep -qi 'version\|healthy\|ok' || fail "Ory Polis through Caddy (sso profile)"

echo "compose e2e: ok"
