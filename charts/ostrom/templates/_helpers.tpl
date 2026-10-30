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

{{/* Secret name and key of the database password used by the server. */}}
{{- define "ostrom.database.passwordRef" -}}
{{- if .Values.postgresql.enabled -}}
name: {{ include "ostrom.postgresql.secretName" . }}
key: password
{{- else if .Values.externalDatabase.existingSecret -}}
name: {{ .Values.externalDatabase.existingSecret }}
key: password
{{- else -}}
name: {{ include "ostrom.fullname" . }}-external-db
key: password
{{- end -}}
{{- end -}}

{{- define "ostrom.server.secretName" -}}
{{- if .Values.server.existingSecret -}}{{ .Values.server.existingSecret }}{{- else -}}{{ printf "%s-server" (include "ostrom.fullname" .) }}{{- end -}}
{{- end -}}

{{- define "ostrom.signingKey.secretName" -}}
{{- if .Values.server.signingKey.existingSecret -}}{{ .Values.server.signingKey.existingSecret }}{{- else -}}{{ printf "%s-signing-key" (include "ostrom.fullname" .) }}{{- end -}}
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
{{- define "ostrom.np.internet" -}}
- to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except: {{- toYaml .denied | nindent 10 }}
{{- end -}}
