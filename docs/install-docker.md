# Install with Docker Compose

One machine with Docker Engine 24+ and Compose v2. 2 vCPU and 4 GB of RAM are enough for a team of 50.

```sh
git clone https://github.com/ostrom-hq/ostrom-helm && cd ostrom-helm/compose
./install.sh
```

`install.sh` writes `.env` once (mode 600) with fresh secrets — the passwords of the four database roles
(`postgres`, the owner `ostrom` who migrates, the serving role `ostrom_app`, `polis`) and the three Ory Polis keys —
then runs `docker compose up -d --wait`. Run it again any time: it keeps the values already in `.env` and only adds
the missing ones. A one-shot `migrate` service applies the schema with the owner's credentials before the server
starts; the server itself connects as `ostrom_app`, which owns nothing and cannot bypass row-level security.

By default everything answers on plain HTTP under `*.localhost`: console `http://app.localhost` (which also serves
the API under `/api/v1`, one origin for the browser), API `http://api.localhost`.

Then make the first owner: the instance is closed to sign-up until they open its one-time setup link.

```sh
docker compose exec server ostrom-server bootstrap
```

It works once, for an hour, and only while the instance has no account; the person signs in with GitHub (or Google,
or an e-mail link), then invites the others from the console. To let anyone who signs in get an account instead, an
administrator sets the console's sign-up to open (Admin, sign-up).

## SAML single sign-on (coming soon)

The server has no SAML code yet, so Ory Polis, the SAML bridge, does not start by default. It is ready for when it
lands: the `sso` profile starts it behind `http://sso.localhost` (its database, role and keys are already created).

```sh
echo COMPOSE_PROFILES=sso >> .env && docker compose up -d --wait
# or once: docker compose --profile sso up -d --wait
```

## On a real domain, with HTTPS

Point the DNS records at the machine (`api.`, `app.`, and `sso.` with the `sso` profile), then before the first
`./install.sh`:

```sh
export OSTROM_SCHEME=https OSTROM_API_HOST=api.example.com OSTROM_APP_HOST=app.example.com OSTROM_SSO_HOST=sso.example.com
./install.sh
```

(or edit those four lines in `.env` and `docker compose up -d`). Caddy obtains and renews the certificates; ports
80 and 443 must be reachable.

## Settings

Anything the server reads (`OSTROM_*`) can go in `compose/server.env` (optional, `KEY=value` lines), for example:

```sh
# OpenTelemetry (OTLP/HTTP)
OTEL_EXPORTER_OTLP_ENDPOINT=https://otlp.example.com
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic ...
```

The full list of server keys is in [values.md](values.md#server-environment).

## Version

No release tag exists yet: `docker-compose.yml` pins the server and the console by digest, to a signed multi-arch build
of `main`. To run another build, set `OSTROM_SERVER_IMAGE` and `OSTROM_WEB_IMAGE` in `.env` (by digest, e.g.
`docker.io/ostromhq/ostrom-server@sha256:…`), then `docker compose pull && docker compose up -d`. To build the server
yourself instead, in a clone of `ostrom-server`: `./gradlew :image:publishImageToLocalRegistry -PimageTags=local
-PimagePlatforms=amd64` (or `arm64`; jib puts `ostrom-server:local` in the local Docker), and
`OSTROM_SERVER_IMAGE=ostrom-server:local`. See [upgrade.md](upgrade.md).

Cloud sessions (agents running on the server) need Kubernetes in the Compose install: they are off there. The local
demo below runs them on the machine's own Docker.

## Local demo: everything on one machine, nothing outside

`compose/demo/` starts Ostrom whole on a laptop, with no real outside service, to try every screen before a real
install:

```sh
cd compose
demo/demo.sh up        # the install's stack, plus the demo's services
demo/demo.sh journey   # the customer's journey against it; report in demo-report.md
demo/demo.sh down      # removes everything it created, cloud sessions included
```

- **Mail**: the server writes its sign-in and invitation mails to a directory (`OSTROM_MAIL_DIR`). A relay hands them
  to [Mailpit](https://mailpit.axllent.org), whose inbox is at `http://mail.localhost`.
- **GitHub**: « Continue with GitHub » goes to a fake GitHub at `http://github.localtest.me`. You pick the login to sign
  in as; no real account is involved. `github.localtest.me` is a public DNS name that answers `127.0.0.1`: offline, or
  behind a resolver that refuses such answers, add `127.0.0.1 github.localtest.me` to `/etc/hosts`. The demo needs
  Caddy on port 80 (`OSTROM_HTTP_PORT`, the default).
- **Cloud sessions**: they run on this machine's Docker (`OSTROM_RUNNERS_DRIVER=docker`). The server reaches the engine
  through a socket proxy, on a network only the server joins. Each session's three containers, the agent host, the
  check host (it runs the hooks' checks, out of the agent's reach) and the runner, join the `ostrom-sessions` network, which is internal. There they reach the server and nothing else: not
  the database, not the engine, not this machine's published ports, not the internet. The session image is `OSTROM_RUNNER_IMAGE` (default
  `docker.io/ostromhq/ostrom-runner:latest`).
- **TeamCode import**: a fake TeamCode team sits in MySQL, in TeamCode's own tables and data shapes
  (`demo/teamcode`). It has three members (`alice`, `rev`, `dev-2`), four remote MCP servers, two tool allowlists and
  three Claude accounts, and its secrets are sealed with the fake key `demo/teamcode/key.txt`. Import it with the CLI, which needs the `mysql` client:
  `MYSQL_PWD=demo-teamcode-ro ostrom import teamcode --db mysql://teamcode_ro@127.0.0.1:3307/teamcode --key-file demo/teamcode/key.txt`.
  TeamCode members are matched to Ostrom members by their GitHub login: sign in with the fake GitHub as `alice` and
  as `rev`. The assignments of a member without a match, here `dev-2`, are left out of the import, and so is the
  account TeamCode never finished. Once TeamCode is stopped, the owner runs the final pass, the cutover, with the same
  command plus `--cutover` (`--confirm cutover` without a terminal). It revives the shared accounts Ostrom holds as waiting for a reconnection, once TeamCode's tokens
  renew; in the demo the fake GitHub answers in place of the providers' token endpoints, and the journey first shares
  « Claude Max 1 » with a refresh token TeamCode has since rotated, so the cutover has an account to revive.
- **Billing, optional**: set `OSTROM_DEMO_STRIPE_KEY_FILE` to a file holding a Stripe **test** key (mode 600, outside
  git) before `demo/demo.sh up`. The Stripe CLI forwards the test events to the server. Checkout opens Stripe's hosted
  test page, where you pay with `4242 4242 4242 4242`.

The socket proxy lets the server create containers on the machine: run the demo on your own computer only, never on
a shared or exposed one.
