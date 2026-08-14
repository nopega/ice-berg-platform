#!/usr/bin/env bash
# Installs the vendored AWS Load Balancer Controller. Safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_PATH="$SCRIPT_DIR/chart/aws-load-balancer-controller"
CLUSTER_NAME="${CLUSTER_NAME:-data-platform-prod}"
REGION="${AWS_REGION:-ap-southeast-1}"
NAMESPACE="kube-system"
RELEASE_NAME="aws-load-balancer-controller"
ROLE_NAME="data-platform-prod-aws-lbc-role"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required." >&2; exit 1; }; }
need aws; need helm; need kubectl

case "$MODE" in
  verify)
    kubectl get deployment "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || { echo "Controller not installed."; exit 1; }
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller -o wide
    echo ""
    echo "=== existing Ingresses (these, not this controller, create ALBs) ==="
    kubectl get ingress -A
    exit 0
    ;;
  logs) kubectl logs -n "$NAMESPACE" deployment/$RELEASE_NAME --tail=100 -f; exit 0 ;;
  uninstall)
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" || true
    echo "Controller removed. Existing ALBs must be removed by deleting their Ingress first; this command deliberately does not touch IAM or load balancers."
    exit 0
    ;;
  diff) ;;
  deploy) ;;
  *) echo "Usage: $0 [deploy|diff|verify|logs|uninstall]" >&2; exit 2 ;;
esac

[ -f "$CHART_PATH/Chart.yaml" ] || {
  cat >&2 <<EOF
ERROR: vendored chart is missing: $CHART_PATH
Download it once, inspect/commit it, then re-run:

  cd "$SCRIPT_DIR"
  helm repo add eks https://aws.github.io/eks-charts
  helm repo update
  helm pull eks/aws-load-balancer-controller --version 1.14.0 --untar --untardir ./chart
EOF
  exit 1
}

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || { echo "ERROR: IAM role missing. Run ./01_create_irsa_prod.sh first." >&2; exit 1; }

VPC_ID="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
echo "[1/3] Creating the controller ServiceAccount with IRSA..."
kubectl create serviceaccount "$RELEASE_NAME" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl annotate serviceaccount "$RELEASE_NAME" -n "$NAMESPACE" eks.amazonaws.com/role-arn="$ROLE_ARN" --overwrite >/dev/null

echo "[2/3] Installing vendored chart..."
if [ "$MODE" = diff ]; then
  helm template "$RELEASE_NAME" "$CHART_PATH" -n "$NAMESPACE" --set vpcId="$VPC_ID"
  exit 0
fi
helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" -n "$NAMESPACE" --set vpcId="$VPC_ID" --wait --timeout 10m

echo "[3/3] Result:"
kubectl get deployment "$RELEASE_NAME" -n "$NAMESPACE"
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller -o wide
cat <<EOF

The controller is ready. It has created no public endpoint and no AWS load
balancer. An ALB is created only in the next phase, when we apply the explicit
Airflow/Trino Ingress after TLS and Trino authentication are configured.
EOF
