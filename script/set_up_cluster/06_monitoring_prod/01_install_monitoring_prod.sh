#!/usr/bin/env bash
#
# 01_install_monitoring_prod.sh
#
# Installs kube-prometheus-stack: the Prometheus Operator, Prometheus, Grafana,
# Alertmanager, kube-state-metrics and node-exporter.
#
# VENDOR THE CHART FIRST (once, then keep it in the repo):
#
#     helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
#     helm repo update
#     helm pull prometheus-community/kube-prometheus-stack --untar --untardir ./chart
#
# CONFIGURATION LIVES IN chart/kube-prometheus-stack/values.yaml
# ----------------------------------------------------------------
#     grep -n "data-platform)" chart/kube-prometheus-stack/values.yaml
#
# WHY THIS IS STEP 06 AND NOT THE LAST STEP
# -------------------------------------------
# The Operator installs the ServiceMonitor and PrometheusRule CRDs, and a Helm
# chart cannot create an object of a kind the API server does not know about --
# it fails with `no matches for kind "ServiceMonitor"`. The load balancer
# controller (08) and the cluster autoscaler (10) both ship ServiceMonitor
# templates, and Trino ships one too.
#
# Put monitoring last and every one of those has to be revisited with a
# `helm upgrade` after the fact. Put it here and each of them simply sets
# `serviceMonitor.enabled: true` in its own values file, which is where a
# reader would look for it.
#
# Its only hard predecessor is 05, the StorageClass: Prometheus and Grafana
# need PVCs that can bind. The Grafana Ingress is created before the load
# balancer controller exists and sits unreconciled until 08 arrives -- ordinary
# declarative behaviour, not a problem to design around.
#
# THE CRD TRAP, WHICH IS WHY `upgrade-crds` EXISTS
# --------------------------------------------------
# Helm installs CRDs on first install and then never touches them again. It
# does not upgrade them, and it does not report that it skipped them. Bumping
# the chart therefore gives you new controller code reading old CRD schemas,
# and the failure is not an error: fields the new chart sets are silently
# dropped by the API server, so a ServiceMonitor looks applied and scrapes
# nothing.
#
# Usage:
#   ./01_install_monitoring_prod.sh              # install or upgrade
#   ./01_install_monitoring_prod.sh diff         # render, apply nothing
#   ./01_install_monitoring_prod.sh verify       # is it actually working
#   ./01_install_monitoring_prod.sh targets      # what Prometheus is scraping
#   ./01_install_monitoring_prod.sh ui           # port-forward Grafana
#   ./01_install_monitoring_prod.sh upgrade-crds # apply CRDs before a chart bump
#   ./01_install_monitoring_prod.sh uninstall
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="kube-prometheus-stack"
NAMESPACE="monitoring"
CHART_PATH="$SCRIPT_DIR/chart/kube-prometheus-stack"
K8S_SECRET="grafana-admin-credentials"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need kubectl; need helm

chart_version() {
  awk '/^version:/ {print $2; exit}' "$CHART_PATH/Chart.yaml"
}

case "$MODE" in
  ui)
    echo "Grafana on http://localhost:3000"
    echo "Credentials: ../06_monitoring_prod/00_create_grafana_secret_prod.sh show"
    kubectl port-forward -n "$NAMESPACE" "svc/${RELEASE}-grafana" 3000:80
    exit 0
    ;;
  targets)
    # The question this answers is "is anything actually being scraped", which
    # `helm status` cannot tell you. A ServiceMonitor that matches no Service
    # is not an error anywhere -- it simply produces no targets.
    echo "=== ServiceMonitors the operator can see ==="
    kubectl get servicemonitors -A \
      -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name 2>/dev/null \
      || echo "  none -- the CRDs may not be installed"
    echo ""
    echo "=== Live targets, by job and health ==="
    echo "    (port-forwarding Prometheus for a moment)"
    kubectl port-forward -n "$NAMESPACE" "svc/${RELEASE}-prometheus" 9090:9090 >/dev/null 2>&1 &
    PF_PID=$!
    trap 'kill $PF_PID 2>/dev/null || true' EXIT
    sleep 3
    if command -v python3 >/dev/null 2>&1; then
      curl -sS http://localhost:9090/api/v1/targets 2>/dev/null | python3 -c "
import json,sys,collections
try:
    d = json.load(sys.stdin)
except Exception:
    print('  could not read the API -- is Prometheus running?'); raise SystemExit
c = collections.Counter()
for t in d.get('data', {}).get('activeTargets', []):
    c[(t['labels'].get('job','?'), t['health'])] += 1
if not c:
    print('  no active targets')
for (job, health), n in sorted(c.items()):
    mark = 'ok  ' if health == 'up' else 'DOWN'
    print(f'  {mark} {job:<45} {n}')
"
    else
      echo "  python3 not found; open http://localhost:9090/targets by hand"
    fi
    exit 0
    ;;
  verify)
    echo "=== Helm release ==="
    helm status "$RELEASE" -n "$NAMESPACE" 2>/dev/null | head -5 || echo "  not installed"
    echo ""
    echo "=== Pods ==="
    kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || echo "  namespace missing"
    echo ""
    echo "=== Storage ==="
    # A Pending PVC here means the StorageClass from 05 is missing or is not
    # the default. Prometheus stays Pending with it and reports nothing.
    kubectl get pvc -n "$NAMESPACE" 2>/dev/null || true
    echo ""
    echo "=== CRDs ==="
    kubectl get crd 2>/dev/null | grep -E "monitoring.coreos.com" | awk '{print "  " $1}' || echo "  none"
    echo ""
    echo "=== Ingress ==="
    # ADDRESS empty means the load balancer controller (08) has not reconciled
    # it yet. Before 08 is installed that is expected, not broken.
    kubectl get ingress -n "$NAMESPACE" 2>/dev/null || true
    exit 0
    ;;
  upgrade-crds)
    [ -d "$CHART_PATH" ] || { echo "ERROR: chart not vendored; see the header." >&2; exit 1; }
    CRD_DIR="$CHART_PATH/charts/crds/crds"
    [ -d "$CRD_DIR" ] || CRD_DIR="$CHART_PATH/crds"
    [ -d "$CRD_DIR" ] || { echo "ERROR: no CRD directory found under $CHART_PATH." >&2; exit 1; }
    echo "Applying CRDs from $CRD_DIR"
    # --server-side, because several of these exceed the 256KB annotation limit
    # that client-side apply uses to store the last-applied configuration, and
    # the error when they do names the annotation rather than the size.
    kubectl apply --server-side --force-conflicts -f "$CRD_DIR"
    exit 0
    ;;
  uninstall)
    helm uninstall "$RELEASE" -n "$NAMESPACE" || true
    echo ""
    echo "CRDs and PVCs are left behind on purpose:"
    echo "  - deleting the CRDs deletes every ServiceMonitor in the cluster,"
    echo "    including ones other charts own"
    echo "  - deleting the PVCs discards the metric history"
    echo "Remove them deliberately if that is what you want:"
    echo "  kubectl delete pvc -n ${NAMESPACE} --all"
    echo "  kubectl get crd | grep monitoring.coreos.com | awk '{print \$1}' | xargs kubectl delete crd"
    exit 0
    ;;
  deploy|diff) ;;
  *) echo "Usage: $0 [deploy|diff|verify|targets|ui|upgrade-crds|uninstall]" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
echo "[1/4] Preflight..."

[ -d "$CHART_PATH" ] || {
  echo "ERROR: chart not vendored at ${CHART_PATH}." >&2
  echo "       helm repo add prometheus-community https://prometheus-community.github.io/helm-charts" >&2
  echo "       helm repo update" >&2
  echo "       helm pull prometheus-community/kube-prometheus-stack --untar --untardir ${SCRIPT_DIR}/chart" >&2
  exit 1
}
echo "      chart version $(chart_version)"

# The StorageClass is the one hard dependency. Without a default, both PVCs
# stay Pending and the pods stay Pending behind them -- with no event that
# mentions storage until you describe the PVC.
DEFAULT_SC="$(kubectl get storageclass \
  -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
[ -n "$DEFAULT_SC" ] || {
  echo "ERROR: no default StorageClass. Run ../05_storageclass_prod first." >&2
  exit 1
}
echo "      default StorageClass: ${DEFAULT_SC}"

kubectl get secret "$K8S_SECRET" -n "$NAMESPACE" >/dev/null 2>&1 || {
  echo "ERROR: ${K8S_SECRET} not found in ${NAMESPACE}." >&2
  echo "       Run ./00_create_grafana_secret_prod.sh first, or Grafana will" >&2
  echo "       start with its default admin/prom-operator credential." >&2
  exit 1
}
echo "      Grafana credential present"

# Monitoring belongs on on-demand capacity. Prometheus holds its recent window
# in memory and its PVC is pinned to one AZ; a Spot reclamation loses the
# window and forces a reattach, exactly when node churn makes the data useful.
CRITICAL_NODES="$(kubectl get nodes -l workload=critical --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo "      workload=critical nodes: ${CRITICAL_NODES}"
[ "${CRITICAL_NODES:-0}" -ge 5 ] || {
  echo "WARNING: this stack asks for roughly 1 vCPU and 2.5Gi. The group was" >&2
  echo "         sized to 5 nodes for it; at ${CRITICAL_NODES} something will" >&2
  echo "         probably sit Pending. See scale/scale_up.sh." >&2
}

# ---------------------------------------------------------------------------
if [ "$MODE" = "diff" ]; then
  echo "[2/4] Rendering (nothing is applied)..."
  helm template "$RELEASE" "$CHART_PATH" \
    --namespace "$NAMESPACE" \
    --values "$CHART_PATH/values.yaml"
  exit 0
fi

echo "[2/4] CRDs..."
# On a first install Helm applies these itself; this is here so a re-run after
# a chart bump is correct rather than silently stale. See the header.
if helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
  "$0" upgrade-crds
else
  echo "      first install -- Helm will apply them"
fi

echo "[3/4] Installing..."
helm upgrade --install "$RELEASE" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --values "$CHART_PATH/values.yaml" \
  --wait --timeout 10m

echo "[4/4] Result"
kubectl get pods -n "$NAMESPACE"
echo ""
echo "Next:"
echo "  $0 targets    # is anything actually being scraped"
echo "  $0 ui         # Grafana on localhost:3000 without waiting for the ALB"
