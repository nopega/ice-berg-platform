#!/usr/bin/env bash
#
# 00_create_autoscaler_irsa_and_tags_prod.sh
#
# Two prerequisites for the Cluster Autoscaler, in one script because neither
# is useful without the other:
#
#   1. the IAM role it assumes, via IRSA
#   2. the ASG tags that let it reason about a node group that has ZERO nodes
#
# WHY THE TAGS MATTER MORE THAN THEY LOOK
# -----------------------------------------
# The autoscaler decides whether to grow a node group by simulating the
# scheduler: would this Pending pod fit on a node from that group? To simulate
# it needs a template node -- labels, taints, capacity. When the group has at
# least one running node it copies that node. When the group is at ZERO, which
# is exactly the state ng-spot is designed to sit in, there is nothing to copy.
#
# It then falls back to tags on the Auto Scaling Group:
#
#   k8s.io/cluster-autoscaler/node-template/label/<key>   -> <value>
#   k8s.io/cluster-autoscaler/node-template/taint/<key>   -> <value>:<effect>
#
# Without them, the autoscaler builds a template with no labels and no taints,
# concludes that a Spark executor requiring `workload=batch` would not fit,
# and does nothing. No error, no event, nothing in its logs above debug level.
# The pod stays Pending and the Spark driver reports
#
#   Initial job has not accepted any resources; check your cluster UI to
#   ensure that workers are registered and have sufficient resources
#
# which is the same message you get from a genuinely full cluster. Confirmed
# missing on this cluster before this script existed -- eksctl's
# `withAddonPolicies.autoScaler: true` adds the *discovery* tags
# (`k8s.io/cluster-autoscaler/enabled`, `.../data-platform-prod`) and the IAM
# permissions, but not the node-template tags.
#
# WHY IRSA AND NOT THE NODE ROLE
# --------------------------------
# eksctl already granted the autoscaler permissions to the node instance role.
# That is not usable here: the IMDS hop limit on these nodes stops pods from
# reaching instance metadata, which is how Harbor's registry was found to have
# no credentials at all earlier in this build. A dedicated role bound to one
# ServiceAccount is also the pattern every other component here follows.
#
# Usage:
#   ./00_create_autoscaler_irsa_and_tags_prod.sh          # create (idempotent)
#   ./00_create_autoscaler_irsa_and_tags_prod.sh verify   # report state
#   ./00_create_autoscaler_irsa_and_tags_prod.sh delete   # remove role + policy
#
set -euo pipefail

REGION="ap-southeast-1"
CLUSTER_NAME="data-platform-prod"
K8S_NAMESPACE="kube-system"
SA_NAME="cluster-autoscaler"
ROLE_NAME="data-platform-prod-cluster-autoscaler-role"
POLICY_NAME="data-platform-prod-cluster-autoscaler"
MODE="${1:-deploy}"

# nodegroup|label=value,label=value|taintkey=taintvalue:Effect
#
# These MUST match eks-cluster.yaml. If a label or taint is changed there and
# not here, the autoscaler's model of a future node stops matching the node
# that actually appears, and it makes the wrong decision in the direction that
# is hardest to notice: refusing to scale.
NODEGROUP_TEMPLATES=(
  "ng-ondemand|workload=critical|"
  "ng-spot|workload=batch,lifecycle=spot|spot=true:NoSchedule"
)

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

asg_of() {
  aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --region "$REGION" \
    --nodegroup-name "$1" \
    --query 'nodegroup.resources.autoScalingGroups[0].name' --output text 2>/dev/null
}

# ---------------------------------------------------------------------------
if [ "$MODE" = "verify" ]; then
  echo "=== iam role ==="
  aws iam get-role --role-name "$ROLE_NAME" \
    --query 'Role.[RoleName,Arn]' --output table 2>/dev/null || echo "  not created"
  echo ""
  echo "=== service account annotation it expects ==="
  echo "  ${K8S_NAMESPACE}/${SA_NAME} -> ${ROLE_ARN}"
  echo ""
  for entry in "${NODEGROUP_TEMPLATES[@]}"; do
    IFS='|' read -r ng labels taints <<< "$entry"
    ASG="$(asg_of "$ng")"
    echo "=== ${ng} (${ASG:-not found}) ==="
    if [ -z "$ASG" ] || [ "$ASG" = "None" ]; then echo "  n/a"; continue; fi
    aws autoscaling describe-tags --region "$REGION" \
      --filters "Name=auto-scaling-group,Values=${ASG}" \
      --query 'Tags[?starts_with(Key, `k8s.io/cluster-autoscaler`)].[Key,Value]' \
      --output text 2>/dev/null | sort | sed 's/^/  /' || echo "  none"
    # The two that decide whether scale-from-zero works at all.
    HAVE="$(aws autoscaling describe-tags --region "$REGION" \
      --filters "Name=auto-scaling-group,Values=${ASG}" \
      --query 'Tags[?contains(Key, `node-template`)] | length(@)' --output text 2>/dev/null || echo 0)"
    if [ "$HAVE" = "0" ]; then
      echo "  >> NO node-template tags. Scale-from-zero will silently do nothing."
    fi
    echo ""
  done
  echo "=== current sizes ==="
  aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --region "$REGION" \
    --nodegroup-name ng-spot --query 'nodegroup.scalingConfig' --output json 2>/dev/null || true
  exit 0
fi

if [ "$MODE" = "delete" ]; then
  aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
  aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true
  echo "Removed ${ROLE_NAME} and ${POLICY_NAME} (if they existed)."
  echo ""
  echo "The ASG tags are deliberately LEFT IN PLACE. They describe the node"
  echo "groups accurately whether or not an autoscaler is installed, and"
  echo "removing them would break a reinstall in a way that looks like an"
  echo "autoscaler bug."
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
  echo "       ../03_irsa_role_prod/ creates it." >&2
  exit 1
}
echo "      ${OIDC_HOST}"

# ---------------------------------------------------------------------------
echo "[2/4] Writing policies..."
TRUST_FILE="$(mktemp)"
POLICY_FILE="$(mktemp)"
trap 'rm -f "$TRUST_FILE" "$POLICY_FILE"' EXIT

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

# The read half cannot be scoped: the autoscaler has to enumerate every ASG in
# the account before it can tell which ones carry the discovery tag, so a
# resource condition on Describe* would prevent it from finding its own groups.
#
# The write half IS scoped, by the same tag it discovers with. That is the part
# that matters -- it means this role can resize and terminate instances in the
# node groups belonging to THIS cluster and nowhere else in the account, which
# is the difference between an autoscaler and a way to delete production.
cat > "$POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DiscoverNodeGroups",
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "eks:DescribeNodegroup"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ResizeThisClustersNodeGroupsOnly",
      "Effect": "Allow",
      "Action": [
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/k8s.io/cluster-autoscaler/${CLUSTER_NAME}": "owned"
        }
      }
    }
  ]
}
EOF
echo "      writes scoped to ASGs tagged k8s.io/cluster-autoscaler/${CLUSTER_NAME}=owned"

# ---------------------------------------------------------------------------
echo "[3/4] Applying IAM..."
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
    --policy-document "file://${TRUST_FILE}" >/dev/null
  echo "      role exists, trust policy updated"
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://${TRUST_FILE}" \
    --description "Cluster Autoscaler for ${CLUSTER_NAME}" >/dev/null
  echo "      role created"
fi

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  OLD_VERSIONS="$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
    --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)"
  COUNT="$(printf '%s' "$OLD_VERSIONS" | wc -w | tr -d ' ')"
  if [ "$COUNT" -ge 4 ]; then
    OLDEST="$(printf '%s' "$OLD_VERSIONS" | tr '\t' '\n' | tail -1)"
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST" >/dev/null
  fi
  aws iam create-policy-version --policy-arn "$POLICY_ARN" \
    --policy-document "file://${POLICY_FILE}" --set-as-default >/dev/null
  echo "      policy updated"
else
  aws iam create-policy --policy-name "$POLICY_NAME" \
    --policy-document "file://${POLICY_FILE}" >/dev/null
  echo "      policy created"
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" >/dev/null
echo "      policy attached"

# ---------------------------------------------------------------------------
echo "[4/4] Tagging the Auto Scaling Groups..."
for entry in "${NODEGROUP_TEMPLATES[@]}"; do
  IFS='|' read -r ng labels taints <<< "$entry"
  ASG="$(asg_of "$ng")"
  if [ -z "$ASG" ] || [ "$ASG" = "None" ]; then
    echo "      ${ng}: node group not found, skipping"
    continue
  fi

  TAG_ARGS=""
  # PropagateAtLaunch=false on purpose. These tags describe the group for the
  # autoscaler's benefit; propagating them onto every EC2 instance adds noise
  # to the console and to cost allocation reports without adding information.
  add_tag() {
    TAG_ARGS="${TAG_ARGS} ResourceId=${ASG},ResourceType=auto-scaling-group,Key=$1,Value=$2,PropagateAtLaunch=false"
  }

  # The ${arr[@]+"${arr[@]}"} form, rather than plain "${arr[@]}".
  #
  # macOS ships Bash 3.2, where an EMPTY array is indistinguishable from an
  # unset one, so `set -u` aborts on "${TS[@]}" the moment a node group has no
  # taints -- which ng-ondemand does not. Bash 4.4 fixed that, so this script
  # ran clean on Linux and died on the machine it is actually used from:
  #
  #   line 255: TS[@]: unbound variable
  #
  # The +"..." form expands to nothing when the array is unset instead of
  # erroring, and is the portable way to iterate a possibly-empty array.
  LS=(); TS=()
  IFS=',' read -ra LS <<< "$labels"
  for l in ${LS[@]+"${LS[@]}"}; do
    [ -n "$l" ] || continue
    add_tag "k8s.io/cluster-autoscaler/node-template/label/${l%%=*}" "${l#*=}"
  done

  IFS=',' read -ra TS <<< "$taints"
  for t in ${TS[@]+"${TS[@]}"}; do
    [ -n "$t" ] || continue
    # Tag value is "<value>:<effect>" -- the key of the tag carries the taint
    # key, the value carries the rest. Getting this shape wrong produces a tag
    # the autoscaler ignores rather than an error.
    add_tag "k8s.io/cluster-autoscaler/node-template/taint/${t%%=*}" "${t#*=}"
  done

  [ -n "$TAG_ARGS" ] || { echo "      ${ng}: nothing to tag"; continue; }

  # shellcheck disable=SC2086
  aws autoscaling create-or-update-tags --region "$REGION" --tags $TAG_ARGS
  echo "      ${ng} -> ${ASG}"
  aws autoscaling describe-tags --region "$REGION" \
    --filters "Name=auto-scaling-group,Values=${ASG}" \
    --query 'Tags[?contains(Key, `node-template`)].[Key,Value]' --output text \
    | sed 's/^/        /'
done

cat <<EOF

IAM and ASG tags ready.

  ${ROLE_ARN}

Next:

  ./01_install_cluster_autoscaler_prod.sh

After it is running, the real test is not that the pod is Running -- it is that
ng-spot can go to zero and come back. Scale it down, submit a Spark job, and
watch a node appear:

  eksctl scale nodegroup --cluster ${CLUSTER_NAME} --region ${REGION} \\
    --name ng-spot --nodes 0 --nodes-min 0 --nodes-max 4
EOF
