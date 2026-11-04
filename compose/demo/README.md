# The local demo: Ostrom whole on one computer

```sh
./demo up         # from the repository's root (compose/demo/demo.sh is the same script)
./demo journey    # optional: the customer's journey against it, report in compose/demo-report.md
./demo down       # removes its containers, volumes and the cloud sessions' ones
```

`./demo logs [lines]` prints the services' logs (Stripe's excepted: it holds the webhook secret).

## What you need

| | |
|---|---|
| Docker | Docker Desktop on a Mac (Apple silicon or Intel), Docker Engine 24+ on Linux; Compose 2.24 or later |
| Memory | 4 GB or more for Docker (Docker Desktop: Settings > Resources > Memory). `up` stops below 3 GiB seen by Docker (`OSTROM_DEMO_MIN_MEMORY_MIB` changes the floor) |
| Ports | 80 (the demo's addresses have no port), 443 and 3307 (the fake TeamCode base) free on this machine |
| ghcr.io | While Ostrom's images are private packages: Docker logged in to `ghcr.io` as a member of `ostrom-hq`, see below |
| Node 22+ | Only for `./demo journey` (`brew install node`) |
| Disk | A few GB free for the images |

The clone must sit where Docker Desktop shares files with its containers (`/Users` by default): the stack mounts
`compose/demo` and `compose/postgres-init`.

### Reading the images (ghcr.io)

The server, console and cloud session images are private packages of the `ostrom-hq` organization: a member reads
them once Docker is logged in to `ghcr.io` with a token that has `read:packages`. Once, with the GitHub CLI:

```sh
gh auth refresh -h github.com -s read:packages
gh auth token | docker login ghcr.io -u "$(gh api user -q .login)" --password-stdin
```

When the GitHub CLI already has `read:packages`, `./demo up` does the login itself the first time ghcr.io refuses it.
Without the GitHub CLI: a classic token with `read:packages` (github.com/settings/tokens), given to
`docker login ghcr.io -u <your login> --password-stdin`.

## What `./demo up` does

1. Checks Docker: running, Compose 2.24+, its memory.
2. Writes `compose/.env` with fresh secrets the first time (`install.sh --no-start`), keeps it after.
3. Takes the images: by default **main's last published ones**, the server's and the console's `edge` (the head of
   main once its Image run is done) and the cloud session image's `latest`, each pulled and resolved to its digest.
   `OSTROM_DEMO_IMAGES=pinned ./demo up` takes the digests pinned in `docker-compose.yml` instead, and
   `OSTROM_SERVER_IMAGE`, `OSTROM_WEB_IMAGE` or `OSTROM_RUNNER_IMAGE` set to an image take that one. The choice is
   written in `compose/demo/.images.env` for `journey`, `logs` and `down`.
4. Checks that this Docker runs a `linux/amd64` container (the cloud session image, see below), that ports 80, 443
   and 3307 are free, and that the demo's names answer this machine.
5. Starts the stack, waits until the server is ready behind Caddy and the console answers, then prints the image of
   each part, the memory each container uses, the addresses and how to sign in.

## Signing in

| | |
|---|---|
| Console | <http://app.localhost>. « Sign up » with any e-mail address: the sign-in link arrives in the inbox. Or « Continue with GitHub »: the fake GitHub signs you in as the login you type |
| Inbox | <http://mail.localhost> (Mailpit): sign-in links and invitations |
| API | <http://api.localhost> (CLI, tokens) |
| Fake GitHub | <http://github.localtest.me> |
| Fake TeamCode | `mysql://teamcode_ro@127.0.0.1:3307/teamcode`, password `demo-teamcode-ro`, key `compose/demo/teamcode/key.txt`; its members `alice` and `rev` match the fake GitHub logins of the same names |

No real account is involved anywhere. Billing stays off unless `OSTROM_DEMO_STRIPE_KEY_FILE` names a file holding a
Stripe **test** key (mode 600, outside git) before `./demo up`; Checkout then takes the test card
`4242 4242 4242 4242`. The rest of the demo's services are described in [docs/install-docker.md](../../docs/install-docker.md#local-demo-everything-on-one-machine-nothing-outside).

## On a Mac

- **Apple silicon**: the server, the console and every third-party image (PostgreSQL, Caddy, Mailpit, Node, MySQL,
  the Docker socket proxy, Stripe CLI) are multi-arch and run natively. The cloud session image
  (`ostrom-runner`) is built for `linux/amd64` only: Docker Desktop runs it under Rosetta (Settings > General, « Use
  Rosetta for x86_64/amd64 emulation on Apple Silicon », on by default). `./demo up` pulls it for `linux/amd64` and
  stops with this setting's name if such a container does not start.
- **Names**: macOS answers `*.localhost` with this machine itself; `github.localtest.me` is a public DNS name that
  answers `127.0.0.1`. Offline, or behind a resolver that refuses such answers, `./demo up` prints the `/etc/hosts`
  line to add.
- **The Docker socket**: cloud sessions are containers the server creates through a socket proxy, which mounts
  `/var/run/docker.sock` (Docker Desktop provides it inside its VM). Docker Desktop's Enhanced Container Isolation, when
  an administrator turns it on, refuses that mount.

The socket proxy lets the server create containers on the machine: run the demo on your own computer only, never on
a shared or exposed one.
