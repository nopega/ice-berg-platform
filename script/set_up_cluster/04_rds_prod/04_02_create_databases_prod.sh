#!/usr/bin/env bash
#
# 05_create_databases_prod.sh  (PROD environment)
#
# Creates the two logical databases inside the RDS instance from
# 04_create_rds_prod.sh: iceberg_catalog (Iceberg REST Catalog metadata) and
# airflow (Airflow metadata). RDS is private, so this connects via a
# throwaway pod running inside the EKS cluster (same VPC) rather than from
# your Mac directly.
#
# Safe to re-run: uses the `SELECT ... WHERE NOT EXISTS (...) \gexec` idiom,
# psql's standard way to make CREATE DATABASE idempotent (Postgres has no
# native "CREATE DATABASE IF NOT EXISTS").
#
# Usage:
#   ./05_create_databases_prod.sh          # create the databases
#   ./05_create_databases_prod.sh verify   # list databases only, change nothing
#
# Requires: ../04_create_rds_prod.sh already run, kubectl pointed at the
#           data-platform-prod cluster.

set -euo pipefail

AWS_REGION="ap-southeast-1"
DB_INSTANCE_ID="data-platform-prod-db"
SECRET_NAME="data-platform-prod-rds-master-password"
DB_MASTER_USER="dbadmin"
TARGET_DBS=("iceberg_catalog" "airflow")

if ! aws rds describe-db-instances --region "$AWS_REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID" >/dev/null 2>&1; then
  echo "ERROR: RDS instance '${DB_INSTANCE_ID}' not found. Run 04_create_rds_prod.sh first." >&2
  exit 1
fi

ENDPOINT="$(aws rds describe-db-instances --region "$AWS_REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text)"

PASSWORD="$(aws secretsmanager get-secret-value --region "$AWS_REGION" \
  --secret-id "$SECRET_NAME" --query 'SecretString' --output text)"

# Connect to the always-present "postgres" maintenance database — CREATE
# DATABASE cannot run while connected to the database being created/checked.
CONN="host=${ENDPOINT} port=5432 user=${DB_MASTER_USER} dbname=postgres password=${PASSWORD}"

run_psql() {
  # -i (no -t): stdin is piped in, not a real terminal — matches how this
  # function is invoked below via a heredoc.
  # postgres:17 matches the server major version pinned in
  # 04_01_create_rds_prod.sh. Keeping client and server on the same major
  # avoids psql meta-commands (\l and friends) failing on catalog columns
  # that differ between versions.
  kubectl run psql-client --rm -i --restart=Never --image=postgres:17 -- \
    psql "$1"
}

if [[ "${1:-}" == "verify" ]]; then
  echo "=== Databases on ${ENDPOINT} ==="
  run_psql "$CONN" <<'SQL'
SELECT datname FROM pg_database ORDER BY datname;
SQL
  unset PASSWORD
  exit 0
fi

echo "Creating databases on ${ENDPOINT} (if missing)..."

{
  for DB in "${TARGET_DBS[@]}"; do
    # \gexec: run whichever CREATE DATABASE statement the SELECT produces —
    # produces zero rows (nothing to run) if the database already exists.
    echo "SELECT 'CREATE DATABASE ${DB}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB}')\\gexec"
  done
  echo "SELECT datname FROM pg_database ORDER BY datname;"
} | run_psql "$CONN"

unset PASSWORD

echo
echo "Done. iceberg_catalog and airflow databases are present (created just now, or already existed)."
