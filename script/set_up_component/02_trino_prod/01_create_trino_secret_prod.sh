#!/usr/bin/env bash
#
# 01_create_trino_secret_prod.sh
#
# Creates the Kubernetes Secret that Trino reads its Polaris OAuth2 credential
# from. The data_platform catalog in chart/trino/values.yaml refers to it as:
#
#     iceberg.rest-catalog.oauth2.credential=${ENV:POLARIS_OAUTH2_CREDENTIAL}
#
# and the chart injects the whole Secret into every pod via envFrom, so the
# key name in the Secret IS the env var name.
#
# Trino expects the credential in the single-string form "clientId:clientSecret".
# Polaris stores those as two separate JSON fields, so this script joins them.
#
# Nothing is hardcoded: the values come from the Secrets Manager entry written
# by 01_iceberg_catalog_and_polaris_prod/03_bootstrap_polaris_realm_prod.sh, so
# there is one authoritative copy of the credential and re-bootstrapping
# Polaris only means re-running this script.
#
# Usage:
#   ./01_create_trino_secret_prod.sh          # create / refresh
#   ./01_create_trino_secret_prod.sh verify   # report status, no changes
#
set -euo pipefail

REGION="ap-southeast-1"
NAMESPACE="data-platform"
K8S_SECRET="trino-polaris-credentials"
POLARIS_ROOT_SECRET="data-platform-prod-polaris-root-credentials"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws
need kubectl
need python3

json_get() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(d.get(sys.argv[1], "") if isinstance(d, dict) else "")
' "$1"
}

echo "== Trino Polaris credential secret ($MODE) ======================="

if [ "$MODE" = "verify" ]; then
  if kubectl get secret "$K8S_SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Secret '$K8S_SECRET' exists. Keys:"
    kubectl get secret "$K8S_SECRET" -n "$NAMESPACE" -o jsonpath='{range $k,$v := .data}{"  "}{$k}{"\n"}{end}'
    # Length only -- never the value itself.
    LEN="$(kubectl get secret "$K8S_SECRET" -n "$NAMESPACE" \
      -o jsonpath='{.data.POLARIS_OAUTH2_CREDENTIAL}' | base64 --decode | wc -c | tr -d ' ')"
    echo "  POLARIS_OAUTH2_CREDENTIAL length: $LEN bytes"
  else
    echo "  (not created yet)"
  fi
  exit 0
fi

echo "[1/2] Reading Polaris root credentials from Secrets Manager..."
ROOT_JSON="$(aws secretsmanager get-secret-value --secret-id "$POLARIS_ROOT_SECRET" --region "$REGION" \
  --query 'SecretString' --output text 2>/dev/null)" \
  || { echo "ERROR: '$POLARIS_ROOT_SECRET' not found. Polaris must be bootstrapped first." >&2; exit 1; }

CLIENT_ID="$(printf '%s' "$ROOT_JSON"     | json_get clientId)"
CLIENT_SECRET="$(printf '%s' "$ROOT_JSON" | json_get clientSecret)"
[ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] \
  || { echo "ERROR: secret has no clientId/clientSecret." >&2; exit 1; }
echo "      clientId=$CLIENT_ID (secret not shown)"

echo "[2/2] Creating/updating Kubernetes Secret '$K8S_SECRET'..."
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
  || { echo "ERROR: namespace '$NAMESPACE' missing. Run 01_iceberg_catalog_and_polaris_prod/01_create_namespace_and_sa_prod.sh first." >&2; exit 1; }

# --dry-run=client | apply, rather than `create`, so re-running updates in
# place instead of failing with AlreadyExists. The value is piped, never a
# command-line argument, so it stays out of shell history and `ps`.
kubectl create secret generic "$K8S_SECRET" \
  --namespace "$NAMESPACE" \
  --from-literal=POLARIS_OAUTH2_CREDENTIAL="${CLIENT_ID}:${CLIENT_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -
unset CLIENT_SECRET

cat <<EOF

Done.

NOTE: Trino pods read this at startup only. If the credential is ever rotated,
restart them so the new value is picked up:
  kubectl rollout restart deployment/trino-coordinator deployment/trino-worker -n $NAMESPACE

Next: ./03_install_trino_prod.sh
EOF
