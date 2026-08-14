#!/usr/bin/env bash
#
# 05_create_polaris_credential_prod.sh
#
# Puts the Polaris credential Spark authenticates with into the `spark`
# namespace, as the `etl` principal rather than as root.
#
# WHY THIS SCRIPT EXISTS
# -----------------------
# The first working smoke test copied Trino's Secret across namespaces, which
# is the Polaris ROOT principal. It worked, and it quietly cancelled most of
# the access control this platform is built around.
#
# Polaris vends short-lived, per-table S3 credentials to whoever asks -- that
# part was confirmed working when a failed write named
# `data-platform-prod-polaris-storage-role/PolarisAwsCredentialsStorageIntegration`
# rather than Spark's own IRSA role. But vending decides WHAT to vend by
# looking at the privileges of the principal doing the asking. Ask as root, and
# the answer is "everything, on every table". The mechanism was enforcing
# correctly; the identity made the enforcement vacuous.
#
# 06_create_team_roles_prod.sh already creates an `etl` principal, holding
# CATALOG_MANAGE_CONTENT and nothing else. Pointing Spark at it turns
# "Spark can write what the catalog allows" from a description of the design
# into a statement about the running system.
#
# WHY THE CREDENTIAL IS RESHAPED HERE
# -------------------------------------
# Secrets Manager stores {realm, clientId, clientSecret} because that is what
# Polaris's own management API returns. Iceberg's REST client wants a single
# `credential` string of the form `clientId:clientSecret`. Joining them at the
# point of use, rather than storing the joined form, keeps one representation
# authoritative -- and means rotating the principal does not require editing
# two secrets that must agree.
#
# Usage:
#   ./05_create_polaris_credential_prod.sh          # create/refresh (idempotent)
#   ./05_create_polaris_credential_prod.sh verify   # which principal is in use
#   ./05_create_polaris_credential_prod.sh delete   # remove the k8s Secret
#
set -euo pipefail

REGION="ap-southeast-1"
NAMESPACE="spark"
PRINCIPAL="etl"
SM_PRINCIPAL="data-platform-prod-polaris-${PRINCIPAL}-credentials"
SM_ROOT="data-platform-prod-polaris-root-credentials"
K8S_SECRET="spark-polaris-credentials"
K8S_KEY="POLARIS_CREDENTIAL"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need kubectl; need aws; need python3

json_get() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"; }

case "$MODE" in
  delete)
    kubectl delete secret "$K8S_SECRET" -n "$NAMESPACE" --ignore-not-found
    echo "Removed. Any SparkApplication referencing it will now fail its"
    echo "required-environment check with a named variable, which is the"
    echo "intended behaviour -- see jobs/smoke_test.py."
    exit 0
    ;;

  verify)
    echo "=== kubernetes secret ==="
    kubectl get secret "$K8S_SECRET" -n "$NAMESPACE" 2>/dev/null || { echo "  not created"; exit 0; }
    echo ""
    echo "=== which principal is Spark actually using ==="
    # Only the client id is printed. It is the half that identifies, not the
    # half that authenticates, so `verify` stays safe to paste into a ticket.
    LIVE="$(kubectl get secret "$K8S_SECRET" -n "$NAMESPACE" \
      -o jsonpath="{.data.${K8S_KEY}}" 2>/dev/null | base64 -d 2>/dev/null || true)"
    LIVE_ID="${LIVE%%:*}"
    echo "  client id in cluster : ${LIVE_ID:-EMPTY}"

    ETL_ID="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SM_PRINCIPAL" \
      --query SecretString --output text 2>/dev/null | json_get clientId || true)"
    ROOT_ID="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SM_ROOT" \
      --query SecretString --output text 2>/dev/null | json_get clientId || true)"
    echo "  '${PRINCIPAL}' principal   : ${ETL_ID:-not found}"
    echo "  root principal       : ${ROOT_ID:-not found}"
    echo ""
    if [ -n "$LIVE_ID" ] && [ "$LIVE_ID" = "$ROOT_ID" ]; then
      echo "  RESULT: Spark is running as ROOT. Catalog privileges are not"
      echo "          being enforced for it. Re-run this script without args."
    elif [ -n "$LIVE_ID" ] && [ "$LIVE_ID" = "$ETL_ID" ]; then
      echo "  RESULT: Spark is running as '${PRINCIPAL}'."
    else
      echo "  RESULT: the credential in the cluster matches neither principal."
    fi
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
echo "[1/3] Reading the '${PRINCIPAL}' principal from Secrets Manager..."
JSON="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$SM_PRINCIPAL" --query SecretString --output text 2>/dev/null || true)"
if [ -z "$JSON" ] || [ "$JSON" = "None" ]; then
  cat >&2 <<EOF
ERROR: ${SM_PRINCIPAL} not found in Secrets Manager.

  The '${PRINCIPAL}' principal is created by

    ../01_iceberg_catalog_and_polaris_prod/06_create_team_roles_prod.sh

  Note that Polaris returns a principal's client secret exactly once, when the
  principal is created. If the principal exists but its secret does not, the
  only remedy is to delete the principal and let that script re-create it.
EOF
  exit 1
fi

CLIENT_ID="$(printf '%s' "$JSON" | json_get clientId)"
CLIENT_SECRET="$(printf '%s' "$JSON" | json_get clientSecret)"
[ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] || {
  echo "ERROR: ${SM_PRINCIPAL} does not contain clientId and clientSecret." >&2
  exit 1
}
echo "      ${CLIENT_ID}"

# ---------------------------------------------------------------------------
echo "[2/3] Refusing to install the root credential by accident..."
# The failure this guards against is not a typo -- it is someone reaching for
# the credential that is known to work while debugging something else, and
# leaving it there. Root works for every query, so nothing ever complains.
ROOT_JSON="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$SM_ROOT" --query SecretString --output text 2>/dev/null || true)"
if [ -n "$ROOT_JSON" ] && [ "$ROOT_JSON" != "None" ]; then
  ROOT_ID="$(printf '%s' "$ROOT_JSON" | json_get clientId)"
  if [ -n "$ROOT_ID" ] && [ "$CLIENT_ID" = "$ROOT_ID" ]; then
    echo "ERROR: ${SM_PRINCIPAL} holds the ROOT client id." >&2
    echo "       Installing it would give Spark catalog-wide privileges." >&2
    exit 1
  fi
  echo "      not root"
else
  echo "      root credential not readable from here -- check skipped"
fi

# ---------------------------------------------------------------------------
echo "[3/3] Writing ${NAMESPACE}/${K8S_SECRET}..."
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || {
  echo "ERROR: namespace '${NAMESPACE}' does not exist." >&2
  echo "       Run ./01_create_namespace_and_sa_prod.sh first." >&2
  exit 1
}

# `credential` in Iceberg's REST client is one string, id and secret joined by
# a colon. Neither half may contain a colon; Polaris generates both, so this
# holds -- but it is the reason this is a join rather than two env vars.
kubectl create secret generic "$K8S_SECRET" -n "$NAMESPACE" \
  --from-literal="${K8S_KEY}=${CLIENT_ID}:${CLIENT_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset CLIENT_SECRET
echo "      done (secret half never printed)"

cat <<EOF

Spark now authenticates to Polaris as '${PRINCIPAL}', which holds
CATALOG_MANAGE_CONTENT and nothing more.

This changes what Spark is ALLOWED to do, not what it asks for, so the way to
confirm it is a job that should now fail:

  ./05_create_polaris_credential_prod.sh verify

Running pods keep the old value -- a Secret is read at pod start. Re-submit
rather than expecting a running job to pick this up:

  kubectl delete sparkapplication platform-smoke-test -n ${NAMESPACE} --ignore-not-found
  sed 's|__IMAGE_TAG__|v1.0.2|' 06_smoke_test.yaml | kubectl apply -f -
EOF
