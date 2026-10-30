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

{{- define "ostrom.database.url" -}}
{{- if .Values.postgresql.enabled -}}
{{- printf "postgresql://%s:5432/%s" (include "ostrom.postgresql.host" .) .Values.postgresql.database -}}
{{- else -}}
{{- required "externalDatabase.url is required when postgresql.enabled is false" .Values.externalDatabase.url -}}
{{- end -}}
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
