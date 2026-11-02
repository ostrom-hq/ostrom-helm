#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# No secret in clear outside a Secret (AUDIT-SECU-HELM-2 M4). Renders the chart with a witness value in every input
# that holds a secret, on several value sets, then fails if a witness, or any value of a rendered Secret (the generated
# passwords and keys included), appears in another object: a ConfigMap, a pod spec, an annotation, a label. The `view`
# role of Kubernetes reads all of those, never a Secret.
# Usage: ci/secrets-in-render.sh   (needs helm and yq v4)
set -euo pipefail
cd "$(dirname "$0")/.."

chart=charts/ostrom
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
seen=""

# One witness per secret input: long, unique, and never a substring of anything else the chart writes.
w() { printf 'witness%s0d1f9c3e7b' "$1"; }
witnesses=(pg-password ext-password ext-migration polis-db polis-api otel-headers langfuse-public langfuse-secret secret-env)

common=(
  --set "server.secretEnv.OSTROM_STRIPE_SECRET_KEY=$(w secret-env)"
  --set observability.otel.enabled=true --set observability.otel.endpoint=https://otlp.example.com
  --set "observability.otel.headers=Authorization=Basic $(w otel-headers)"
  --set observability.langfuse.enabled=true
  --set "observability.langfuse.publicKey=$(w langfuse-public)" --set "observability.langfuse.secretKey=$(w langfuse-secret)"
  --set polis.enabled=true --set "polis.apiKey=$(w polis-api)"
)
sets=(
  "builtin|--set postgresql.password=$(w pg-password) --set postgresql.backup.enabled=true"
  "external|--set postgresql.enabled=false --set externalDatabase.url=postgresql://db.example.com:5432/ostrom --set externalDatabase.username=ostrom_app --set externalDatabase.password=$(w ext-password) --set externalDatabase.migrationUsername=ostrom --set externalDatabase.migrationPassword=$(w ext-migration) --set externalDatabase.polisUrl=postgres://polis:$(w polis-db)@db.example.com:5432/polis"
  "cloud|--set cloudSessions.enabled=true --set server.replicas=1 --set postgresql.password=$(w pg-password)"
)

for entry in "${sets[@]}"; do
  name=${entry%%|*}
  read -r -a extra <<< "${entry#*|}"
  helm template o "$chart" -n ostrom "${common[@]}" "${extra[@]}" > "$work/$name.yaml"
  yq 'select(.kind != "Secret")' "$work/$name.yaml" > "$work/$name.public.yaml"
  # Every value of every rendered Secret: stringData as written, data decoded.
  { yq -r 'select(.kind == "Secret") | .stringData // {} | .[]' "$work/$name.yaml"
    yq -r 'select(.kind == "Secret") | .data // {} | .[] | @base64d' "$work/$name.yaml"
  } > "$work/$name.secret-values"
  # Each witness must reach a Secret in at least one set: a renamed value would otherwise go untested.
  for id in "${witnesses[@]}"; do grep -qF "$(w "$id")" "$work/$name.secret-values" && seen="$seen $id"; done
  for id in "${witnesses[@]}"; do
    if grep -qF "$(w "$id")" "$work/$name.public.yaml"; then
      echo "::error::[$name] the secret input '$id' appears outside a Secret:"
      grep -nF "$(w "$id")" "$work/$name.public.yaml" | head -3
      failures=$((failures + 1))
    fi
  done
  while IFS= read -r value; do
    # Short values (a key name, "true") are not secrets; the generated ones are 32 characters or more.
    [ "${#value}" -ge 16 ] || continue
    if grep -qF -- "$value" "$work/$name.public.yaml"; then
      echo "::error::[$name] a value of a rendered Secret appears outside a Secret (${value:0:4}…)"
      failures=$((failures + 1))
    fi
  done < "$work/$name.secret-values"
  echo "[$name] $(yq 'select(.kind == "Secret") | .metadata.name' "$work/$name.yaml" | grep -cv '^---$') Secrets, $(grep -cv -e "^---$" -e "^$" "$work/$name.secret-values") values, checked against $(yq 'select(.kind != "Secret") | .kind' "$work/$name.yaml" | grep -cv '^---$') other objects"
done

for id in "${witnesses[@]}"; do
  case " $seen " in *" $id "*) ;; *) echo "::error::the secret input '$id' reached no Secret: the check would not test it"; failures=$((failures + 1)) ;; esac
done

[ "$failures" -eq 0 ] || { echo "secrets in clear: $failures"; exit 1; }
echo "secrets in render: none in clear"
