#!/usr/bin/env bash
#
# 00_create_spark_irsa_prod.sh
#
# Creates the IAM role Spark driver and executor pods assume to read and write
# Iceberg data in S3.
#
# WHAT THIS ROLE ACTUALLY COVERS -- IT IS LESS THAN IT LOOKS
# ------------------------------------------------------------
# An earlier version of this comment claimed Polaris credential vending was
# "not used here yet", and that Spark therefore reached S3 for table data with
# this role. That was wrong, and the smoke test proved it: a failed write named
# a completely different identity --
#
#   User: arn:aws:sts::...:assumed-role/data-platform-prod-polaris-storage-role/
#   PolarisAwsCredentialsStorageIntegration is not authorized to perform:
#   s3:PutObject on ".../bronze/log/query_audit/smoke_test/metadata/....json"
#
# So vending IS in effect. Spark asks Polaris for the table, Polaris hands back
# short-lived credentials minted from ITS storage role, and those credentials
# write the Parquet and the metadata. The division is:
#
#   table data + metadata  -> data-platform-prod-polaris-storage-role
#                             (policy: 01_iceberg.../s3-storage-access-policy.json)
#   Spark event log        -> this role
#
# Two consequences worth holding onto:
#
#   1. When Spark cannot write a TABLE, this file is the wrong place to look.
#      The storage role's policy is.
#   2. The governance story is stronger than previously written down, not
#      weaker: access to bytes is granted per-request by the catalog that also
#      decides who may see the table, rather than by a standing role attached
#      to every Spark pod.
#
# The warehouse permissions below are therefore belt-and-braces. They are kept
# because a job can still touch the warehouse outside the catalog path -- for
# example reading raw files staged in S3 before they become a bronze table --
# and because removing them would make a failure mode ("Spark can suddenly not
# read its own staging area") depend on a subtlety of which client was used.
#
# WHY A SEPARATE ROLE FROM TRINO'S AND AIRFLOW'S
# -----------------------------------------------
# Airflow's role reaches only s3://data-store-prod-logs/airflow/*. Trino reads
# through Polaris. Spark is the only component that writes table data
# directly, so it is the only one that needs write access to the warehouse
# bucket -- and it should be the only one that has it. If a table is ever
# corrupted by a bad write, this role is the short list of what could have
# done it.
#
# Usage:
#   ./00_create_spark_irsa_prod.sh          # create / update (idempotent)
#   ./00_create_spark_irsa_prod.sh verify   # report state, change nothing
#   ./00_create_spark_irsa_prod.sh delete   # remove role and policy
#
set -euo pipefail

REGION="ap-southeast-1"
CLUSTER_NAME="data-platform-prod"
K8S_NAMESPACE="spark"
SA_NAME="spark"
ROLE_NAME="data-platform-prod-spark-irsa-role"
POLICY_NAME="data-platform-prod-spark-s3-warehouse"
WAREHOUSE_BUCKET="data-store-prod-warehouse"
LOGS_BUCKET="data-store-prod-logs"
EVENTLOG_PREFIX="spark-events"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

if [ "$MODE" = "verify" ]; then
  echo "=== role ==="
  aws iam get-role --role-name "$ROLE_NAME" \
    --query 'Role.[RoleName,Arn,CreateDate]' --output table 2>/dev/null || echo "  not created"
  echo ""
  echo "=== trust policy ==="
  aws iam get-role --role-name "$ROLE_NAME" \
    --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null || echo "  n/a"
  echo ""
  echo "=== attached policies ==="
  aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
    --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null || echo "  n/a"
  echo ""
  echo "=== what the ServiceAccount must be annotated with ==="
  echo "  eks.amazonaws.com/role-arn: ${ROLE_ARN}"
  exit 0
fi

if [ "$MODE" = "delete" ]; then
  aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
  aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true
  echo "Removed ${ROLE_NAME} and ${POLICY_NAME} (if they existed)."
  echo "No S3 data is touched -- this only removes the ability to reach it."
  exit 0
fi

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
echo "[2/4] Writing the trust policy..."
TRUST_FILE="$(mktemp)"
POLICY_FILE="$(mktemp)"
trap 'rm -f "$TRUST_FILE" "$POLICY_FILE"' EXIT

# StringEquals on exactly one ServiceAccount. Driver and executor pods both run
# as `spark` in namespace `spark` -- the operator does not generate per-pod
# ServiceAccounts, so no wildcard is needed here (unlike Airflow, whose chart
# creates one SA per component).
cat > "$TRUST_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${PROVIDER_ARN}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_HOST}:sub": "system:serviceaccount:${K8S_NAMESPACE}:${SA_NAME}",
          "${OIDC_HOST}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
echo "      trusts system:serviceaccount:${K8S_NAMESPACE}:${SA_NAME}"

# ---------------------------------------------------------------------------
echo "[3/4] Writing the permission policy..."
# Scoped to the three medallion prefixes rather than the whole bucket. The
# bucket root holds nothing else today, so this changes nothing operationally
# -- but it means a future prefix (say an export area) is not silently
# writable by every ETL job the day it is created.
#
# DeleteObject is required and worth being explicit about: Iceberg's own
# maintenance (expiring snapshots, removing orphan files, rewriting small
# files into large ones) deletes Parquet. A read-plus-write-only role produces
# tables that grow forever and compaction jobs that fail late.
#
# AbortMultipartUpload matters for the same reason it did for Harbor: a
# Spark write of a large Parquet file is multipart, and an executor lost to a
# spot reclaim mid-write leaves parts that are billed but invisible to `ls`.
#
# TWO S3 CLIENTS, TWO ACCESS PATTERNS -- WHY THE EVENT-LOG STATEMENTS LOOK ODD
# -----------------------------------------------------------------------------
# Iceberg table data goes through S3FileIO, which addresses objects directly.
# For it, "<prefix>/*" is enough, which is why the warehouse statements below
# are the shape one would expect.
#
# The Spark event log goes through S3A (the s3a:// scheme), which emulates a
# filesystem on top of an object store. getFileStatus on the log DIRECTORY
# issues HeadObject against the BARE key "spark-events" -- no trailing slash --
# before it lists anything. A policy granting only "spark-events/*" does not
# cover that key, S3 answers 403, and S3A treats 403 as fatal rather than as
# "not found". The job then dies during SparkContext creation:
#
#   java.nio.file.AccessDeniedException: s3a://data-store-prod-logs/spark-events:
#   getFileStatus on ...: S3Exception: null (Status Code: 403)
#
# before reading a single row, and the message points at the path rather than
# at the missing permission. Hence the bare-key ARN alongside the wildcard one,
# and the bare prefix alongside the wildcard prefix, in the two statements at
# the end of this document.
#
# Note that IAM policy JSON accepts no comment fields, so this has to live here
# rather than next to the statements it explains.
cat > "$POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "IcebergTableData",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::${WAREHOUSE_BUCKET}/bronze/*",
        "arn:aws:s3:::${WAREHOUSE_BUCKET}/silver/*",
        "arn:aws:s3:::${WAREHOUSE_BUCKET}/gold/*"
      ]
    },
    {
      "Sid": "IcebergTableListing",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::${WAREHOUSE_BUCKET}",
      "Condition": {
        "StringLike": { "s3:prefix": ["bronze/*", "silver/*", "gold/*", ""] }
      }
    },
    {
      "Sid": "SparkEventLogs",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::${LOGS_BUCKET}/${EVENTLOG_PREFIX}",
        "arn:aws:s3:::${LOGS_BUCKET}/${EVENTLOG_PREFIX}/*"
      ]
    },
    {
      "Sid": "SparkEventLogListing",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::${LOGS_BUCKET}",
      "Condition": {
        "StringLike": { "s3:prefix": ["${EVENTLOG_PREFIX}", "${EVENTLOG_PREFIX}/*"] }
      }
    }
  ]
}
EOF
echo "      warehouse bronze/silver/gold + s3://${LOGS_BUCKET}/${EVENTLOG_PREFIX}/"

# ---------------------------------------------------------------------------
echo "[4/4] Applying..."
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
    --policy-document "file://${TRUST_FILE}" >/dev/null
  echo "      role exists, trust policy updated"
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://${TRUST_FILE}" \
    --description "Spark driver/executor access to Iceberg data in s3://${WAREHOUSE_BUCKET}" >/dev/null
  echo "      role created"
fi

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
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

# ---------------------------------------------------------------------------
# The event-log directory has to EXIST before a job starts.
#
# S3 has no directories, and Iceberg does not care -- S3FileIO addresses
# objects and a "missing" prefix is simply a prefix with nothing under it. But
# Spark's event logging goes through S3A, and EventLoggingListener calls
# requireLogBaseDirAsDirectory during SparkContext construction. Against an
# empty prefix S3A finds no object and no children, concludes the path does not
# exist, and the job dies before it starts:
#
#   java.io.FileNotFoundException: No such file or directory:
#   s3a://data-store-prod-logs/spark-events
#
# A zero-byte object whose key ENDS IN A SLASH is the convention every S3
# filesystem shim uses to mean "directory". Creating it here rather than by
# hand means a rebuilt bucket does not reintroduce the failure -- and this is
# the script that already owns this prefix, since it is the one granting
# access to it.
#
# Costs nothing: zero bytes, and the abort-incomplete-multipart lifecycle rule
# on the logs bucket does not touch it.
echo "      ensuring s3://${LOGS_BUCKET}/${EVENTLOG_PREFIX}/ exists..."
if aws s3api head-object --bucket "$LOGS_BUCKET" --key "${EVENTLOG_PREFIX}/" >/dev/null 2>&1; then
  echo "      already present"
else
  aws s3api put-object --bucket "$LOGS_BUCKET" --key "${EVENTLOG_PREFIX}/" >/dev/null
  echo "      created"
fi

cat <<EOF

Role ready:

  ${ROLE_ARN}

Next:

  ./01_create_namespace_and_sa_prod.sh

which creates namespace '${K8S_NAMESPACE}', the '${SA_NAME}' ServiceAccount
annotated with this ARN, and the RBAC a Spark driver needs in order to create
its own executor pods.
EOF
