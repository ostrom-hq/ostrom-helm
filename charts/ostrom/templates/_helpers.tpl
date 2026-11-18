{{- define "ostrom.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ostrom.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains (include "ostrom.name" .) .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "ostrom.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "ostrom.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels. Call with (dict "root" $ "component" "server"). */}}
{{- define "ostrom.labels" -}}
helm.sh/chart: {{ include "ostrom.chart" .root }}
{{ include "ostrom.selectorLabels" . }}
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/part-of: ostrom
{{- with .root.Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "ostrom.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ostrom.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* Image reference. Call with (dict "root" $ "image" .Values.server.image "name" "ostrom-server"). */}}
{{- define "ostrom.image" -}}
{{- $repo := .image.repository | default (printf "%s/%s" .root.Values.global.imageRegistry .name) -}}
{{- if .image.digest -}}
{{- printf "%s@%s" $repo .image.digest -}}
{{- else -}}
{{- $tag := .image.tag | default .root.Values.global.imageTag | default .root.Chart.AppVersion -}}
{{- printf "%s:%s" $repo (toString $tag) -}}
{{- end -}}
{{- end -}}

{{/*
The digests values.yaml pins, and the tag each one is: a tag changed without its digest would otherwise run the pinned
version without a word (a PostgreSQL 16 data directory started by 17). Moving a digest in values.yaml (Renovate)
means moving it here too (Renovate does, by the comment that ends each line): the unit tests fail otherwise.
*/}}
{{- define "ostrom.thirdPartyPins" -}}
"sha256:00bc86618629af00d2937fdc5a5d63db3ff8450acf52f0636ec813c7f4902929": "17.6" # renovate: docker.io/library/postgres
"sha256:9165f3db9d9f5d3262f23446e860f4929f462d1d9c954af13f3bb44910c3a699": "26.2.0" # renovate: docker.io/boxyhq/jackson
"sha256:c1fe1679c34d9784c1b0d1e5f62ac0a79fca01fb6377cdd33e90473c6f9f9a69": "8.11.1" # renovate: docker.io/curlimages/curl
"sha256:c96417dce3f7ee82a1cb6df65309ebb7efec0a449363c333c043e2fe0c636097": "1.26.1-202610291052-trixie" # renovate: ghcr.io/cloudnative-pg/pgbouncer
{{- end -}}

{{/*
A third-party image (PostgreSQL, Ory Polis, the helm test's curl): repository:tag@digest (the runtime pulls the
digest, the tag stays readable), or repository:tag with `digest: ""`. Refused: a malformed digest, no tag nor digest,
and the chart's digest with another tag. Call with (dict "repository" "tag" "digest" "where").
*/}}
{{- define "ostrom.thirdPartyImage" -}}
{{- $tag := toString (.tag | default "") -}}
{{- $where := .where | default .repository -}}
{{- if .digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" (toString .digest)) -}}
{{- fail (printf "%s: image digest of %s must be sha256:<64 hex>, got %v" $where .repository .digest) -}}
{{- end -}}
{{- $pinned := get (include "ostrom.thirdPartyPins" . | fromYaml) (toString .digest) -}}
{{- if and $pinned (ne (toString $pinned) $tag) -}}
{{- fail (printf "%s: tag %q with the chart's digest of %s, which would run %s: set the digest of %s too, or digest \"\" to follow the tag" $where $tag $pinned $pinned $tag) -}}
{{- end -}}
{{- if $tag }}{{ printf "%s:%s@%s" .repository $tag .digest }}{{ else }}{{ printf "%s@%s" .repository .digest }}{{ end -}}
{{- else -}}
{{- if not $tag }}{{ fail (printf "%s: a tag or a digest is required" $where) }}{{ end -}}
{{- printf "%s:%s" .repository $tag -}}
{{- end -}}
{{- end -}}

{{/* tests.image, one reference (repository[:tag][@digest]), through the same checks. */}}
{{- define "ostrom.testsImage" -}}
{{- $ref := toString .Values.tests.image -}}
{{- $digest := "" -}}
{{- if contains "@" $ref }}{{ $digest = last (splitList "@" $ref) }}{{ $ref = first (splitList "@" $ref) }}{{ end -}}
{{- $tag := "" -}}
{{- if regexMatch ":[^/:]+$" $ref }}{{ $tag = last (splitList ":" $ref) }}{{ $ref = trimSuffix (printf ":%s" $tag) $ref }}{{ end -}}
{{- include "ostrom.thirdPartyImage" (dict "repository" $ref "tag" $tag "digest" $digest "where" "tests.image") -}}
{{- end -}}

{{- define "ostrom.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

{{/* Reuse a generated value across upgrades: (dict "root" $ "secret" name "key" k "length" n). */}}
{{- define "ostrom.keepOrGenerate" -}}
{{- $existing := lookup "v1" "Secret" .root.Release.Namespace .secret -}}
{{- if and $existing (hasKey $existing.data .key) -}}
{{- index $existing.data .key | b64dec -}}
{{- else -}}
{{- randAlphaNum (int .length) -}}
{{- end -}}
{{- end -}}

{{- define "ostrom.postgresql.host" -}}
{{- printf "%s-postgresql" (include "ostrom.fullname" .) -}}
{{- end -}}

{{- define "ostrom.postgresql.secretName" -}}
{{- if .Values.postgresql.existingSecret -}}{{ .Values.postgresql.existingSecret }}{{- else -}}{{ printf "%s-postgresql" (include "ostrom.fullname" .) }}{{- end -}}
{{- end -}}

{{/* The URL the server and `migrate` use: the TLS proxy on the pod's loopback when externalDatabase.tls is on. */}}
{{- define "ostrom.database.url" -}}
{{- if .Values.postgresql.enabled -}}
{{- printf "postgresql://%s:5432/%s" (include "ostrom.postgresql.host" .) .Values.postgresql.database -}}
{{- else if include "ostrom.dbProxy.enabled" . -}}
{{- printf "postgresql://127.0.0.1:%d/%s" (include "ostrom.dbProxy.port" . | int) (include "ostrom.externalDatabase.parts" . | fromYaml).db -}}
{{- else -}}
{{- include "ostrom.refuseCredentialUrl" (dict "value" .Values.externalDatabase.url "where" "externalDatabase.url" "instead" "give the credentials in externalDatabase.username and password, or existingSecret") -}}
{{- required "externalDatabase.url is required when postgresql.enabled is false" .Values.externalDatabase.url -}}
{{- end -}}
{{- end -}}

{{/* "true" when the server reaches an external database through the TLS proxy sidecar. */}}
{{- define "ostrom.dbProxy.enabled" -}}
{{- if and (not .Values.postgresql.enabled) .Values.externalDatabase.tls .Values.externalDatabase.tls.enabled }}true{{ end -}}
{{- end -}}

{{- define "ostrom.dbProxy.port" -}}6432{{- end -}}

{{/* host, port and db of externalDatabase.url (postgresql://host[:port]/db), as YAML. */}}
{{- define "ostrom.externalDatabase.parts" -}}
{{- $url := required "externalDatabase.url is required when postgresql.enabled is false" .Values.externalDatabase.url -}}
{{- include "ostrom.refuseCredentialUrl" (dict "value" $url "where" "externalDatabase.url" "instead" "give the credentials in externalDatabase.username and password, or existingSecret") -}}
{{- if contains "[" $url -}}
{{- fail "externalDatabase.url: an IPv6 literal cannot go through the TLS proxy; use a host name (the one its certificate names)" -}}
{{- end -}}
{{- $re := "^postgres(?:ql)?://([^/:@?#\\[\\]]+)(?::([0-9]+))?/([^/?#]+)$" -}}
{{- if not (regexMatch $re $url) -}}
{{- fail "externalDatabase.url must be postgresql://host[:port]/database with externalDatabase.tls (no credentials, no query string)" -}}
{{- end }}
host: {{ regexReplaceAll $re $url "${1}" | quote }}
port: {{ regexReplaceAll $re $url "${2}" | default "5432" | quote }}
db: {{ regexReplaceAll $re $url "${3}" | quote }}
{{- end -}}

{{/*
The PgBouncer configuration of the TLS proxy (externalDatabase.tls). It listens on 127.0.0.1 only, checks the
client's password (SCRAM) against the file the config step writes, and logs in to the database with it, in TLS.
Session pooling: the server's prepared statements and the migration lock (a session advisory lock) need it.
PgBouncer refuses the session settings the JVM server sends in the startup `options` (statement, lock and
idle-in-transaction timeouts): it ignores them, and the operator sets them on the roles (docs/install-kubernetes.md).
*/}}
{{- define "ostrom.dbProxy.ini" -}}
{{- $t := .Values.externalDatabase.tls -}}
{{- $p := include "ostrom.externalDatabase.parts" . | fromYaml -}}
{{- $host := $t.host | default $p.host -}}
{{- if not (has $t.mode (list "verify-full" "verify-ca" "require")) -}}
{{- fail (printf "externalDatabase.tls.mode must be verify-full, verify-ca or require, got %v" $t.mode) -}}
{{- end -}}
{{- $verify := ne $t.mode "require" -}}
{{- if and $verify (not (or $t.ca.secretName $t.ca.configMapName)) -}}
{{- fail (printf "externalDatabase.tls.mode %s needs the CA: externalDatabase.tls.ca.secretName or configMapName" $t.mode) -}}
{{- end -}}
{{- $pool := add (int .Values.server.database.maxConnections) 2 -}}
[databases]
{{- if not (regexMatch "^[A-Za-z0-9_.-]+$" $p.db) }}
{{- fail "externalDatabase.url: the database name goes through the TLS proxy, letters, digits, _ . - only" }}
{{- end }}
{{ $p.db }} = host={{ $host }} port={{ $p.port }} dbname={{ $p.db }}

[pgbouncer]
listen_addr = 127.0.0.1
listen_port = {{ include "ostrom.dbProxy.port" . }}
unix_socket_dir =
auth_type = scram-sha-256
auth_file = /run/ostrom/db-proxy/userlist.txt
pool_mode = session
max_client_conn = {{ add $pool 4 }}
default_pool_size = {{ $pool }}
server_tls_sslmode = {{ $t.mode }}
{{- if $verify }}
server_tls_ca_file = /etc/ostrom/db-ca/{{ $t.ca.key }}
{{- end }}
server_tls_protocols = secure
ignore_startup_parameters = extra_float_digits,options
admin_users =
stats_users =
logfile =
pidfile =
{{- end -}}

{{- define "ostrom.database.user" -}}
{{- if .Values.postgresql.enabled -}}{{ .Values.postgresql.username }}{{- else -}}{{ required "externalDatabase.username is required" .Values.externalDatabase.username }}{{- end -}}
{{- end -}}

{{/* Owner role of the database: migrations only, never the serving process. */}}
{{- define "ostrom.database.ownerUser" -}}
{{- if .Values.postgresql.enabled -}}{{ .Values.postgresql.ownerUsername }}{{- else -}}{{ required "externalDatabase.migrationUsername is required" .Values.externalDatabase.migrationUsername }}{{- end -}}
{{- end -}}

{{/* Secret holding the database passwords: keys `password` (serving role) and `migration-password` or `owner-password`. */}}
{{- define "ostrom.database.secretName" -}}
{{- if .Values.postgresql.enabled -}}{{ include "ostrom.postgresql.secretName" . }}
{{- else if .Values.externalDatabase.existingSecret -}}{{ .Values.externalDatabase.existingSecret }}
{{- else -}}{{ include "ostrom.fullname" . }}-external-db
{{- end -}}
{{- end -}}

{{/* Secret name and key of the database password used by the server (the serving role). */}}
{{- define "ostrom.database.passwordRef" -}}
name: {{ include "ostrom.database.secretName" . }}
key: password
{{- end -}}

{{/* Secret name and key of the owner's password, for `ostrom-server migrate`. */}}
{{- define "ostrom.database.ownerPasswordRef" -}}
name: {{ include "ostrom.database.secretName" . }}
key: {{ if .Values.postgresql.enabled }}owner-password{{ else }}migration-password{{ end }}
{{- end -}}

{{- define "ostrom.server.secretName" -}}
{{- if .Values.server.existingSecret -}}{{ .Values.server.existingSecret }}{{- else -}}{{ printf "%s-server" (include "ostrom.fullname" .) }}{{- end -}}
{{- end -}}

{{- define "ostrom.signingKey.secretName" -}}
{{- if .Values.server.signingKey.existingSecret -}}{{ .Values.server.signingKey.existingSecret }}{{- else -}}{{ printf "%s-signing-key" (include "ostrom.fullname" .) }}{{- end -}}
{{- end -}}

{{/* The Secret the user gives for the secrets key, or "": safe when `server.secretsKey` is absent (`--reuse-values`). */}}
{{- define "ostrom.secretsKey.existingSecret" -}}
{{- dig "secretsKey" "existingSecret" "" .Values.server -}}
{{- end -}}

{{- define "ostrom.secretsKey.secretName" -}}
{{- $given := include "ostrom.secretsKey.existingSecret" . -}}
{{- if $given -}}{{ $given }}{{- else -}}{{ printf "%s-secrets-key" (include "ostrom.fullname" .) }}{{- end -}}
{{- end -}}

{{- define "ostrom.polis.secretName" -}}
{{- if .Values.polis.existingSecret -}}{{ .Values.polis.existingSecret }}{{- else -}}{{ printf "%s-polis" (include "ostrom.fullname" .) }}{{- end -}}
{{- end -}}

{{/* Secret of Ory Polis's external database URL (key `url`): the user's, or the one the chart writes from polisUrl. */}}
{{- define "ostrom.polis.dbSecretName" -}}
{{- .Values.externalDatabase.polisExistingSecret | default (printf "%s-polis-db" (include "ostrom.fullname" .)) -}}
{{- end -}}

{{/*
Refuses a secret-looking key in a place that is not a Secret (AUDIT-SECU-HELM-2 M4): a ConfigMap, a plain env value,
or the console's public config. Call with (dict "values" (dict name value …) "where" "server.config" "what" "…"
"instead" "…"). A name is secret-looking with SECRET, PASSWORD, PASSWD, TOKEN, CREDENTIAL, API_KEY, PRIVATE_KEY,
LICENSE_KEY or a final _KEY; except a path (_FILE), an address (_URL), the runners' pull Secret name and PostHog's
project key (public by design). A false positive (a length, a TTL) goes in the Secret too: it is only an environment
variable there. Every value is also refused when it carries a credential (ostrom.refuseCredentialUrl), whatever its
name: an address is exempt by name, never by content.
*/}}
{{- define "ostrom.refuseSecrets" -}}
{{- range $k, $v := .values -}}
{{- $u := upper (toString $k) -}}
{{- $named := regexMatch "(SECRET|PASSWORD|PASSWD|TOKEN|CREDENTIAL|API_KEY|PRIVATE_KEY|LICENSE_KEY|_KEY$)" $u -}}
{{- $exempt := or (hasSuffix "_FILE" $u) (hasSuffix "_URL" $u) (has $u (list "OSTROM_POSTHOG_API_KEY" "OSTROM_RUNNERS_KUBERNETES_IMAGE_PULL_SECRET")) -}}
{{- if and $named (not $exempt) -}}
{{- fail (printf "%s.%s looks like a secret, and %s is not a Secret: %s" $.where $k $.what $.instead) -}}
{{- end -}}
{{- include "ostrom.refuseCredentialUrl" (dict "value" $v "where" (printf "%s.%s" $.where $k) "instead" $.instead) -}}
{{- end -}}
{{- end -}}

{{/* A value that carries a credential whatever its name: a URL with a password, or a token in its query string. */}}
{{- define "ostrom.refuseCredentialUrl" -}}
{{- $v := toString (.value | default "") -}}
{{- if or (regexMatch "://[^/@\\s:]*:[^/@\\s]+@" $v) (regexMatch "(?i)[?&](access_?token|token|api_?key|key|secret|password|sig|signature)=" $v) -}}
{{- fail (printf "%s holds a credential (a password in the URL, or a token in its query string): %s" .where .instead) -}}
{{- end -}}
{{- end -}}

{{/* Ory Polis's external database URL (it holds a password): only ever in its Secret, or hashed. */}}
{{- define "ostrom.polis.dbUrl" -}}
{{- required "externalDatabase.polisUrl or polisExistingSecret is required when polis.enabled and postgresql.enabled is false" .Values.externalDatabase.polisUrl -}}
{{- end -}}

{{- define "ostrom.polis.externalUrl" -}}
{{- .Values.polis.externalUrl | default (printf "https://%s" .Values.ingress.hosts.sso) -}}
{{- end -}}

{{- define "ostrom.tls.secretName" -}}
{{- .Values.ingress.tls.secretName | default (printf "%s-tls" (include "ostrom.fullname" .)) -}}
{{- end -}}

{{/* Pod-level security context. */}}
{{- define "ostrom.podSecurityContext" -}}
securityContext:
  {{- toYaml .Values.podSecurityContext | nindent 2 }}
{{- end -}}

{{- define "ostrom.containerSecurityContext" -}}
securityContext:
  {{- toYaml .Values.containerSecurityContext | nindent 2 }}
{{- end -}}

{{- define "ostrom.np.peer" -}}
podSelector:
  matchLabels:
    app.kubernetes.io/instance: {{ .root.Release.Name }}
    app.kubernetes.io/component: {{ .component }}
{{- end -}}
{{/* The session pods the server creates (labels set by ostrom-server's Kubernetes driver). */}}
{{- define "ostrom.np.sessions" -}}
podSelector:
  matchLabels:
    app.kubernetes.io/managed-by: ostrom
  matchExpressions:
    - { key: ostrom.run/session, operator: Exists }
{{- end -}}
{{/* "true" or "" for a boolean value that defaults to `default` when unset (null or absent, e.g. --reuse-values). */}}
{{- define "ostrom.flag" -}}
{{- if ternary .default .value (kindIs "invalid" .value) }}true{{ end -}}
{{- end -}}

{{/*
Extra egress rules (networkPolicy.<part>.extraEgress), each one destination and its ports. A guard against the
mistakes that open everything, not a policy engine: no rule without `to` or `ports`, no ipBlock wider than /16 (IPv4)
or /48 (IPv6), and no peer that selects every namespace or every pod of the namespace.
Call with (dict "rules" list "where" "networkPolicy.server.extraEgress").
*/}}
{{- define "ostrom.np.extraEgress" -}}
{{- range $i, $rule := .rules }}
{{- if or (not (kindIs "map" $rule)) (not $rule.to) (not $rule.ports) }}
{{- fail (printf "%s[%d] needs `to` and `ports`: a rule without them allows every destination" $.where $i) }}
{{- end }}
{{- range $peer := $rule.to }}
{{- if not (kindIs "map" $peer) }}{{ fail (printf "%s[%d]: every `to` entry is a NetworkPolicy peer" $.where $i) }}{{ end }}
{{- with $peer.ipBlock }}
{{- $parts := splitList "/" (toString .cidr) }}
{{- $v6 := contains ":" (toString .cidr) }}
{{- if or (ne (len $parts) 2) (lt (atoi (last $parts)) (ternary 48 16 $v6)) }}
{{- fail (printf "%s[%d] opens %s: name the destination itself (a /32, a subnet of /16 or narrower); for the internet use networkPolicy.server.allowInternet" $.where $i .cidr) }}
{{- end }}
{{- end }}
{{- if and (hasKey $peer "namespaceSelector") (empty $peer.namespaceSelector) (empty $peer.podSelector) }}
{{- fail (printf "%s[%d] selects every pod of every namespace: name the namespace and the pods" $.where $i) }}
{{- end }}
{{- if and (not $peer.ipBlock) (not (hasKey $peer "namespaceSelector")) (empty $peer.podSelector) }}
{{- fail (printf "%s[%d] selects every pod of the namespace: name the pods" $.where $i) }}
{{- end }}
{{- end }}
- {{- toYaml $rule | nindent 2 }}
{{- end }}
{{- end -}}

{{/* Whether `helm test` runs the NetworkPolicy probe (templates/tests/test-network.yaml); NOTES says so only then. */}}
{{- define "ostrom.networkProbe.enabled" -}}
{{- if and .Values.tests.enabled .Values.networkPolicy.enabled (include "ostrom.flag" (dict "value" .Values.tests.networkPolicyEnforced "default" true)) (or .Values.postgresql.enabled .Values.server.enabled) }}true{{ end -}}
{{- end -}}

{{- define "ostrom.np.internet" -}}
- to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except: {{- toYaml .denied | nindent 10 }}
{{- end -}}

{{/*
Roles that must hold on every install and every upgrade (SECURITY-AUDIT S2-43), idempotent, run as the superuser with
psql variables owner, app and db. The owner gets CREATEROLE (the migrations create `ostrom_tenant`; since PostgreSQL 16
it only administers the roles it creates, never a superuser nor a BYPASSRLS role); `ostrom_tenant` is created ahead and
granted to the serving role, which gets neither CREATEROLE nor membership of the owner (the server refuses to start).
`ostrom_router` owns the cross-organization functions (SECURITY DEFINER, ostrom-server docs/tenancy.md, S2-51): no
table, administered by the owner who hands it the functions, never granted to the serving role.
The migrations' history tables (Flyway's `flyway_<module>`) are written by the owner alone (AUDIT-RLS R8): the default
privileges give the serving role every table. `ostrom-server migrate` revokes the write on its histories at every pass
(ostrom-server#144), install and external database included; this block does it again before every upgrade, for any
history of the schema (one an older server migrated, or one a module no longer migrates), from every role but the owner.
Also the end of 10-roles.sh, and the pre-upgrade Job for a database created by an older chart.
*/}}
{{- define "ostrom.postgresql.tenantSql" -}}
SELECT 'CREATE ROLE ostrom_tenant NOLOGIN NOSUPERUSER NOBYPASSRLS'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ostrom_tenant') \gexec
ALTER ROLE :"owner" CREATEROLE;
GRANT ostrom_tenant TO :"owner" WITH ADMIN OPTION;
GRANT ostrom_tenant TO :"app";
SELECT 'CREATE ROLE ostrom_router NOLOGIN NOSUPERUSER NOBYPASSRLS'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ostrom_router') \gexec
GRANT ostrom_router TO :"owner" WITH ADMIN OPTION;
\connect :"db"
GRANT USAGE ON SCHEMA public TO ostrom_tenant;
-- AUDIT-RLS R8: the migrations' history is written by its owner alone. Any other role (the serving role, ostrom_tenant
-- that it inherits, PUBLIC) holding more than SELECT, on the table or a column, loses it all and keeps SELECT.
-- A named dollar quote: Kubernetes reads a doubled dollar sign in a container's args as one (the pre-upgrade Job).
DO $lock$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT quote_ident(c.relname) AS tbl,
      CASE WHEN g.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(g.grantee)) END AS name,
      bool_or(g.privilege_type = 'SELECT' AND NOT g.on_column) AS reads
    FROM pg_class c
    CROSS JOIN LATERAL (
      SELECT a.grantee, a.privilege_type, false AS on_column FROM aclexplode(c.relacl) a
      UNION ALL
      SELECT a.grantee, a.privilege_type, true FROM pg_attribute t, aclexplode(t.attacl) a WHERE t.attrelid = c.oid
    ) g
    WHERE c.relkind = 'r' AND c.relnamespace = 'public'::regnamespace AND c.relname LIKE 'flyway\_%'
      AND g.grantee <> c.relowner
    GROUP BY c.relname, g.grantee
    HAVING bool_or(g.privilege_type <> 'SELECT' OR g.on_column)
  LOOP
    EXECUTE format('REVOKE ALL ON public.%s FROM %s CASCADE', r.tbl, r.name);
    IF r.reads THEN
      EXECUTE format('GRANT SELECT ON public.%s TO %s', r.tbl, r.name);
    END IF;
  END LOOP;
END
$lock$;
{{- end -}}

{{/*
Affinity of a stateless component: the user's, or by default a preference for one pod per node, so that one node going
down does not take every replica with it. Usage: include "ostrom.affinity" (dict "root" $ "component" "web" "affinity" $w.affinity)
*/}}
{{- define "ostrom.affinity" -}}
{{- if .affinity -}}
{{ toYaml .affinity }}
{{- else -}}
podAntiAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels: {{- include "ostrom.selectorLabels" (dict "root" .root "component" .component) | nindent 12 }}
{{- end -}}
{{- end -}}
