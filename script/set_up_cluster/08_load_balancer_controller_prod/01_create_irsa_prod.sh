#!/usr/bin/env bash
# Creates the least-privilege IAM policy and IRSA role used only by the AWS
# Load Balancer Controller. It does not create an ALB or expose any Service.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_DOCUMENT="$SCRIPT_DIR/iam-policy.json"
CLUSTER_NAME="${CLUSTER_NAME:-data-platform-prod}"
REGION="${AWS_REGION:-ap-southeast-1}"
NAMESPACE="kube-system"
SERVICE_ACCOUNT="aws-load-balancer-controller"
ROLE_NAME="data-platform-prod-aws-lbc-role"
POLICY_NAME="data-platform-prod-aws-lbc-policy"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required." >&2; exit 1; }; }
need aws; need kubectl
[ -f "$POLICY_DOCUMENT" ] || { echo "ERROR: missing $POLICY_DOCUMENT" >&2; exit 1; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

report() {
  echo "=== IAM policy ==="
  aws iam get-policy --policy-arn "$POLICY_ARN" --query 'Policy.{Arn:Arn,DefaultVersionId:DefaultVersionId}' --output table 2>/dev/null || echo "  not found"
  echo "=== IAM role ==="
  aws iam get-role --role-name "$ROLE_NAME" --query 'Role.{Arn:Arn,CreateDate:CreateDate}' --output table 2>/dev/null || echo "  not found"
  echo "=== ServiceAccount annotation ==="
  kubectl get serviceaccount "$SERVICE_ACCOUNT" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}' 2>/dev/null || echo "  ServiceAccount not created yet (expected before Helm install)"
}

case "$MODE" in
  verify) report; exit 0 ;;
  *) ;;
esac

OIDC_ISSUER="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || true)"
[ -n "$OIDC_ISSUER" ] && [ "$OIDC_ISSUER" != "None" ] || { echo "ERROR: EKS cluster '$CLUSTER_NAME' not found in $REGION." >&2; exit 1; }
OIDC_PROVIDER="${OIDC_ISSUER#https://}"
PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1 || {
  echo "ERROR: OIDC provider is missing. Run: eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --region $REGION --approve" >&2; exit 1;
}

TRUST_POLICY="$(mktemp -t aws-lbc-irsa).json"
trap 'rm -f "$TRUST_POLICY"' EXIT
cat > "$TRUST_POLICY" <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Federated":"${PROVIDER_ARN}"},"Action":"sts:AssumeRoleWithWebIdentity","Condition":{"StringEquals":{"${OIDC_PROVIDER}:aud":"sts.amazonaws.com","${OIDC_PROVIDER}:sub":"system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT}"}}}]}
EOF

echo "[1/3] IAM policy..."
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  echo "      ${POLICY_NAME} already exists"
else
  aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://${POLICY_DOCUMENT}" --description "Permissions for AWS Load Balancer Controller in ${CLUSTER_NAME}" >/dev/null
  echo "      created ${POLICY_NAME}"
fi

echo "[2/3] IRSA role..."
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "file://${TRUST_POLICY}"
  echo "      ${ROLE_NAME} trust policy refreshed"
else
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "file://${TRUST_POLICY}" --description "IRSA role for ${NAMESPACE}/${SERVICE_ACCOUNT}" >/dev/null
  echo "      created ${ROLE_NAME}"
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"

echo "[3/3] Ready for the Helm chart..."
echo "      role ARN: ${ROLE_ARN}"
cat <<EOF

No load balancer was created. The next script creates the ServiceAccount with
this role annotation and installs the controller; an ALB appears only later
when an Ingress is applied.

Next: ./02_install_controller_prod.sh
EOF
