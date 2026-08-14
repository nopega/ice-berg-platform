#!/usr/bin/env bash
#
# 99_delete_eks_cluster_prod.sh  (PROD environment)
#
# Tears down the EKS cluster and everything eksctl created with it (VPC,
# subnets, NAT gateway, node groups, add-on roles). Run this as soon as you
# are done — the control plane bills $0.10/hr whether or not it is being used.
#
# S3 buckets, RDS and the IAM roles created by the other scripts are NOT
# touched: they are managed separately and hold state you probably want to
# keep. Deleting the cluster invalidates the IRSA trust policy (the OIDC
# provider goes away), so re-run 03_irsa_role_prod/03_create_irsa_role_prod.sh
# after recreating the cluster.
#
# Usage:
#   ./99_delete_eks_cluster_prod.sh       # prompts for confirmation
#   ./99_delete_eks_cluster_prod.sh -y    # skip the prompt

set -euo pipefail

CLUSTER_NAME="data-platform-prod"
AWS_REGION="ap-southeast-1"

for tool in aws eksctl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: '${tool}' is not installed." >&2
    exit 1
  fi
done

if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Cluster '${CLUSTER_NAME}' does not exist in ${AWS_REGION} — nothing to delete."
  exit 0
fi

if [[ "${1:-}" != "-y" ]]; then
  cat <<EOF
About to DELETE EKS cluster '${CLUSTER_NAME}' in ${AWS_REGION}.

This removes the control plane, both node groups, the VPC and the NAT
gateway. Anything running only inside the cluster is lost.

NOT deleted: S3 buckets, RDS, IAM roles/policies.

EOF
  read -r -p "Type 'delete' to confirm: " CONFIRM
  if [[ "$CONFIRM" != "delete" ]]; then
    echo "Aborted — nothing deleted."
    exit 0
  fi
fi

echo "Deleting cluster (10-15 min)..."
eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait

echo
echo "Verifying..."
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "WARNING: cluster still reported as present — check the CloudFormation" >&2
  echo "console for stacks that failed to delete (a stuck ENI or load balancer" >&2
  echo "left behind by a Service of type LoadBalancer is the usual cause)." >&2
  exit 1
fi

echo "Cluster deleted. Billing for the control plane, nodes and NAT has stopped."
echo
echo "Reminder: S3 buckets and RDS are still running and still billing."
