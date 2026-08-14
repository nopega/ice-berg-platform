#!/usr/bin/env bash
#
# 03_create_irsa_role_prod.sh  (PROD environment — IRSA)
#
# Creates the IAM role that EKS pods (Trino, Spark) assume via IRSA to reach
# the prod S3 buckets — no static Access Key on any node or pod. See README.md
# in this folder for why this differs from the TEST instance-profile approach
# (../03_iam_role_test/).
#
# This script needs a real EKS cluster to already exist (its OIDC provider is
# embedded directly into the trust policy) — that's ../../02_eks_cluster_prod/,
# which must run before this one. If the cluster isn't there yet, this script
# exits early with a clear explanation instead of failing on a confusing AWS
# error — safe to run anytime, including before the cluster exists.
#
# Usage:
#   ./03_create_irsa_role_prod.sh          # create + configure
#   ./03_create_irsa_role_prod.sh verify   # report current state only, change nothing
#
# Configurable via environment variables (defaults shown):
#   CLUSTER_NAME=data-platform-prod
#   AWS_REGION=ap-southeast-1
#   NAMESPACE=data-platform
#   SERVICE_ACCOUNT=data-platform-workload
#
# Requires: AWS CLI v2, an EKS cluster reachable by `aws eks describe-cluster`,
#           s3-access-policy.json present next to this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S3_POLICY="${SCRIPT_DIR}/s3-access-policy.json"

if [[ ! -f "$S3_POLICY" ]]; then
  echo "ERROR: missing policy file: ${S3_POLICY}" >&2
  exit 1
fi

CLUSTER_NAME="${CLUSTER_NAME:-data-platform-prod}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
NAMESPACE="${NAMESPACE:-data-platform}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-data-platform-workload}"

ROLE_NAME="data-platform-prod-irsa-role"
POLICY_NAME="data-platform-prod-s3-access"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

echo "Account:          ${ACCOUNT_ID}"
echo "Cluster:           ${CLUSTER_NAME} (${AWS_REGION})"
echo "Role:              ${ROLE_NAME}"
echo "K8s identity:       ${NAMESPACE}/${SERVICE_ACCOUNT}"
echo

report() {
  echo "=== IAM role: ${ROLE_NAME}"
  if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    echo "  exists: yes"
    echo "  attached policies: $(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[].PolicyName' --output text)"
  else
    echo "  exists: no"
  fi

  echo "=== IAM policy: ${POLICY_NAME}"
  if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo "  exists: yes ($POLICY_ARN)"
  else
    echo "  exists: no"
  fi
}

if [[ "${1:-}" == "verify" ]]; then
  report
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Require the EKS cluster to exist — run ../02_eks_cluster_prod/ first.
# ---------------------------------------------------------------------------

OIDC_ISSUER="$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query "cluster.identity.oidc.issuer" --output text 2>/dev/null || true)"

if [[ -z "$OIDC_ISSUER" || "$OIDC_ISSUER" == "None" ]]; then
  cat <<EOF
EKS cluster '${CLUSTER_NAME}' not found in region ${AWS_REGION}.

Run ../../02_eks_cluster_prod/02_create_eks_cluster_prod.sh first — this script
needs the cluster's OIDC provider, which is created along with the cluster.
Nothing has been changed.

Once the cluster exists, re-run this script (or override the name):
  CLUSTER_NAME=your-cluster-name ./03_create_irsa_role_prod.sh
EOF
  exit 0
fi

OIDC_ID="${OIDC_ISSUER##*/}"
OIDC_PROVIDER="${OIDC_ISSUER#https://}"

echo "OIDC issuer found: ${OIDC_ISSUER}"

# ---------------------------------------------------------------------------
# 2. Confirm the IAM OIDC identity provider is registered for this cluster.
#    (eksctl create cluster with a recent version does this automatically;
#    otherwise: eksctl utils associate-iam-oidc-provider --cluster ... --approve)
# ---------------------------------------------------------------------------

PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1; then
  cat <<EOF
ERROR: no IAM OIDC provider registered for this cluster yet.

Register it first:
  eksctl utils associate-iam-oidc-provider --cluster ${CLUSTER_NAME} --region ${AWS_REGION} --approve

Then re-run this script.
EOF
  exit 1
fi
echo "IAM OIDC provider confirmed: ${PROVIDER_ARN}"

# ---------------------------------------------------------------------------
# 3. Generate the trust policy (cluster-specific — cannot be a static file
#    like the TEST one, since the OIDC provider ARN is unique per cluster).
#    Scoped to exactly one Kubernetes ServiceAccount via the `sub` condition.
# ---------------------------------------------------------------------------

TRUST_POLICY_FILE="$(mktemp -t irsa-trust-policy).json"
trap 'rm -f "$TRUST_POLICY_FILE"' EXIT

cat > "$TRUST_POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${PROVIDER_ARN}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT}",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

# ---------------------------------------------------------------------------
# 4. Role + policy (same idempotent pattern as the TEST script)
# ---------------------------------------------------------------------------

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "file://${TRUST_POLICY_FILE}"
  echo "role ${ROLE_NAME}: already exists, trust policy refreshed"
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://${TRUST_POLICY_FILE}" \
    --description "IRSA role for ${NAMESPACE}/${SERVICE_ACCOUNT} - scoped to data-store-prod-* S3 buckets only" \
    >/dev/null
  echo "role ${ROLE_NAME}: created"
fi

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  echo "policy ${POLICY_NAME}: already exists, skipping create"
else
  aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://${S3_POLICY}" \
    --description "Read/write access to data-store-prod-warehouse and data-store-prod-logs only" \
    >/dev/null
  echo "policy ${POLICY_NAME}: created"
fi

aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
echo "policy attached to role"

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

echo
echo "--- Final state ---"
report

cat <<EOF

Next step (once the ServiceAccount is applied to the cluster) — annotate it
so pods using it pick up this role:

  kubectl annotate serviceaccount ${SERVICE_ACCOUNT} \\
    -n ${NAMESPACE} \\
    eks.amazonaws.com/role-arn=${ROLE_ARN} \\
    --overwrite

Or set it directly in the ServiceAccount manifest:

  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: ${SERVICE_ACCOUNT}
    namespace: ${NAMESPACE}
    annotations:
      eks.amazonaws.com/role-arn: ${ROLE_ARN}
EOF
