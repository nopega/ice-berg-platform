#!/usr/bin/env bash
#
# 01_install_cluster_autoscaler_prod.sh
#
# Installs the Cluster Autoscaler, which is what makes `ng-spot desired 0` an
# actual design rather than a comment in eks-cluster.yaml.
#
# VENDOR THE CHART FIRST (once, then commit it):
#
#     helm repo add autoscaler https://kubernetes.github.io/autoscaler
#     helm repo update
#     helm pull autoscaler/cluster-autoscaler --version 9.53.0 --untar --untardir ./chart
#
# CONFIGURATION LIVES IN chart/cluster-autoscaler/values.yaml
# ------------------------------------------------------------
#     grep -n "data-platform)" chart/cluster-autoscaler/values.yaml
#
# THE VERSION RULE IS DIFFERENT HERE
# ------------------------------------
# Every other component in this repo follows "the chart decides the version".
# The autoscaler does not get that freedom: it links the upstream Kubernetes
# scheduler code and replays scheduling decisions against a simulated node. A
# mismatched minor version simulates against different rules than the cluster
# actually applies, and the result is not a crash -- it is a scale-up that
# never happens, or a scale-down that evicts something it should not have.
#
# So: cluster-autoscaler MINOR must equal the cluster's Kubernetes MINOR.
# Patch may differ. This script asserts it rather than trusting whoever ran
# `helm pull`.
#
# Usage:
#   ./01_install_cluster_autoscaler_prod.sh            # install or upgrade
#   ./01_install_cluster_autoscaler_prod.sh diff       # render, apply nothing
#   ./01_install_cluster_autoscaler_prod.sh verify     # is it actually working
#   ./01_install_cluster_autoscaler_prod.sh logs       # tail decisions
#   ./01_install_cluster_autoscaler_prod.sh status     # its own status ConfigMap
#   ./01_install_cluster_autoscaler_prod.sh uninstall
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="cluster-autoscaler"
NAMESPACE="kube-system"
CLUSTER_NAME="data-platform-prod"
REGION="ap-southeast-1"
CHART_PATH="$SCRIPT_DIR/chart/cluster-autoscaler"
SA_NAME="cluster-autoscaler"
ROLE_NAME="data-platform-prod-cluster-autoscaler-role"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need kubectl; need helm; need aws; need python3

case "$MODE" in
  logs)
    # The two lines worth reading are "Scale-up:" and "Scale-down:". Everything
    # else at v=2 is bookkeeping.
    kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" \
      --tail=100 -f
    exit 0
    ;;

  status)
    # The autoscaler publishes its own view of every node group here, including
    # why it did NOT act. This is the first thing to read when a pod is Pending
    # and nothing is happening -- more useful than the logs.
    kubectl get configmap cluster-autoscaler-status -n "$NAMESPACE" \
      -o jsonpath='{.data.status}' 2>/dev/null \
      || echo "No status ConfigMap yet. It appears a minute or so after the pod starts."
    exit 0
    ;;

  uninstall)
    helm uninstall "$RELEASE" -n "$NAMESPACE" || true
    cat <<EOF

Removed. The node groups keep whatever size they are at right now -- nothing
shrinks them back, and nothing will grow them either.

Before leaving it uninstalled, set ng-spot to a size that can actually run a
job, or every Spark submission will hang at
"Initial job has not accepted any resources".
EOF
    exit 0
    ;;

  verify)
    echo "=== release ==="
    helm status "$RELEASE" -n "$NAMESPACE" --output json 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(' ', d['name'], d['info']['status'], 'rev', d['version'])" \
      2>/dev/null || echo "  not installed"
    echo ""
    echo "=== pod ==="
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" -o wide 2>/dev/null \
      || echo "  none"
    echo ""
    echo "=== is IRSA actually projected into the pod ==="
    # Running proves nothing: the pod starts fine without credentials and then
    # fails every AWS call. These two variables are injected by the EKS webhook
    # only when the ServiceAccount carries the role annotation.
    POD="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -n "$POD" ]; then
      kubectl exec -n "$NAMESPACE" "$POD" -- env 2>/dev/null \
        | grep -E '^AWS_(ROLE_ARN|WEB_IDENTITY_TOKEN_FILE)=' \
        || echo "  NO AWS_* VARS -- the ServiceAccount annotation is missing or the pod predates it."
    else
      echo "  no pod"
    fi
    echo ""
    echo "=== did it find the node groups ==="
    # An autoscaler that adopted zero groups looks completely healthy.
    kubectl get configmap cluster-autoscaler-status -n "$NAMESPACE" \
      -o jsonpath='{.data.status}' 2>/dev/null | grep -E "Name:|Health:|ScaleUp:|ScaleDown:" \
      | sed 's/^/  /' || echo "  no status ConfigMap yet"
    echo ""
    echo "=== node-template tags (scale-from-zero depends on these) ==="
    for ng in ng-ondemand ng-spot; do
      ASG="$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --region "$REGION" \
        --nodegroup-name "$ng" --query 'nodegroup.resources.autoScalingGroups[0].name' \
        --output text 2>/dev/null || true)"
      N="$(aws autoscaling describe-tags --region "$REGION" \
        --filters "Name=auto-scaling-group,Values=${ASG}" \
        --query 'Tags[?contains(Key, `node-template`)] | length(@)' --output text 2>/dev/null || echo 0)"
      printf '  %-12s %s tag(s)%s\n' "$ng" "$N" \
        "$([ "$N" = "0" ] && echo '   <- scale-from-zero will do nothing' || true)"
    done
    echo ""
    echo "=== current sizes ==="
    for ng in ng-ondemand ng-spot; do
      printf '  %-12s ' "$ng"
      aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --region "$REGION" \
        --nodegroup-name "$ng" --query 'nodegroup.scalingConfig' --output text 2>/dev/null \
        | awk '{printf "desired=%s max=%s min=%s\n", $1, $2, $3}'
    done
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
echo "[1/5] Preflight..."

[ -d "$CHART_PATH" ] || {
  echo "ERROR: chart not found at ${CHART_PATH}" >&2
  echo "       helm repo add autoscaler https://kubernetes.github.io/autoscaler" >&2
  echo "       helm pull autoscaler/cluster-autoscaler --version 9.53.0 --untar --untardir \"$SCRIPT_DIR/chart\"" >&2
  exit 1
}

# The version assertion described in the header.
CHART_APP="$(python3 -c "
import yaml
print(yaml.safe_load(open('${CHART_PATH}/Chart.yaml')).get('appVersion',''))
" 2>/dev/null || echo "")"
CLUSTER_VER="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.version' --output text 2>/dev/null || echo "")"
[ -n "$CHART_APP" ] && [ -n "$CLUSTER_VER" ] || {
  echo "ERROR: could not read the chart appVersion or the cluster version." >&2
  exit 1
}
CHART_MINOR="$(printf '%s' "$CHART_APP"   | cut -d. -f1,2)"
CLUSTER_MINOR="$(printf '%s' "$CLUSTER_VER" | cut -d. -f1,2)"
if [ "$CHART_MINOR" != "$CLUSTER_MINOR" ]; then
  cat >&2 <<EOF
ERROR: version mismatch.

  cluster Kubernetes : ${CLUSTER_VER}
  chart appVersion   : ${CHART_APP}

  The Cluster Autoscaler links the Kubernetes scheduler and replays its
  decisions. Across minor versions it simulates different rules than the
  cluster enforces, and the symptom is a scale-up that never happens rather
  than an error. Vendor the chart whose appVersion is ${CLUSTER_MINOR}.x:

    helm search repo autoscaler/cluster-autoscaler --versions | grep ' ${CLUSTER_MINOR}\.'
EOF
  exit 1
fi
echo "      chart appVersion ${CHART_APP} matches cluster ${CLUSTER_VER}"

# IAM role must exist before the ServiceAccount references it. The annotation
# is applied either way; a missing role only shows up as an
# AssumeRoleWithWebIdentity failure inside the pod's log.
aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || {
  echo "ERROR: IAM role ${ROLE_NAME} does not exist." >&2
  echo "       Run ./00_create_autoscaler_irsa_and_tags_prod.sh first." >&2
  exit 1
}
echo "      IAM role present"

# Refuse to install a blind autoscaler. Without node-template tags on a
# scaled-to-zero group, this whole component is decorative.
MISSING_TAGS=""
for ng in ng-ondemand ng-spot; do
  ASG="$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --region "$REGION" \
    --nodegroup-name "$ng" --query 'nodegroup.resources.autoScalingGroups[0].name' \
    --output text 2>/dev/null || true)"
  [ -n "$ASG" ] && [ "$ASG" != "None" ] || continue
  N="$(aws autoscaling describe-tags --region "$REGION" \
    --filters "Name=auto-scaling-group,Values=${ASG}" \
    --query 'Tags[?contains(Key, `node-template`)] | length(@)' --output text 2>/dev/null || echo 0)"
  [ "$N" = "0" ] && MISSING_TAGS="${MISSING_TAGS} ${ng}"
done
if [ -n "$MISSING_TAGS" ]; then
  echo "ERROR: no node-template tags on:${MISSING_TAGS}" >&2
  echo "       Scale-from-zero would silently never trigger." >&2
  echo "       Run ./00_create_autoscaler_irsa_and_tags_prod.sh." >&2
  exit 1
fi
echo "      node-template tags present on both groups"

CRITICAL_NODES="$(kubectl get nodes -l workload=critical --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[ "$CRITICAL_NODES" -gt 0 ] || {
  echo "ERROR: no node labelled workload=critical; the pod is pinned there." >&2
  exit 1
}
echo "      ${CRITICAL_NODES} critical node(s)"

# ---------------------------------------------------------------------------
if [ "$MODE" = "diff" ]; then
  echo "[2/5] Rendering (nothing applied)..."
  helm template "$RELEASE" "$CHART_PATH" -n "$NAMESPACE"
  exit 0
fi

echo "[2/5] Installing..."
helm upgrade --install "$RELEASE" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  --wait --timeout 5m

echo "[3/5] Pod..."
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" -o wide

echo "[4/5] Confirming it can talk to AWS..."
POD="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" \
  -o jsonpath='{.items[0].metadata.name}')"
kubectl exec -n "$NAMESPACE" "$POD" -- env 2>/dev/null \
  | grep -qE '^AWS_ROLE_ARN=' \
  && echo "      IRSA token projected" \
  || echo "      WARNING: no AWS_ROLE_ARN in the pod -- it will fail every AWS call."

echo "[5/5] Waiting for it to adopt the node groups..."
# The status ConfigMap is written on the first successful scan. If it never
# appears, the autoscaler is running but has adopted nothing.
i=0
while [ "$i" -lt 24 ]; do
  if kubectl get configmap cluster-autoscaler-status -n "$NAMESPACE" >/dev/null 2>&1; then
    kubectl get configmap cluster-autoscaler-status -n "$NAMESPACE" \
      -o jsonpath='{.data.status}' | grep -E "Name:|Health:" | sed 's/^/      /' || true
    break
  fi
  i=$((i + 1)); sleep 5
done
[ "$i" -lt 24 ] || echo "      WARNING: no status ConfigMap after 2 minutes. Check: $0 logs"

cat <<EOF

Installed.

The pod being Running proves almost nothing. The real test is that ng-spot can
go to zero and come back on demand:

  eksctl scale nodegroup --cluster ${CLUSTER_NAME} --region ${REGION} \\
    --name ng-spot --nodes 0 --nodes-min 0 --nodes-max 4

  cd ../../../set_up_component/06_spark_prod
  kubectl delete sparkapplication platform-smoke-test -n spark --ignore-not-found
  sed 's|__IMAGE_TAG__|v1.0.2|' 06_smoke_test.yaml | kubectl apply -f -

  kubectl get nodes -l workload=batch -w      # a node should appear in ~2 min

If it does not, read this before the logs -- it says why a group was rejected:

  $0 status
EOF
