# Rotating secrets

The examples below assume a release called `ostrom` in namespace `ostrom`. With another release name `x`, the
objects are called `x-ostrom-…`.

Rule of thumb: **change the credential where it lives first, then update the Kubernetes Secret, then restart the
pods that read it**. The server reads every secret once, at start, from environment variables. The chart's pod
checksums cover `server.secretEnv` and `observability`, but not the generated Secrets or your `existingSecret`s. A
restart is therefore always explicit:

```sh
kubectl -n ostrom rollout restart deploy/ostrom-server
kubectl -n ostrom rollout status deploy/ostrom-server
```

With two replicas or more and the PodDisruptionBudget, the restart drops no request: each pod answers 503 on
`/ready` and leaves the Service before it stops (`server.shutdownDelaySeconds`).

On Docker Compose, the order is the same: the passwords live in `compose/.env`, while the signing key and the
secrets key are files of the `server-data` volume (`instance-key.pem`, `data/secrets.key`). `docker compose up -d`
then recreates the containers whose settings changed.

| Secret | Where | Rotation | Overlap |
|---|---|---|---|
| Instance signing key | `<release>-signing-key`, key `instance-key.pem` | supported | old receipts stay verifiable |
| Secrets key | `<release>-secrets-key`, key `secrets-key` | **not supported**: compromise only | none: stored org secrets must be entered again |
| PostgreSQL passwords | `<release>-postgresql` | `ALTER ROLE`, then the Secret | short: one restart |
| External database passwords | `<release>-external-db` or `externalDatabase.existingSecret` | at your provider, then the Secret | as your provider allows |
| Stripe webhook secret | the console (Admin, `stripe`) | supported | two values, comma-separated |
| Provider and OAuth keys, mail, license | the console (Admin) | new key, save, revoke the old one | while both are valid at the provider |
| Telemetry headers, Langfuse keys | `observability.*` (or their `existingSecret`) | same as provider keys | same |

## Instance signing key

The instance signs every receipt with its Ed25519 key. At each start, the server records the public key it signs
with, and it keeps every key it has used: `GET /api/v1/instance/keys` and `GET /api/v1/receipts/keys` list them all.
A receipt signed before a rotation therefore still verifies, through its `kid`.

```sh
openssl genpkey -algorithm ed25519 -out instance-key.pem
kubectl -n ostrom create secret generic ostrom-signing-key --from-file=instance-key.pem \
  --dry-run=client -o yaml | kubectl -n ostrom apply -f -
kubectl -n ostrom rollout restart deploy/ostrom-server
curl -s https://api.example.com/api/v1/instance/keys     # the new key is listed next to the old ones
```

`kubectl apply` keeps the Secret's Helm annotations, so the chart's `lookup` finds the new key and keeps it at the
next `helm upgrade`. With `server.signingKey.existingSecret`, replace the key in your own Secret the same way.

Keep the old key file, encrypted, with your backups (see [backup-restore.md](backup-restore.md)). A verifier that
holds only the instance's public keys does not need it. The old public key stays in the database, and is
restored with it.

## Secrets key

The secrets key seals the org secrets stored in PostgreSQL (MCP credentials, provider keys) with AES-256-GCM.
**The server holds one key and has no re-encryption command**: once the key changes, an envelope sealed with
the old key is no longer readable. Do not rotate it on a schedule: rotate it **only when it is compromised**,
and plan for every org to enter its secrets again.

1. List what will have to be entered again: `GET /api/v1/secrets` for each org (names only, never the values).
2. Put a new key in place, then restart:

   ```sh
   kubectl -n ostrom create secret generic ostrom-secrets-key --from-literal=secrets-key="$(openssl rand -base64 32)" \
     --dry-run=client -o yaml | kubectl -n ostrom apply -f -
   kubectl -n ostrom rollout restart deploy/ostrom-server
   ```

3. Each org enters its secrets again (console, or `PUT /api/v1/secrets/{id}`). Until it does, the integrations
   that use them fail as if the secret were missing.

Never set the key in `server.secretEnv`: the chart refuses `OSTROM_SECRETS_KEY` there, so that the key never ends up
in the values file.

## PostgreSQL passwords (built-in database)

The roles get their passwords **once**, when PostgreSQL creates its data directory. Changing the Secret does
not change the role's password, and vice versa. Do both, in this order: role, then Secret, then restart.

| Key of `<release>-postgresql` | Role | Read by |
|---|---|---|
| `password` | `ostrom_app` (serving role) | the server |
| `owner-password` | `ostrom` (owner) | `ostrom-server migrate` (init container or Job) |
| `postgres-password` | `postgres` (superuser) | the backup CronJob and the chart's hooks |
| `polis-password` | `polis` | Ory Polis, when enabled |

Serving role, for example:

```sh
NEW=$(openssl rand -hex 24)
kubectl -n ostrom exec -i ostrom-postgresql-0 -- psql -U postgres -v ON_ERROR_STOP=1 -v pw="$NEW" <<'SQL'
ALTER ROLE ostrom_app PASSWORD :'pw';
SQL
kubectl -n ostrom patch secret ostrom-postgresql --type merge -p "{\"stringData\":{\"password\":\"$NEW\"}}"
kubectl -n ostrom rollout restart deploy/ostrom-server
```

Between the `ALTER ROLE` and the end of the restart, the old pods keep their open connections. A new connection
made with the old password fails. Rotate at a quiet hour, or with a single command chain as above. Do the same for
`owner-password` (role `ostrom`, then restart the server too, whose init container migrates), `polis-password`
(role `polis`, then `rollout restart deploy/ostrom-polis`) and `postgres-password` (role `postgres`: nothing to
restart, the CronJob and the hooks read it when they run).

If you set `postgresql.password` in your values, the Secret's `password` comes from it at every upgrade: change
the value in the values file (or, better, move it to `postgresql.existingSecret`), not only in the Secret.

## External database

Change the passwords at your provider: the serving role and the owner. Then update `<release>-external-db`
(keys `password` and `migration-password`) or your `externalDatabase.existingSecret`, and restart the server.
Providers that keep two valid passwords per user (or two users) let you rotate with no failed connection.

## Stripe webhook secret

The server accepts two webhook secrets, comma-separated, during a rotation:

1. In Stripe, roll the endpoint's signing secret, keeping the old one valid for a while.
2. In the console (Admin, `stripe`), save `whsec_new,whsec_old` as the webhook secret. Every replica reads it within
   30 seconds, without a restart.
3. When the old one expires at Stripe, save `whsec_new` alone.

The secret key: create a new restricted key in Stripe, save it in the same section, then delete the old key.

## Provider keys, OAuth clients, mail, telemetry

Each of these has one value, so the overlap is the provider's: create the new credential there while the old one
is still valid, set it, check it works, then revoke the old one. Where you set it depends on the credential:
- **In the console (Admin):** the OAuth clients (Google, GitHub), the GitHub App's key and webhook secret, Resend's
  key, the gateway's provider keys and the license. Save the new value in its section; every replica reads it within
  30 seconds, without a restart.
- **In the chart:** telemetry (`OTEL_EXPORTER_OTLP_HEADERS`, `OSTROM_LANGFUSE_*`). Set it in the `existingSecret` of
  `observability.*` and restart the server. With the values instead, run `helm upgrade`: the pod checksum covers it,
  and the server restarts by itself.

The PostHog project key is public (the console sends it too): rotating it is a PostHog project setting, not a
secret operation.

## After a rotation

- `helm test ostrom -n ostrom` checks the API answers and the database is reachable with the serving role.
- Export the Secrets again right away ([backup-restore.md](backup-restore.md), "Keys and secrets"). A restore made
  with a Secrets file older than the rotation brings back the old secrets key, and the secrets entered after the
  rotation can no longer be read.
- CI plays the signing key and PostgreSQL steps of this page on kind at every run (`ci/secret-rotation-drill.sh`).
