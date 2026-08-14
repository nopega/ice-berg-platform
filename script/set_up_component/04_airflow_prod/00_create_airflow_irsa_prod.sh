#!/usr/bin/env bash
#
# 00_create_airflow_irsa_prod.sh
#
# Creates the IAM role Airflow's pods assume to write task logs to S3.
#
# WHY REMOTE LOGGING IS NOT OPTIONAL HERE
# ----------------------------------------
# KubernetesExecutor deletes a task's pod as soon as the task finishes. The
# log file lives on that pod's disk, so it goes with it. Without remote
# logging, a failed task shows up in the UI as a red square with the message
# "log file does not exist" -- exactly when the log is the only thing that
# would explain the failure. That is survivable while running a smoke test and
# unworkable once real ETL jobs start failing at 3am.
#
# WHY A SEPARATE ROLE RATHER THAN REUSING THE EXISTING ONE
# ---------------------------------------------------------
# `data-platform-prod-irsa-role` already exists, but two things make it the
# wrong role to reuse:
#
#   1. Its trust policy is `StringEquals` on exactly one subject --
#      system:serviceaccount:data-platform:data-platform-workload -- so it
#      cannot be assumed from the `airflow` namespace at all. Widening it would
#      mean loosening the condition that makes it precise.
#
#   2. It grants read/write on data-store-prod-warehouse, the bucket holding
#      every Iceberg table. Airflow's scheduler has no business being able to
#      delete Parquet files; it needs to append log text and nothing else.
#      Reusing the role would hand the orchestrator the same reach as the
#      engines it orchestrates.
#
# So this role is scoped to one prefix of one bucket:
# s3://data-store-prod-logs/airflow/*.
#
# The trust policy uses StringLike with `airflow-*` because the Helm chart
# creates a separate ServiceAccount per component (airflow-scheduler,
# airflow-worker, airflow-triggerer, ...) and all of them read or write logs --
# the API server reads them to render the UI, everything else writes. Listing
# them individually would break silently the next time the chart adds one.
#
# Usage:
#   ./00_create_airflow_irsa_prod.sh          # create / update (idempotent)
#   ./00_create_airflow_irsa_prod.sh verify   # report state, change nothing
#   ./00_create_airflow_irsa_prod.sh delete   # remove role and policy
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="ap-southeast-1"
CLUSTER_NAME="data-platform-prod"
K8S_NAMESPACE="airflow"
SA_PATTERN="airflow-*"          # every ServiceAccount the chart creates
ROLE_NAME="data-platform-prod-airflow-irsa-role"
POLICY_NAME="data-platform-prod-airflow-s3-logs"
LOGS_BUCKET="data-store-prod-logs"
LOG_PREFIX="airflow"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

if [ "$MODE" = "verify" ]; then
  echo "=== role ==="
  aws iam get-role --role-name "$ROLE_NAME" \
    --query 'Role.[RoleName,Arn,CreateDate]' --output table 2>/dev/null \
    || echo "  not created"
  echo ""
  echo "=== trust policy ==="
  aws iam get-role --role-name "$ROLE_NAME" \
    --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null || echo "  n/a"
  echo ""
  echo "=== attached policies ==="
  aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
    --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null || echo "  n/a"
  echo ""
  echo "=== what the chart should be annotated with ==="
  echo "  eks.amazonaws.com/role-arn: ${ROLE_ARN}"
  exit 0
fi

if [ "$MODE" = "delete" ]; then
  aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
  aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true
  echo "Removed ${ROLE_NAME} and ${POLICY_NAME} (if they existed)."
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. The cluster's OIDC provider
#
# IRSA works by the cluster issuing a signed token that names the pod's
# ServiceAccount, and IAM trusting that issuer. The issuer URL is unique per
# cluster, so it has to be looked up rather than written down.
# ---------------------------------------------------------------------------
echo "[1/4] Finding the cluster's OIDC provider..."
OIDC_URL="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || true)"
[ -n "$OIDC_URL" ] && [ "$OIDC_URL" != "None" ] || {
  echo "ERROR: cluster '${CLUSTER_NAME}' not found, or it has no OIDC issuer." >&2
  exit 1
}
OIDC_HOST="${OIDC_URL#https://}"
PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"

aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1 || {
  echo "ERROR: no IAM OIDC provider registered for this cluster." >&2
  echo "       ../../../set_up_cluster/03_irsa_role_prod/ creates it." >&2
  exit 1
}
echo "      ${OIDC_HOST}"

# ---------------------------------------------------------------------------
# 2. Trust policy
#
# StringLike, not StringEquals, because of the wildcard in the ServiceAccount
# name. The namespace is still fixed, so a ServiceAccount called
# `airflow-scheduler` in some *other* namespace cannot assume this role.
# ---------------------------------------------------------------------------
echo "[2/4] Writing the trust policy..."
TRUST_FILE="$(mktemp)"
trap 'rm -f "$TRUST_FILE" "${POLICY_FILE:-}"' EXIT
cat > "$TRUST_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${PROVIDER_ARN}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringLike": {
          "${OIDC_HOST}:sub": "system:serviceaccount:${K8S_NAMESPACE}:${SA_PATTERN}"
        },
        "StringEquals": {
          "${OIDC_HOST}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
echo "      trusts system:serviceaccount:${K8S_NAMESPACE}:${SA_PATTERN}"

# ---------------------------------------------------------------------------
# 3. Permission policy -- one prefix of one bucket
#
# The ListBucket statement is conditioned on the same prefix. Without the
# condition, ListBucket on the bucket ARN would let Airflow enumerate every
# object in the logs bucket, including Trino's audit logs, which is a wider
# read than "write my own logs" needs.
# ---------------------------------------------------------------------------
echo "[3/4] Writing the permission policy..."
POLICY_FILE="$(mktemp)"
cat > "$POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AirflowLogObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${LOGS_BUCKET}/${LOG_PREFIX}/*"
    },
    {
      "Sid": "AirflowLogListing",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::${LOGS_BUCKET}",
      "Condition": {
        "StringLike": { "s3:prefix": ["${LOG_PREFIX}/*"] }
      }
    }
  ]
}
EOF
echo "      s3://${LOGS_BUCKET}/${LOG_PREFIX}/* only"

# ---------------------------------------------------------------------------
# 4. Create or update. Both halves are written every run rather than skipped
#    when the role exists, so editing this file and re-running actually
#    changes the live policy instead of quietly doing nothing.
# ---------------------------------------------------------------------------
echo "[4/4] Applying..."
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
    --policy-document "file://${TRUST_FILE}" >/dev/null
  echo "      role exists, trust policy updated"
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://${TRUST_FILE}" \
    --description "Airflow task-log writes to s3://${LOGS_BUCKET}/${LOG_PREFIX}/" >/dev/null
  echo "      role created"
fi

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  # A managed policy keeps up to 5 versions; the oldest non-default one is
  # pruned here so repeated runs cannot hit LimitExceeded.
  OLD_VERSIONS="$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
    --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)"
  COUNT="$(printf '%s' "$OLD_VERSIONS" | wc -w | tr -d ' ')"
  if [ "$COUNT" -ge 4 ]; then
    OLDEST="$(printf '%s' "$OLD_VERSIONS" | awk '{print $NF}')"
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST" >/dev/null
  fi
  aws iam create-policy-version --policy-arn "$POLICY_ARN" \
    --policy-document "file://${POLICY_FILE}" --set-as-default >/dev/null
  echo "      policy exists, new version set as default"
else
  aws iam create-policy --policy-name "$POLICY_NAME" \
    --policy-document "file://${POLICY_FILE}" >/dev/null
  echo "      policy created"
fi

aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" >/dev/null
echo "      policy attached"

cat <<EOF

Role ready:

  ${ROLE_ARN}

Assumable by any ServiceAccount matching
  system:serviceaccount:${K8S_NAMESPACE}:${SA_PATTERN}
and able to touch only
  s3://${LOGS_BUCKET}/${LOG_PREFIX}/*

chart/airflow/values.yaml already annotates each component's ServiceAccount
with this ARN, so the next install picks it up:

  ./02_install_airflow_prod.sh

Verify afterwards that a pod actually received credentials:

  kubectl exec -n ${K8S_NAMESPACE} deploy/airflow-scheduler -c scheduler -- \\
    env | grep AWS_

AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE appearing there means the
annotation was applied and the pod was restarted after it. Their absence
almost always means the pod predates the annotation.
EOF
