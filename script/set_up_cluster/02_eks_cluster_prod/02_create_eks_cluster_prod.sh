#!/usr/bin/env bash
#
# 02_create_eks_cluster_prod.sh  (PROD environment)
#
# Creates the EKS cluster defined in eks-cluster.yaml (same directory — single
# source of truth, this script never embeds a copy of the config).
#
# COST WARNING: an EKS cluster is NOT free-tier eligible. The control plane
# alone is $0.10/hr (~$73/month) from the moment it exists, whether or not
# anything is running on it, plus EC2 node cost and a NAT gateway (~$32/mo).
# Run ./99_delete_eks_cluster_prod.sh when you are done to stop the meter.
#
# Safe to re-run: if the cluster already exists it reports and exits without
# changing anything.
#
# Usage:
#   ./02_create_eks_cluster_prod.sh          # create the cluster
#   ./02_create_eks_cluster_prod.sh verify   # report current state only
#   ./02_create_eks_cluster_prod.sh -y       # skip the confirmation prompt
#
# Requires: AWS CLI v2 (configured), eksctl, kubectl.
# Comes after: 00_aws_cli_setup/, 01_s3_bucket_setup/
# Comes before: 03_irsa_role_prod/ (needs the OIDC provider this script creates)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_CONFIG="${SCRIPT_DIR}/eks-cluster.yaml"

CLUSTER_NAME="data-platform-prod"
AWS_REGION="ap-southeast-1"

if [[ ! -f "$CLUSTER_CONFIG" ]]; then
  echo "ERROR: missing cluster config: ${CLUSTER_CONFIG}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Preflight — check tooling before doing anything slow or expensive
# ---------------------------------------------------------------------------

for tool in aws eksctl kubectl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: '${tool}' is not installed." >&2
    case "$tool" in
      eksctl)  echo "  Install: see INSTALL_KUBECTL.md in this folder" >&2 ;;
      kubectl) echo "  Install: see INSTALL_KUBECTL.md in this folder" >&2 ;;
      aws)     echo "  Install: see ../00_aws_cli_setup/00_setup_aws_cli.sh" >&2 ;;
    esac
    exit 1
  fi
done

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

cluster_exists() {
  aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1
}

report() {
  echo "=== EKS cluster: ${CLUSTER_NAME} (${AWS_REGION})"
  if cluster_exists; then
    echo "  status:      $(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.status' --output text)"
    echo "  version:     $(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.version' --output text)"
    echo "  OIDC issuer: $(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.identity.oidc.issuer' --output text)"
    echo "  nodegroups:  $(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'nodegroups' --output text)"
  else
    echo "  exists: no"
  fi
}

if [[ "${1:-}" == "verify" ]]; then
  report
  exit 0
fi

echo "Account: ${ACCOUNT_ID}"
echo "Cluster: ${CLUSTER_NAME} (${AWS_REGION})"
echo "Config:  ${CLUSTER_CONFIG}"
echo

if cluster_exists; then
  NODEGROUP_COUNT="$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'length(nodegroups)' --output text)"
  if [[ "$NODEGROUP_COUNT" == "0" ]]; then
    cat <<EOF
Cluster already exists, but it has NO node groups — most likely a previous
node group creation failed and was rolled back (the "Free Plan instance
type" issue described in the cost note below is the usual cause).

The control plane is untouched, so there is no need to delete anything or
start over. Add just the missing node groups:

  eksctl create nodegroup -f ${CLUSTER_CONFIG}

EOF
    exit 0
  fi
  echo "Cluster already exists — nothing to do."
  report
  exit 0
fi

# ---------------------------------------------------------------------------
# Cost confirmation
# ---------------------------------------------------------------------------

if [[ "${1:-}" != "-y" ]]; then
  cat <<EOF
About to create an EKS cluster. Ongoing cost while it exists, roughly:

  Control plane      \$0.10/hr        ~\$73/month   (no free tier)
  1x m5.large On-Dem ~\$0.12/hr       ~\$88/month
  1x m5.large Spot   ~\$0.04/hr       ~\$29/month   (varies with spot price)
  NAT gateway        ~\$0.045/hr      ~\$33/month   + data processing
  ------------------------------------------------------------------
  Total              ~\$0.31/hr       ~\$223/month

  Roughly \$45 if left running continuously for 6 days.

Creation takes roughly 15-20 minutes. Delete it with
./99_delete_eks_cluster_prod.sh as soon as you are finished.

NOTE — AWS "Free Plan" accounts: new accounts default to a Free Plan that
only permits free-tier-eligible instance types (t2.micro/t3.micro). The
m5.large instances above are NOT free-tier eligible, so node group creation
will fail with "not eligible for Free Tier" on a Free Plan account, even
though the control plane itself creates fine. If that happens, upgrade to
the Paid plan in the Billing console (any remaining credit still applies —
this just removes the instance-type restriction), then re-run this script;
it will detect the existing cluster and offer to create just the missing
node groups.

EOF
  read -r -p "Type 'yes' to continue: " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted — nothing created."
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------
# eksctl provisions the VPC, subnets, control plane, node groups, add-ons and
# the IAM OIDC provider as a set of CloudFormation stacks, and writes the
# kubeconfig entry when it finishes.

echo "Creating cluster (15-20 min)..."
CREATE_LOG="$(mktemp -t eksctl-create-cluster)"
set +e
eksctl create cluster -f "$CLUSTER_CONFIG" 2>&1 | tee "$CREATE_LOG"
CREATE_STATUS="${PIPESTATUS[0]}"
set -e

if [[ "$CREATE_STATUS" -ne 0 ]]; then
  if grep -q "not eligible for Free Tier" "$CREATE_LOG"; then
    cat <<EOF

--------------------------------------------------------------------------
DIAGNOSIS: node group creation failed because this account is on the AWS
"Free Plan", which only allows free-tier-eligible instance types. m5.large
is not eligible, so EC2 rejected the launch.

The control plane itself creates fine and is unaffected by this failure
(check with: ./02_create_eks_cluster_prod.sh verify).

Fix:
  1. Upgrade to the Paid plan: https://console.aws.amazon.com/billing/home#/account
     (any remaining promotional credit still applies — this only removes
     the instance-type restriction)
  2. Delete the failed (rolled-back) node group stacks:
       aws cloudformation update-termination-protection --region ${AWS_REGION} \\
         --stack-name eksctl-${CLUSTER_NAME}-nodegroup-ng-ondemand --no-enable-termination-protection
       aws cloudformation update-termination-protection --region ${AWS_REGION} \\
         --stack-name eksctl-${CLUSTER_NAME}-nodegroup-ng-spot --no-enable-termination-protection
       aws cloudformation delete-stack --region ${AWS_REGION} --stack-name eksctl-${CLUSTER_NAME}-nodegroup-ng-ondemand
       aws cloudformation delete-stack --region ${AWS_REGION} --stack-name eksctl-${CLUSTER_NAME}-nodegroup-ng-spot
  3. Re-run this script — it will detect the cluster already exists with no
     node groups and give you the exact command to add them back.
--------------------------------------------------------------------------
EOF
  else
    echo
    echo "eksctl create cluster failed — full output saved to ${CREATE_LOG}" >&2
  fi
  exit 1
fi
rm -f "$CREATE_LOG"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

echo
echo "--- Cluster state ---"
report

echo
echo "--- Nodes ---"
kubectl get nodes -o wide

echo
cat <<EOF
Next steps:

  1. IRSA role (now possible — the OIDC provider exists):
       cd ../03_iam_role_and_irsa_role/03_irsa_role_prod && ./03_create_irsa_role_prod.sh

  2. When finished for the day, stop the meter:
       ./99_delete_eks_cluster_prod.sh
EOF
