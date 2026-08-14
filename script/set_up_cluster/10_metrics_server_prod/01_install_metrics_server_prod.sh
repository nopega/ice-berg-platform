#!/usr/bin/env bash
#
# 01_install_metrics_server_prod.sh
#
# Installs metrics-server, without which every HorizontalPodAutoscaler on this
# cluster is decorative.
#
# WHY THIS EXISTS AS ITS OWN STEP
# ---------------------------------
# EKS does not ship metrics-server. The cluster works perfectly well without
# it right up until something asks for pod CPU or memory -- and then it does
# not fail, it goes quiet.
#
# Trino's worker HPA was created on the day Trino was installed and never
# scaled once. `kubectl get hpa` reported `<unknown>/50%`. The HPA controller
# logged FailedGetResourceMetric every 15 seconds, 5918 times in 24 hours, into
# events nobody reads. A Deployment parked at its minimum replicas looks
# identical to a Deployment with no reason to scale, so nothing looked wrong.
#
# It surfaced only when Argo CD marked the Trino Application Degraded, which is
# a fair argument for having installed Argo CD.
#
# WHAT IT MEANT FOR THE DESIGN
# ------------------------------
# The take-home says Team A sends roughly 100 queries at 10am while Team B
# needs fast answers all day. The answer to that is two-part: resource groups
# stop the teams starving each other, and the worker HPA adds capacity for the
# burst. The first half was working. The second half had never run.
#
# WHY AN EKS MANAGED ADDON AND NOT A HELM CHART
# -----------------------------------------------
# Every other Kubernetes controller here is a vendored Helm chart, deliberately
# -- what gets applied is what can be read in this repository. metrics-server
# is the exception for the same reason vpc-cni, coredns, kube-proxy and the EBS
# CSI driver are: it is cluster plumbing that AWS patches on its own schedule,
# with no configuration this platform has an opinion about. Vendoring it would
# mean owning its version forever in exchange for nothing.
#
# Usage:
#   ./01_install_metrics_server_prod.sh          # install (idempotent)
#   ./01_install_metrics_server_prod.sh verify   # is it actually serving
#   ./01_install_metrics_server_prod.sh delete
#
set -euo pipefail

REGION="ap-southeast-1"
CLUSTER_NAME="data-platform-prod"
ADDON="metrics-server"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws; need kubectl

report() {
  echo "=== EKS addon ==="
  aws eks describe-addon --region "$REGION" --cluster-name "$CLUSTER_NAME" \
    --addon-name "$ADDON" \
    --query 'addon.{name:addonName,version:addonVersion,status:status}' \
    --output table 2>/dev/null || echo "  not installed"
  echo ""
  echo "=== Metrics API ==="
  # The addon reporting ACTIVE only means the pod started. This is the check
  # that matters: the aggregated API has to be registered and answering, and
  # that takes a further 30-60 seconds after the pod is Ready.
  if kubectl top nodes >/dev/null 2>&1; then
    kubectl top nodes
  else
    echo "  not answering yet -- give it a minute, then re-run"
  fi
  echo ""
  echo "=== HorizontalPodAutoscalers ==="
  # <unknown> in the TARGETS column is the symptom this whole step exists for.
  kubectl get hpa -A 2>/dev/null || echo "  none"
}

case "$MODE" in
  verify) report; exit 0 ;;
  delete)
    aws eks delete-addon --region "$REGION" --cluster-name "$CLUSTER_NAME" \
      --addon-name "$ADDON" >/dev/null
    echo "Deleting. Every HPA will go back to <unknown> and stop scaling."
    exit 0
    ;;
  deploy) ;;
  *) echo "Usage: $0 [deploy|verify|delete]" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
echo "[1/3] Preflight..."
aws eks describe-cluster --region "$REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1 || {
  echo "ERROR: cluster ${CLUSTER_NAME} not found in ${REGION}." >&2
  exit 1
}
echo "      cluster ${CLUSTER_NAME}"

echo "[2/3] Addon..."
if aws eks describe-addon --region "$REGION" --cluster-name "$CLUSTER_NAME" \
     --addon-name "$ADDON" >/dev/null 2>&1; then
  echo "      already installed"
else
  aws eks create-addon --region "$REGION" --cluster-name "$CLUSTER_NAME" \
    --addon-name "$ADDON" \
    --resolve-conflicts OVERWRITE \
    --tags Project=data-platform,Environment=prod >/dev/null
  echo "      created, waiting for ACTIVE..."
  aws eks wait addon-active --region "$REGION" --cluster-name "$CLUSTER_NAME" \
    --addon-name "$ADDON" 2>/dev/null || true
fi

echo "[3/3] Result"
# Poll rather than sleep once: the addon reaches ACTIVE before the aggregated
# API layer starts answering, and reporting failure in that window would send
# someone debugging a thing that is merely still starting.
for i in $(seq 1 12); do
  if kubectl top nodes >/dev/null 2>&1; then
    echo "      metrics API answering"
    break
  fi
  [ "$i" = "12" ] && echo "      still not answering after 60s -- check: kubectl -n kube-system logs deploy/metrics-server"
  sleep 5
done

echo ""
report

cat <<'EOF'

An HPA does not recover instantly. The controller re-reads metrics on its own
cycle, so give it about a minute, then confirm the TARGETS column has real
numbers instead of <unknown>:

  kubectl get hpa -A
  kubectl describe hpa trino-worker -n data-platform | grep -A4 Conditions

ScalingActive should read True. While it says False with
FailedGetResourceMetric, the HPA is not scaling anything.
EOF
