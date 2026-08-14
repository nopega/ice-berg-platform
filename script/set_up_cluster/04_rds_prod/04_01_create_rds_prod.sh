#!/usr/bin/env bash
#
# 04_create_rds_prod.sh  (PROD environment)
#
# Creates the RDS Postgres instance that backs both the Iceberg REST Catalog
# metadata and Airflow's metadata database. Placed inside the EKS cluster's
# own VPC, in private subnets, reachable only from the cluster's node
# security group — never exposed publicly.
#
# Requires the EKS cluster to already exist (../02_eks_cluster_prod/), since
# this reuses that VPC rather than creating a new one.
#
# COST: db.t4g.micro is RDS free-tier eligible (750 hrs/month for 12 months
# on eligible accounts) — effectively free for this take-home's 6-day window.
# Past free tier, roughly $0.018/hr (~$13/month) plus 20GB gp3 storage
# (~$2.30/month).
#
# Safe to re-run: every step checks current state before changing anything.
#
# Usage:
#   ./04_create_rds_prod.sh          # create + configure
#   ./04_create_rds_prod.sh verify   # report current state only

set -euo pipefail

AWS_REGION="ap-southeast-1"
CLUSTER_NAME="data-platform-prod"

DB_SUBNET_GROUP="data-platform-prod-db-subnet-group"
DB_SG_NAME="data-platform-prod-rds-sg"
DB_INSTANCE_ID="data-platform-prod-db"
DB_ENGINE="postgres"
# Pinned deliberately. Left unset, RDS picks whatever its current default major
# version is (in Aug 2026 that is Postgres 18), and Apache Airflow 3.2 only
# supports Postgres 13-17 -- see docs/STACK_SUMMARY.md "Version compatibility
# matrix". Passing the major version alone lets RDS choose the latest minor.
DB_ENGINE_VERSION="17"
DB_INSTANCE_CLASS="db.t4g.micro"
DB_STORAGE_GB=20
DB_MASTER_USER="dbadmin"
DB_NAME="platform"   # initial DB; iceberg_catalog and airflow DBs are created inside it afterward

SECRET_NAME="data-platform-prod-rds-master-password"

# Highest Postgres major version Apache Airflow 3.2 lists as supported
# (its docs say 13, 14, 15, 16, 17). Used by check_engine_version below.
MAX_SUPPORTED_PG_MAJOR=17

report() {
  echo "=== RDS instance: ${DB_INSTANCE_ID}"
  aws rds describe-db-instances --region "$AWS_REGION" --db-instance-identifier "$DB_INSTANCE_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,EngineVersion,Endpoint.Address,Endpoint.Port]' --output text 2>/dev/null \
    || echo "  exists: no"
}

# If an instance already exists, make sure it isn't running a Postgres major
# version Airflow can't use. Without this the script happily reports "already
# exists" and moves on, and the problem only surfaces much later as a failed
# `airflow db migrate` -- by which point the catalog is already populated and
# recreating the instance is expensive.
check_engine_version() {
  local current major
  current="$(aws rds describe-db-instances --region "$AWS_REGION" \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --query 'DBInstances[0].EngineVersion' --output text 2>/dev/null || true)"
  [ -n "$current" ] && [ "$current" != "None" ] || return 0
  major="${current%%.*}"
  if [ "$major" -gt "$MAX_SUPPORTED_PG_MAJOR" ]; then
    cat >&2 <<EOF

  ============================ WARNING ============================
  Existing instance '${DB_INSTANCE_ID}' runs Postgres ${current}.

  Apache Airflow 3.2 supports Postgres 13-17 only, so ${major} is
  outside the tested matrix. Polaris is unaffected; Airflow is the
  component at risk (it will most likely fail at 'airflow db migrate').

  To recreate the instance on Postgres ${DB_ENGINE_VERSION}:
      ./04_03_recreate_rds_on_supported_pg.sh

  Doing that DESTROYS all data in the instance, so it is only cheap
  while nothing has been bootstrapped into it yet.
  =================================================================

EOF
  else
    echo "engine version: Postgres ${current} (within Airflow's supported range)"
  fi
}

if [[ "${1:-}" == "verify" ]]; then
  report
  check_engine_version
  exit 0
fi

# ---------------------------------------------------------------------------
# 0. Require the EKS cluster to exist — we reuse its VPC/subnets/node SG
# ---------------------------------------------------------------------------

if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "EKS cluster '${CLUSTER_NAME}' not found. Run ../02_eks_cluster_prod/ first." >&2
  exit 1
fi

VPC_ID="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)"

# Private subnets = the ones eksctl tagged for internal load balancers.
PRIVATE_SUBNET_IDS="$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag-key,Values=kubernetes.io/role/internal-elb" \
  --query 'Subnets[].SubnetId' --output text)"

if [[ -z "$PRIVATE_SUBNET_IDS" ]]; then
  echo "ERROR: no private subnets found in ${VPC_ID} (expected kubernetes.io/role/internal-elb tag)." >&2
  exit 1
fi
echo "VPC: ${VPC_ID}"
echo "Private subnets: ${PRIVATE_SUBNET_IDS}"

# Node security group — the one eksctl created for cluster-to-node and
# node-to-node traffic. Every pod's traffic to RDS leaves from a node with
# this security group attached, so it's the correct thing to allow from.
NODE_SG_ID="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)"
echo "Cluster security group: ${NODE_SG_ID}"

# ---------------------------------------------------------------------------
# 1. DB subnet group
# ---------------------------------------------------------------------------

if aws rds describe-db-subnet-groups --region "$AWS_REGION" \
  --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1; then
  echo "DB subnet group ${DB_SUBNET_GROUP}: already exists"
else
  aws rds create-db-subnet-group --region "$AWS_REGION" \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --db-subnet-group-description "Private subnets for data-platform-prod RDS" \
    --subnet-ids $PRIVATE_SUBNET_IDS >/dev/null
  echo "DB subnet group ${DB_SUBNET_GROUP}: created"
fi

# ---------------------------------------------------------------------------
# 2. Security group — Postgres (5432) from the cluster's node SG only
# ---------------------------------------------------------------------------

DB_SG_ID="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=group-name,Values=${DB_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")"

if [[ "$DB_SG_ID" == "None" || -z "$DB_SG_ID" ]]; then
  DB_SG_ID="$(aws ec2 create-security-group --region "$AWS_REGION" \
    --group-name "$DB_SG_NAME" --description "Postgres access from EKS nodes only" --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)"
  echo "security group ${DB_SG_NAME}: created (${DB_SG_ID})"
else
  echo "security group ${DB_SG_NAME}: already exists (${DB_SG_ID})"
fi

# Flatten to a plain list of peer group IDs. An earlier version of this query
# kept UserIdGroupPairs nested inside the IpPermissions projection, which
# `--output text` rendered in a way that didn't reliably contain the group ID,
# so the check reported "missing" for a rule that was already there and the
# authorize call then failed with InvalidPermission.Duplicate.
EXISTING_PEERS="$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$DB_SG_ID" \
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`5432\` && ToPort==\`5432\`].UserIdGroupPairs[].GroupId" \
  --output text 2>/dev/null || true)"

if printf '%s\n' $EXISTING_PEERS | grep -qx "$NODE_SG_ID"; then
  echo "5432 already allowed from node security group"
else
  # Still tolerate a duplicate: the describe above is a read of eventually
  # consistent state, so treating "already exists" as success keeps the script
  # idempotent instead of aborting under `set -e`.
  if AUTH_ERR="$(aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$DB_SG_ID" \
       --protocol tcp --port 5432 --source-group "$NODE_SG_ID" 2>&1 >/dev/null)"; then
    echo "allowed 5432 from node security group ${NODE_SG_ID}"
  elif printf '%s' "$AUTH_ERR" | grep -q "InvalidPermission.Duplicate"; then
    echo "5432 already allowed from node security group (rule existed)"
  else
    echo "$AUTH_ERR" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 3. Master password — generated once, stored in Secrets Manager (never
#    printed to the terminal or written to a file on disk)
# ---------------------------------------------------------------------------

if aws secretsmanager describe-secret --region "$AWS_REGION" --secret-id "$SECRET_NAME" >/dev/null 2>&1; then
  echo "secret ${SECRET_NAME}: already exists, reusing stored password"
  DB_PASSWORD="$(aws secretsmanager get-secret-value --region "$AWS_REGION" \
    --secret-id "$SECRET_NAME" --query 'SecretString' --output text)"
else
  DB_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)"
  aws secretsmanager create-secret --region "$AWS_REGION" \
    --name "$SECRET_NAME" \
    --description "Master password for ${DB_INSTANCE_ID} (RDS Postgres)" \
    --secret-string "$DB_PASSWORD" >/dev/null
  echo "secret ${SECRET_NAME}: created (password generated, never displayed)"
fi

# ---------------------------------------------------------------------------
# 4. RDS instance
# ---------------------------------------------------------------------------
# --no-publicly-accessible: only reachable from inside the VPC.
# --no-multi-az: single-AZ to keep this within free tier / minimal cost —
#   acceptable for a 6-day take-home; note Multi-AZ as the production upgrade.
# --backup-retention-period 1: minimal automated backups (0 disables entirely,
#   which also disables point-in-time recovery — keep at least 1).

if aws rds describe-db-instances --region "$AWS_REGION" --db-instance-identifier "$DB_INSTANCE_ID" >/dev/null 2>&1; then
  echo "RDS instance ${DB_INSTANCE_ID}: already exists"
  check_engine_version
else
  aws rds create-db-instance --region "$AWS_REGION" \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --db-instance-class "$DB_INSTANCE_CLASS" \
    --engine "$DB_ENGINE" \
    --engine-version "$DB_ENGINE_VERSION" \
    --master-username "$DB_MASTER_USER" \
    --master-user-password "$DB_PASSWORD" \
    --allocated-storage "$DB_STORAGE_GB" \
    --storage-type gp3 \
    --db-name "$DB_NAME" \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --vpc-security-group-ids "$DB_SG_ID" \
    --no-publicly-accessible \
    --no-multi-az \
    --backup-retention-period 1 \
    --no-deletion-protection \
    >/dev/null
  echo "RDS instance ${DB_INSTANCE_ID}: creation started (this takes 5-10 minutes)"
fi

unset DB_PASSWORD

echo
# A stopped instance never reaches "available", so `wait` would hang until it
# times out with no explanation. Detect that case and say what to do instead.
CURRENT_STATUS="$(aws rds describe-db-instances --region "$AWS_REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --query 'DBInstances[0].DBInstanceStatus' --output text)"
case "$CURRENT_STATUS" in
  stopped|stopping)
    cat >&2 <<EOF
Instance is '${CURRENT_STATUS}', so it will never become available and this
script would hang waiting. Start it first, then re-run:

  aws rds start-db-instance --region ${AWS_REGION} --db-instance-identifier ${DB_INSTANCE_ID}

(Note: a stopped RDS instance still bills for its storage, and RDS
automatically restarts it after 7 days.)
EOF
    exit 1
    ;;
esac

echo "Waiting for instance to become available (5-10 min)..."
aws rds wait db-instance-available --region "$AWS_REGION" --db-instance-identifier "$DB_INSTANCE_ID"

echo
echo "--- Final state ---"
report

ENDPOINT="$(aws rds describe-db-instances --region "$AWS_REGION" --db-instance-identifier "$DB_INSTANCE_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text)"

cat <<EOF

RDS endpoint: ${ENDPOINT}:5432
Master password: stored in Secrets Manager as "${SECRET_NAME}" (retrieve with
  aws secretsmanager get-secret-value --region ${AWS_REGION} --secret-id ${SECRET_NAME} --query SecretString --output text
)

This endpoint is private — reachable only from pods running on this
cluster's nodes, not from your Mac directly. Next: create the iceberg_catalog
and airflow databases by running psql from inside the cluster:

  kubectl run psql-client --rm -it --restart=Never --image=postgres:17 -- \\
    psql "host=${ENDPOINT} port=5432 user=${DB_MASTER_USER} dbname=platform"

(it will prompt for the password — paste the value retrieved above)
Then inside psql:
  CREATE DATABASE iceberg_catalog;
  CREATE DATABASE airflow;
EOF
