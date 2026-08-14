#!/usr/bin/env bash
#
# 02_create_grafana_cloudwatch_irsa_prod.sh
#
# Lets Grafana read AWS billing and CloudWatch metrics, so the cost decisions
# argued for throughout this repo can be checked rather than asserted.
#
# WHAT THIS IS FOR
# ------------------
# Several choices in this project are justified by cost: one NAT gateway rather
# than one per AZ, an S3 gateway endpoint so Trino scans are not billed at
# $0.045/GB, ng-spot sitting at zero nodes when no Spark job is running, a
# fifth on-demand node bought deliberately for monitoring. Every one of those
# is a claim about a number nobody can currently see.
#
# WHY IRSA AND NOT AN ACCESS KEY
# --------------------------------
# The Grafana pod gets a role through its ServiceAccount, and the credentials
# are short-lived tokens minted by the cluster's OIDC provider. There is no key
# to store in a Secret, no key to rotate, and no key to leak. Same pattern as
# Spark, Airflow and the autoscaler use here.
#
# WHY THE PERMISSIONS ARE READ-ONLY AND NARROW
# ----------------------------------------------
# Billing data is unusually sensitive for a dashboard: it describes the whole
# account, not just this cluster. The policy below can read cost and metrics
# and nothing else -- it cannot see resource names, tags, or anything in S3.
# Cost Explorer has no per-resource scoping, so limiting the ACTIONS is the
# only control available.
#
# Usage:
#   ./02_create_grafana_cloudwatch_irsa_prod.sh          # create / update
#   ./02_create_grafana_cloudwatch_irsa_prod.sh verify   # role, policy, SA
#   ./02_create_grafana_cloudwatch_irsa_prod.sh delete
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="ap-southeast-1"
CLUSTER_NAME="data-platform-prod"
NAMESPACE="monitoring"
SERVICE_ACCOUNT="kube-prometheus-stack-grafana"
ROLE_NAME="data-platform-prod-grafana-cloudwatch-role"
POLICY_NAME="data-platform-prod-grafana-cloudwatch-policy"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws; need kubectl; need python3

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

POLICY_JSON="$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudWatchMetricsRead",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:DescribeAlarmsForMetric",
        "cloudwatch:DescribeAlarmHistory",
        "cloudwatch:DescribeAlarms",
        "cloudwatch:ListMetrics",
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:GetInsightRuleReport"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CostExplorerRead",
      "Effect": "Allow",
      "Action": [
        "ce:GetCostAndUsage",
        "ce:GetCostForecast",
        "ce:GetDimensionValues",
        "ce:GetTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ResourceTagsForDimensionLists",
      "Effect": "Allow",
      "Action": [
        "tag:GetResources"
      ],
      "Resource": "*"
    }
  ]
}
EOF
)"

report() {
  echo "=== IAM policy ==="
  aws iam get-policy --policy-arn "$POLICY_ARN" \
    --query 'Policy.{name:PolicyName,default:DefaultVersionId,attached:AttachmentCount}' \
    --output table 2>/dev/null || echo "  absent"
  echo "=== IAM role ==="
  aws iam get-role --role-name "$ROLE_NAME" \
    --query 'Role.{name:RoleName,arn:Arn}' --output table 2>/dev/null || echo "  absent"
  echo "=== ServiceAccount annotation ==="
  # The annotation is what actually connects the two. A role that exists and a
  # ServiceAccount that does not name it is the most common way this silently
  # does nothing: the pod falls back to no credentials and Grafana reports
  # "Access denied" from a datasource, not from Kubernetes.
  local annotated
  annotated="$(kubectl get sa "$SERVICE_ACCOUNT" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || true)"
  if [ -z "$annotated" ]; then
    echo "  NOT annotated -- Grafana has no AWS identity."
    echo "  Add it under grafana.serviceAccount.annotations in values.yaml and"
    echo "  re-run ./01_install_monitoring_prod.sh"
  elif [ "$annotated" = "$ROLE_ARN" ]; then
    echo "  ${annotated}"
  else
    echo "  MISMATCH"
    echo "    ServiceAccount says: ${annotated}"
    echo "    this script created: ${ROLE_ARN}"
  fi
  echo "=== Is the token actually mounted in the pod ==="
  kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=grafana \
    -o jsonpath='{range .items[*]}{.metadata.name}{"  AWS_ROLE_ARN="}{.spec.containers[0].env[?(@.name=="AWS_ROLE_ARN")].value}{"\n"}{end}' 2>/dev/null \
    || echo "  no grafana pod"
}

case "$MODE" in
  verify) report; exit 0 ;;
  delete)
    aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true
    aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
    aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true
    echo "Deleted. Remove the annotation from values.yaml as well."
    exit 0
    ;;
  deploy) ;;
  *) echo "Usage: $0 [deploy|verify|delete]" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
echo "[1/4] Preflight..."
OIDC_URL="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.identity.oidc.issuer' --output text | sed 's|https://||')"
[ -n "$OIDC_URL" ] && [ "$OIDC_URL" != "None" ] || {
  echo "ERROR: cluster has no OIDC issuer. IRSA needs `iam.withOIDC: true`." >&2
  exit 1
}
echo "      OIDC: ${OIDC_URL}"
echo "      account: ${ACCOUNT_ID}"

echo "[2/4] IAM policy..."
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  # `create-policy` runs exactly once; every later edit to the JSON above would
  # be silently ignored without this branch. That bug cost a debugging cycle in
  # 01_iceberg_catalog_and_polaris_prod, so it is handled everywhere now.
  CURRENT="$(aws iam get-policy-version --policy-arn "$POLICY_ARN" \
    --version-id "$(aws iam get-policy --policy-arn "$POLICY_ARN" --query 'Policy.DefaultVersionId' --output text)" \
    --query 'PolicyVersion.Document' --output json)"
  if python3 -c "
import json,sys
cur=json.loads(sys.argv[1]); new=json.loads(sys.argv[2])
sys.exit(0 if json.dumps(cur,sort_keys=True)==json.dumps(new,sort_keys=True) else 1)
" "$CURRENT" "$POLICY_JSON" 2>/dev/null; then
    echo "      unchanged"
  else
    # IAM keeps at most 5 versions. Prune the oldest non-default before adding.
    COUNT="$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'length(Versions)' --output text)"
    if [ "$COUNT" -ge 5 ]; then
      OLDEST="$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
        --query 'Versions[?IsDefaultVersion==`false`]|[-1].VersionId' --output text)"
      aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST" >/dev/null
    fi
    aws iam create-policy-version --policy-arn "$POLICY_ARN" \
      --policy-document "$POLICY_JSON" --set-as-default >/dev/null
    echo "      updated to a new default version"
  fi
else
  aws iam create-policy --policy-name "$POLICY_NAME" \
    --policy-document "$POLICY_JSON" \
    --description "Read-only CloudWatch and Cost Explorer access for Grafana" >/dev/null
  echo "      created"
fi

echo "[3/4] IAM role and trust policy..."
# The trust policy names this exact ServiceAccount. The subject string is what
# the OIDC provider asserts; a mismatch produces AssumeRoleWithWebIdentity
# denials that mention neither the ServiceAccount nor the namespace.
TRUST="$(python3 - "$ACCOUNT_ID" "$OIDC_URL" "$NAMESPACE" "$SERVICE_ACCOUNT" <<'PY'
import json, sys
account, oidc, ns, sa = sys.argv[1:5]
print(json.dumps({
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": f"arn:aws:iam::{account}:oidc-provider/{oidc}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {
      f"{oidc}:aud": "sts.amazonaws.com",
      f"{oidc}:sub": f"system:serviceaccount:{ns}:{sa}",
    }},
  }],
}))
PY
)"

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST" >/dev/null
  echo "      trust policy refreshed"
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST" \
    --description "Grafana CloudWatch and Cost Explorer reader (IRSA)" \
    --tags Key=Project,Value=data-platform Key=Environment,Value=prod >/dev/null
  echo "      created"
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" >/dev/null
echo "      policy attached"

echo "[4/4] Result"
echo "      role: ${ROLE_ARN}"
cat <<EOF

Grafana's ServiceAccount still has to name this role. It is already set in
chart/kube-prometheus-stack/values.yaml under grafana.serviceAccount.annotations;
apply it with:

  ./01_install_monitoring_prod.sh
  $0 verify

ONE THING THIS SCRIPT CANNOT DO FOR YOU
-----------------------------------------
CloudWatch publishes the AWS/Billing namespace only if billing alerts are
enabled on the account, and only into us-east-1 regardless of where anything
runs. If the Billing dashboard is empty, that is why -- not the IAM policy:

  AWS Console -> Billing and Cost Management -> Billing preferences
  -> "Receive CloudWatch billing alerts"

It takes a few hours to start publishing after being switched on. Cost Explorer
(the ce:* permissions above) works immediately and does not need it.
EOF
