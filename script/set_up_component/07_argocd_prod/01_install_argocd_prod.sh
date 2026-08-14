#!/usr/bin/env bash
#
# 01_install_argocd_prod.sh
#
# Installs Argo CD from the Helm chart vendored at ./chart/argo-cd.
#
# The chart was downloaded once with:
#     helm repo add argo https://argoproj.github.io/argo-helm
#     helm pull argo/argo-cd --version 10.3.0 --untar --untardir ./chart
#
# and is committed as part of the answer. This script does NOT re-download it:
# the copy on disk is the source of truth, so what gets applied is exactly what
# can be read in this repository, and a later run cannot pick up a different
# upstream version by surprise.
#
# CONFIGURATION LIVES IN chart/argo-cd/values.yaml
# ------------------------------------------------
# There is no separate overrides file. Every deviation from the upstream
# defaults is edited directly in that file and marked with a
# `CHANGED (data-platform)` or `ADDED (data-platform)` comment explaining why,
# so `grep -n "data-platform" chart/argo-cd/values.yaml` lists the complete set
# of decisions. Currently:
#
#   global.nodeSelector        + workload=critical  -> on-demand nodes only
#   dex.enabled                true  -> false       -> no SSO provider in scope
#   notifications.enabled      true  -> false       -> no Slack/webhook targets
#   configs.params             + server.insecure    -> port-forward over http
#   server.service.type        ClusterIP (kept)     -> no public load balancer
#   {controller,server,repoServer,applicationSet}.resources set
#
# Chart 10.3.0 ships Argo CD v3.5.0 and declares kubeVersion ">=1.25.0-0";
# the cluster runs EKS 1.34.
#
# Usage:
#   ./01_install_argocd_prod.sh            # install / upgrade
#   ./01_install_argocd_prod.sh diff       # render manifests locally, apply nothing
#   ./01_install_argocd_prod.sh verify     # report status, change nothing
#   ./01_install_argocd_prod.sh password   # print the initial admin password
#   ./01_install_argocd_prod.sh ui         # port-forward the UI to localhost:8080
#   ./01_install_argocd_prod.sh uninstall  # remove the release
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="argocd"
RELEASE_NAME="argocd"
CHART_PATH="$SCRIPT_DIR/chart/argo-cd"
CLUSTER_NAME="data-platform-prod"
REGION="ap-southeast-1"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH. On macOS: brew install $1" >&2; exit 1; }; }
need helm
need kubectl

require_chart() {
  [ -f "$CHART_PATH/Chart.yaml" ] || {
    echo "ERROR: no chart at $CHART_PATH" >&2
    echo "       Re-download it with:" >&2
    echo "         helm repo add argo https://argoproj.github.io/argo-helm" >&2
    echo "         helm pull argo/argo-cd --version 10.3.0 --untar --untardir \"$SCRIPT_DIR/chart\"" >&2
    exit 1
  }
}

case "$MODE" in
  verify)
    echo "== Chart on disk =="
    if [ -f "$CHART_PATH/Chart.yaml" ]; then
      grep -E '^(name|version|appVersion|kubeVersion):' "$CHART_PATH/Chart.yaml"
      echo ""
      echo "== Local edits to values.yaml =="
      grep -n "data-platform" "$CHART_PATH/values.yaml" || echo "  (none found - values.yaml is pristine upstream)"
    else
      echo "  (missing - see require_chart in this script)"
    fi
    echo ""
    echo "== Release =="
    helm status "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null | head -12 || echo "  (not installed yet)"
    echo ""
    echo "== Pods =="
    kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || echo "  (namespace not created yet)"
    exit 0
    ;;
  diff)
    # Renders what would be applied without touching the cluster. Useful for
    # sanity-checking an edit to values.yaml before running the install.
    require_chart
    helm template "$RELEASE_NAME" "$CHART_PATH" --namespace "$NAMESPACE"
    exit 0
    ;;
  password)
    # The chart generates this Secret on first install only. Rotate it (and
    # move to a real identity provider) before anyone else uses this cluster.
    kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret \
      -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode \
      || { echo "Secret not found - not installed yet, or it was deleted after first login." >&2; exit 1; }
    echo ""
    exit 0
    ;;
  ui)
    echo "Argo CD UI -> http://localhost:8080"
    echo "  username: admin"
    echo "  password: ./01_install_argocd_prod.sh password"
    echo "Ctrl-C to stop."
    kubectl port-forward -n "$NAMESPACE" svc/argocd-server 8080:80
    exit 0
    ;;
  uninstall)
    read -r -p "Uninstall release '$RELEASE_NAME' from namespace '$NAMESPACE'? [y/N] " ans
    [ "$ans" = "y" ] || { echo "Aborted."; exit 0; }
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
    echo "Release removed. Applications it had deployed are NOT deleted."
    exit 0
    ;;
  deploy) ;;
  *)
    echo "Unknown mode '$MODE'. Use: deploy | diff | verify | password | ui | uninstall" >&2
    exit 1
    ;;
esac

echo "== Argo CD install ==============================================="

echo "[1/4] Checking cluster access..."
kubectl get nodes >/dev/null 2>&1 \
  || { echo "ERROR: kubectl can't reach the cluster. Run: aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION" >&2; exit 1; }

echo "[2/4] Checking prerequisites..."
require_chart
# values.yaml pins these pods to workload=critical. If no such node exists the
# pods would sit Pending forever with a scheduling error that is easy to
# misread, so fail here with a clear message instead.
if [ -z "$(kubectl get nodes -l workload=critical -o name 2>/dev/null)" ]; then
  echo "ERROR: no node carries the label workload=critical." >&2
  echo "       The ng-ondemand node group sets it. Inspect with:" >&2
  echo "         kubectl get nodes --show-labels" >&2
  exit 1
fi
echo "      chart: $(grep -E '^version:' "$CHART_PATH/Chart.yaml") / $(grep -E '^appVersion:' "$CHART_PATH/Chart.yaml")"

echo "[3/4] helm upgrade --install from $CHART_PATH ..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  --wait --timeout 10m

echo "[4/4] Pods:"
kubectl get pods -n "$NAMESPACE" -o wide

cat <<EOF

Argo CD is up.

  ./01_install_argocd_prod.sh password    # initial admin password
  ./01_install_argocd_prod.sh ui          # port-forward to http://localhost:8080

The UI is ClusterIP-only on purpose - no public load balancer in front of the
component that holds admin rights over the cluster.
EOF
