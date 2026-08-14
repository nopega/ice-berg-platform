#!/usr/bin/env bash
#
# 02_create_persistence_secret_prod.sh
#
# The Polaris Helm chart reads its Postgres connection details from a
# Kubernetes Secret (persistence.relationalJdbc.secret in values-prod.yaml),
# not from inline values — so credentials never end up in a YAML file we
# might commit or paste somewhere. This script pulls the RDS master
# password fresh from Secrets Manager every run and (re)creates that Secret.
#
# Reuses the RDS instance already created by
# set_up_cluster/04_rds_prod, database "iceberg_catalog".
#
# Usage:
#   ./02_create_persistence_secret_prod.sh          # create / update
#   ./02_create_persistence_secret_prod.sh verify   # check status only
#
set -euo pipefail

REGION="ap-southeast-1"
RDS_INSTANCE_ID="data-platform-prod-db"
SECRETS_MANAGER_SECRET="data-platform-prod-rds-master-password"
NAMESPACE="data-platform"
K8S_SECRET_NAME="polaris-persistence"
DB_NAME="iceberg_catalog"
DB_USER="dbadmin"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws
need kubectl

echo "== Polaris persistence secret ($MODE) ============================"

if [ "$MODE" = "verify" ]; then
  kubectl get secret "$K8S_SECRET_NAME" -n "$NAMESPACE" 2>/dev/null || echo "  (not created yet)"
  exit 0
fi

echo "[1/2] Looking up RDS endpoint..."
RDS_ENDPOINT="$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_INSTANCE_ID" \
  --region "$REGION" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text 2>/dev/null || true)"
[ -n "$RDS_ENDPOINT" ] && [ "$RDS_ENDPOINT" != "None" ] \
  || { echo "ERROR: RDS instance '$RDS_INSTANCE_ID' not found. Run set_up_cluster/04_rds_prod first." >&2; exit 1; }
echo "      RDS endpoint: $RDS_ENDPOINT"

echo "[2/2] Pulling DB password from Secrets Manager and syncing k8s Secret..."
DB_PASSWORD="$(aws secretsmanager get-secret-value \
  --secret-id "$SECRETS_MANAGER_SECRET" \
  --region "$REGION" \
  --query 'SecretString' --output text)"

kubectl create secret generic "$K8S_SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-literal=username="$DB_USER" \
  --from-literal=password="$DB_PASSWORD" \
  --from-literal=jdbcUrl="jdbc:postgresql://${RDS_ENDPOINT}:5432/${DB_NAME}" \
  --dry-run=client -o yaml | kubectl apply -f -
unset DB_PASSWORD

echo ""
echo "Done. Next: ./03_bootstrap_polaris_realm_prod.sh"
