#!/usr/bin/env bash
#
# 01_create_namespace_and_sa_prod.sh
#
# (Renamed from 01_deploy_iceberg_catalog_prod.sh, which was a misleading
# name: this script deploys nothing. Polaris itself is installed by
# 04_install_polaris_prod.sh.)
#
# Creates the two Kubernetes objects the Polaris Helm chart does NOT manage:
#
#   1. the namespace `data-platform`
#      The chart does not create it, and 04_ deliberately does not pass
#      --create-namespace, so the namespace belongs to us rather than to a
#      Helm release -- `helm uninstall` then cannot take it (and everything
#      else in it) down with the release.
#
#   2. the ServiceAccount `data-platform-workload`, annotated with the IRSA
#      role ARN.
#      The chart *can* create a ServiceAccount, but we set
#      serviceAccount.create: false in chart/polaris/values.yaml and point it
#      at this one instead, because the annotation must carry a role ARN that
#      contains the AWS account ID -- a runtime value that cannot be committed
#      into values.yaml. serviceaccount.yaml holds a __IRSA_ROLE_ARN__
#      placeholder that this script substitutes at apply time, so no real ARN
#      is ever written to disk in the repository.
#
# Everything downstream depends on step 2: without the annotation the EKS Pod
# Identity webhook injects nothing, the AWS SDK inside the pod falls back to
# the node's identity, and S3 calls fail with 403 -- while the pod itself
# looks perfectly healthy. That is a slow failure to diagnose, which is why
# this script verifies the IAM role exists before annotating anything.
#
# Usage:
#   ./01_create_namespace_and_sa_prod.sh          # apply
#   ./01_create_namespace_and_sa_prod.sh verify   # check status only
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="data-platform-prod"
REGION="ap-southeast-1"
IRSA_ROLE_NAME="data-platform-prod-irsa-role"
NAMESPACE="data-platform"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws
need kubectl

echo "== Namespace + ServiceAccount ($MODE) ============================"

kubectl get nodes >/dev/null 2>&1 \
  || { echo "ERROR: kubectl can't reach the cluster. Run: aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION" >&2; exit 1; }

if [ "$MODE" = "verify" ]; then
  echo "[verify] Namespace:"
  kubectl get namespace "$NAMESPACE" 2>/dev/null || echo "  (not created yet)"
  echo "[verify] ServiceAccount annotation (should be the IRSA role ARN):"
  kubectl get serviceaccount data-platform-workload -n "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}' 2>/dev/null \
    || echo "  (not created yet)"
  exit 0
fi

IRSA_ROLE_ARN="$(aws iam get-role --role-name "$IRSA_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null || true)"
[ -n "$IRSA_ROLE_ARN" ] && [ "$IRSA_ROLE_ARN" != "None" ] \
  || { echo "ERROR: '$IRSA_ROLE_NAME' not found. Run set_up_cluster/03_irsa_role_prod first." >&2; exit 1; }
echo "IRSA role: $IRSA_ROLE_ARN"

kubectl apply -f "$SCRIPT_DIR/namespace.yaml"
sed "s#__IRSA_ROLE_ARN__#${IRSA_ROLE_ARN}#g" "$SCRIPT_DIR/serviceaccount.yaml" | kubectl apply -f -

echo ""
echo "Done. Next: ./02_create_persistence_secret_prod.sh"
