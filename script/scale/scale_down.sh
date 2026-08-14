#!/usr/bin/env bash
#
# scale_down.sh — park the platform overnight without destroying it
#
# Scales both EKS node groups to zero and stops the RDS instance. Everything
# that defines the platform survives: the EKS control plane, the VPC, S3, IAM,
# Helm releases, PersistentVolumeClaims and the Secrets Manager entries. Pods
# simply have nowhere to run until scale_up.sh puts nodes back, at which point
# Kubernetes reschedules them on its own -- nothing needs reinstalling.
#
# WHAT THIS DOES NOT STOP, AND WHY
# --------------------------------
#   EKS control plane  ~$0.10/hr (~$2.40/day). AWS offers no "stop"; the only
#                      way to avoid it is deleting the cluster, which means
#                      rebuilding it (and re-running the IRSA trust policy,
#                      since a new cluster gets a new OIDC issuer).
#   NAT Gateway        ~$0.045/hr (~$1.08/day). Deleting it cuts internet
#                      egress for every private-subnet node, so image pulls
#                      and AWS API calls stop working until it is recreated.
#
# So there is a hard floor of roughly $3.50/day while the cluster exists. This
# script removes the part above that floor -- about $0.24/hr of EC2 -- which is
# the majority of the hourly burn.
#
# Usage:
#   ./scale_down.sh          # scale to zero + stop RDS
#   ./scale_down.sh status   # show current state, change nothing
#
set -euo pipefail

CLUSTER_NAME="data-platform-prod"
REGION="ap-southeast-1"
NODEGROUPS=("ng-ondemand" "ng-spot")
DB_INSTANCE_ID="data-platform-prod-db"
MODE="${1:-down}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws
need eksctl

show_status() {
  echo "=== Node groups ==="
  for ng in "${NODEGROUPS[@]}"; do
    aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$REGION" \
      --query 'nodegroup.{name:nodegroupName,status:status,min:scalingConfig.minSize,desired:scalingConfig.desiredSize,max:scalingConfig.maxSize}' \
      --output table 2>/dev/null || echo "  $ng: not found"
  done
  echo "=== Nodes ==="
  kubectl get nodes 2>/dev/null || echo "  (no nodes, or kubectl can't reach the cluster)"
  echo "=== RDS ==="
  aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" --region "$REGION" \
    --query 'DBInstances[0].{id:DBInstanceIdentifier,status:DBInstanceStatus,engine:EngineVersion}' \
    --output table 2>/dev/null || echo "  not found"
}

if [ "$MODE" = "status" ]; then
  show_status
  exit 0
fi

echo "== Scaling down =================================================="

for ng in "${NODEGROUPS[@]}"; do
  if ! aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$REGION" >/dev/null 2>&1; then
    echo "node group $ng: not found, skipping"
    continue
  fi
  # --nodes-min 0 is required as well as --nodes 0: a managed node group
  # refuses a desired size below its configured minimum, and ng-ondemand is
  # created with minSize 1.
  echo "node group $ng: scaling to 0..."
  eksctl scale nodegroup \
    --cluster "$CLUSTER_NAME" \
    --region "$REGION" \
    --name "$ng" \
    --nodes 0 \
    --nodes-min 0
done

echo ""
DB_STATUS="$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" --region "$REGION" \
  --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "missing")"
case "$DB_STATUS" in
  available)
    echo "RDS $DB_INSTANCE_ID: stopping..."
    aws rds stop-db-instance --db-instance-identifier "$DB_INSTANCE_ID" --region "$REGION" >/dev/null
    echo "  stop requested (takes a few minutes to reach 'stopped')"
    ;;
  stopped|stopping)
    echo "RDS $DB_INSTANCE_ID: already $DB_STATUS"
    ;;
  missing)
    echo "RDS $DB_INSTANCE_ID: not found, skipping"
    ;;
  *)
    echo "RDS $DB_INSTANCE_ID: status is '$DB_STATUS' -- not stopping it in this state." >&2
    ;;
esac

cat <<EOF

Done. Still billing while the cluster exists:
  EKS control plane   ~\$2.40/day  (cannot be stopped)
  NAT Gateway         ~\$1.08/day  (deleting it breaks node internet access)
  EBS + S3 storage    small, and RDS storage still bills while stopped

Bring it back with:
  ./scale_up.sh

NOTE: RDS restarts itself automatically 7 days after being stopped -- that is
an AWS behaviour, not something this script controls.
EOF
