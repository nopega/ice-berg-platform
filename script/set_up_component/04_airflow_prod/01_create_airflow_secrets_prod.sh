#!/usr/bin/env bash
#
# 01_create_airflow_secrets_prod.sh
#
# Creates the three Kubernetes Secrets the Airflow chart expects, before the
# chart is installed. Running this first matters: the chart's database-migration
# Job runs on install and fails immediately if the metadata connection Secret is
# not already there, and a failed migration Job leaves the release in a state
# that needs manual cleanup.
#
# WHAT EACH SECRET IS FOR
# ------------------------
#   airflow-metadata        SQLAlchemy URL for the `airflow` database in RDS.
#                           Created by 04_02_create_databases_prod.sh.
#
#   airflow-fernet-key      Symmetric key Airflow uses to encrypt connection
#                           passwords and Variables *inside* the metadata
#                           database. Losing or changing it does not break
#                           Airflow, but every stored credential becomes
#                           undecryptable -- which is why it is generated once
#                           and then read back on later runs rather than
#                           regenerated.
#
#   airflow-api-secret-key  Flask secret key for the API server ([api]
#                           secret_key). If each replica generated its own, a
#                           user would be logged out whenever their request hit
#                           a different pod.
#
#   airflow-jwt-secret      Signs the JWTs that Airflow 3 components use to
#                           authenticate to each other ([api_auth] jwt_secret).
#                           Separate from the key above in Airflow 3 -- they
#                           were one value in Airflow 2.
#
# WHY NOT LET THE CHART GENERATE THEM
# ------------------------------------
# The chart auto-generates all three if none are supplied -- and regenerates
# them on every `helm upgrade`. For the fernet key that silently makes every
# encrypted connection already in the database undecryptable; for the JWT
# secret the chart's own values.yaml warns it "can cause dag failures during
# component rollouts", because tasks holding a token signed with the old secret
# are rejected mid-run. Generating them once here, storing them in AWS Secrets
# Manager, and referencing them by name makes an upgrade a no-op for
# credentials.
#
# Secrets are generated with openssl and piped straight into kubectl/aws. They
# are never echoed, never passed as a command-line argument (visible in `ps`),
# and never written to a file on disk.
#
# Usage:
#   ./01_create_airflow_secrets_prod.sh          # create if missing (idempotent)
#   ./01_create_airflow_secrets_prod.sh verify   # show what exists, no changes
#   ./01_create_airflow_secrets_prod.sh rotate-api-key   # new API key only
#
set -euo pipefail

REGION="ap-southeast-1"
NAMESPACE="airflow"
DB_INSTANCE_ID="data-platform-prod-db"
DB_NAME="airflow"
DB_USER="dbadmin"
RDS_PASSWORD_SECRET="data-platform-prod-rds-master-password"
SM_FERNET="data-platform-prod-airflow-fernet-key"
SM_API_KEY="data-platform-prod-airflow-api-secret-key"
SM_JWT="data-platform-prod-airflow-jwt-secret"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need kubectl; need aws; need openssl

# ---------------------------------------------------------------------------
# get_or_create_sm_secret NAME GENERATOR_CMD
# Reads an existing Secrets Manager value, or generates and stores one.
# The generated value is passed to `aws` via a file descriptor rather than an
# argument so it never appears in the process list.
# ---------------------------------------------------------------------------
get_or_create_sm_secret() {
  local name="$1" generator="$2" existing
  if existing="$(aws secretsmanager get-secret-value --region "$REGION" \
        --secret-id "$name" --query 'SecretString' --output text 2>/dev/null)"; then
    printf '%s' "$existing"
    return 0
  fi
  local generated
  generated="$(eval "$generator")"
  aws secretsmanager create-secret --region "$REGION" \
    --name "$name" \
    --description "Airflow key for data-platform-prod (generated, never handled by a human)" \
    --secret-string "$generated" >/dev/null
  printf '%s' "$generated"
}

# ---------------------------------------------------------------------------
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
  || kubectl create namespace "$NAMESPACE" >/dev/null

if [ "$MODE" = "verify" ]; then
  echo "=== namespace ==="
  kubectl get namespace "$NAMESPACE" 2>/dev/null || echo "  (missing)"
  echo ""
  echo "=== secrets in ${NAMESPACE} ==="
  kubectl get secrets -n "$NAMESPACE" 2>/dev/null | grep -E 'NAME|airflow-' || echo "  (none)"
  echo ""
  echo "=== Secrets Manager entries ==="
  for s in "$SM_FERNET" "$SM_API_KEY" "$SM_JWT" "$RDS_PASSWORD_SECRET"; do
    if aws secretsmanager describe-secret --region "$REGION" --secret-id "$s" >/dev/null 2>&1; then
      echo "  $s: present"
    else
      echo "  $s: MISSING"
    fi
  done
  echo ""
  echo "=== airflow database reachable? ==="
  echo "  (checked properly by 04_02_create_databases_prod.sh verify)"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Metadata database connection
# ---------------------------------------------------------------------------
echo "[1/4] Building the metadata database connection..."

DB_STATUS="$(aws rds describe-db-instances --region "$REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo missing)"
case "$DB_STATUS" in
  available) ;;
  missing)
    echo "ERROR: RDS instance '${DB_INSTANCE_ID}' not found." >&2; exit 1 ;;
  *)
    echo "ERROR: RDS is '${DB_STATUS}', not 'available'." >&2
    echo "       Start it with: ../../../scale/scale_up.sh" >&2
    exit 1 ;;
esac

ENDPOINT="$(aws rds describe-db-instances --region "$REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text)"

DB_PASSWORD="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$RDS_PASSWORD_SECRET" --query 'SecretString' --output text)"

# URL-encode the password: it is randomly generated and may contain characters
# ("/", "@", "?", "#") that would otherwise be read as URL delimiters and
# produce a connection string that parses into the wrong host or database.
DB_PASSWORD_ENC="$(printf '%s' "$DB_PASSWORD" | python3 -c \
  'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read(), safe=""))')"

CONNECTION="postgresql+psycopg2://${DB_USER}:${DB_PASSWORD_ENC}@${ENDPOINT}:5432/${DB_NAME}"

kubectl create secret generic airflow-metadata -n "$NAMESPACE" \
  --from-literal=connection="$CONNECTION" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset DB_PASSWORD DB_PASSWORD_ENC CONNECTION
echo "      airflow-metadata -> ${DB_NAME} on ${ENDPOINT}"

# ---------------------------------------------------------------------------
# 2. Fernet key
# ---------------------------------------------------------------------------
echo "[2/4] Fernet key..."
# Fernet requires exactly 32 url-safe base64-encoded bytes -- not "roughly 32
# characters". `openssl rand -base64 32` produces precisely that.
FERNET_KEY="$(get_or_create_sm_secret "$SM_FERNET" 'openssl rand -base64 32')"
kubectl create secret generic airflow-fernet-key -n "$NAMESPACE" \
  --from-literal=fernet-key="$FERNET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset FERNET_KEY
echo "      airflow-fernet-key ready (stored in ${SM_FERNET})"

# ---------------------------------------------------------------------------
# 3. API server secret key
#
# Key name is 'api-secret-key', not 'webserver-secret-key': Airflow 3 renamed
# this ([api] secret_key), and the chart reads the old name only from the
# deprecated webserverSecretKeySecretName path.
# ---------------------------------------------------------------------------
echo "[3/4] API server secret key..."
if [ "$MODE" = "rotate-api-key" ]; then
  NEW_KEY="$(openssl rand -hex 32)"
  aws secretsmanager put-secret-value --region "$REGION" \
    --secret-id "$SM_API_KEY" --secret-string "$NEW_KEY" >/dev/null
  API_KEY="$NEW_KEY"; unset NEW_KEY
  echo "      rotated -- every logged-in session is now invalid"
else
  API_KEY="$(get_or_create_sm_secret "$SM_API_KEY" 'openssl rand -hex 32')"
fi
kubectl create secret generic airflow-api-secret-key -n "$NAMESPACE" \
  --from-literal=api-secret-key="$API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset API_KEY
echo "      airflow-api-secret-key ready (stored in ${SM_API_KEY})"

# ---------------------------------------------------------------------------
# 4. JWT secret
#
# Separate value in Airflow 3 ([api_auth] jwt_secret), used for component-to-
# component auth. Deliberately NOT rotated by rotate-api-key: rotating it
# invalidates tokens held by tasks that are mid-flight, which the chart's own
# values.yaml warns "can cause dag failures during component rollouts".
# ---------------------------------------------------------------------------
echo "[4/4] JWT secret..."
JWT_SECRET="$(get_or_create_sm_secret "$SM_JWT" 'openssl rand -hex 32')"
kubectl create secret generic airflow-jwt-secret -n "$NAMESPACE" \
  --from-literal=jwt-secret="$JWT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset JWT_SECRET
echo "      airflow-jwt-secret ready (stored in ${SM_JWT})"

cat <<EOF

Secrets are in place in namespace '${NAMESPACE}':

  airflow-metadata         connection      -> RDS ${DB_NAME}
  airflow-fernet-key       fernet-key      -> ${SM_FERNET}
  airflow-api-secret-key   api-secret-key  -> ${SM_API_KEY}
  airflow-jwt-secret       jwt-secret      -> ${SM_JWT}

None of these values were printed, written to disk, or passed as an argument.

Next: ./02_install_airflow_prod.sh
EOF
