#!/usr/bin/env bash
#
# 04_install_polaris_prod.sh
#
# Installs Apache Polaris from the Helm chart vendored at ./chart/polaris.
#
# The chart was downloaded once with:
#     helm repo add polaris https://downloads.apache.org/polaris/helm-chart
#     helm pull polaris/polaris --version 1.5.0 --untar --untardir ./chart
#
# and is committed as part of the answer. This script does NOT re-download it:
# the copy on disk is the source of truth, so what gets applied is exactly what
# can be read in this repository.
#
# CONFIGURATION LIVES IN chart/polaris/values.yaml
# ------------------------------------------------
# There is no separate overrides file. Every deviation from the upstream
# defaults is edited in place and marked with a `CHANGED (data-platform)` /
# `KEPT ... DELIBERATELY (data-platform)` comment explaining why, so
#     grep -n "data-platform" chart/polaris/values.yaml
# lists the complete set of decisions. Currently:
#
#   persistence.type        in-memory -> relational-jdbc   (survive a restart)
#   persistence...secret    ""        -> polaris-persistence
#   serviceAccount.create   true      -> false             (reuse the IRSA SA)
#   serviceAccount.name     ""        -> data-platform-workload
#   realmContext.realms     POLARIS   -> data-platform-prod
#   nodeSelector            {}        -> workload=critical (no spot nodes)
#   resources               {}        -> requests/limits set
#   storage.secret          kept empty (IRSA instead of static AWS keys)
#
# Usage:
#   ./04_install_polaris_prod.sh            # install / upgrade
#   ./04_install_polaris_prod.sh diff       # render manifests locally, apply nothing
#   ./04_install_polaris_prod.sh verify     # report status, change nothing
#   ./04_install_polaris_prod.sh logs       # tail the Polaris pod logs
#   ./04_install_polaris_prod.sh smoke      # curl the catalog API from inside the cluster
#   ./04_install_polaris_prod.sh uninstall  # remove the release
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="data-platform"
RELEASE_NAME="polaris"
CHART_PATH="$SCRIPT_DIR/chart/polaris"
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
    echo "         helm repo add polaris https://downloads.apache.org/polaris/helm-chart" >&2
    echo "         helm pull polaris/polaris --version 1.5.0 --untar --untardir \"$SCRIPT_DIR/chart\"" >&2
    exit 1
  }
}

case "$MODE" in
  verify)
    echo "== Chart on disk =="
    if [ -f "$CHART_PATH/Chart.yaml" ]; then
      grep -E '^(name|version|appVersion):' "$CHART_PATH/Chart.yaml"
      echo ""
      echo "== Local edits to values.yaml =="
      grep -c "data-platform" "$CHART_PATH/values.yaml" | xargs -I{} echo "  {} annotated lines (grep -n 'data-platform' chart/polaris/values.yaml)"
    else
      echo "  (missing)"
    fi
    echo ""
    echo "== Prerequisites =="
    kubectl get serviceaccount data-platform-workload -n "$NAMESPACE" >/dev/null 2>&1 \
      && echo "  ServiceAccount data-platform-workload: present" || echo "  ServiceAccount data-platform-workload: MISSING (run 01_)"
    kubectl get secret polaris-persistence -n "$NAMESPACE" >/dev/null 2>&1 \
      && echo "  Secret polaris-persistence: present" || echo "  Secret polaris-persistence: MISSING (run 02_)"
    aws secretsmanager describe-secret --secret-id data-platform-prod-polaris-root-credentials --region "$REGION" >/dev/null 2>&1 \
      && echo "  Realm bootstrapped: yes" || echo "  Realm bootstrapped: NO (run 03_)"
    echo ""
    echo "== Release =="
    helm status "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null | head -12 || echo "  (not installed yet)"
    echo ""
    echo "== Pods =="
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=polaris -o wide 2>/dev/null || echo "  (none)"
    exit 0
    ;;
  diff)
    require_chart
    helm template "$RELEASE_NAME" "$CHART_PATH" --namespace "$NAMESPACE"
    exit 0
    ;;
  logs)
    kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/name=polaris --tail=100 -f
    exit 0
    ;;
  smoke)
    # /v1/config is the Iceberg REST spec's own discovery endpoint -- if this
    # answers, the catalog is genuinely serving the API and not merely running.
    echo "GET /api/catalog/v1/config from inside the cluster:"
    kubectl run polaris-smoke --rm -i --restart=Never --image=curlimages/curl -n "$NAMESPACE" -- \
      curl -s -o /dev/stdout -w '\nHTTP %{http_code}\n' \
      "http://${RELEASE_NAME}.${NAMESPACE}.svc.cluster.local:8181/api/catalog/v1/config?warehouse=data_platform"
    exit 0
    ;;
  uninstall)
    read -r -p "Uninstall release '$RELEASE_NAME' from namespace '$NAMESPACE'? [y/N] " ans
    [ "$ans" = "y" ] || { echo "Aborted."; exit 0; }
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
    echo "Release removed. The catalog DATA is untouched -- it lives in the"
    echo "iceberg_catalog database on RDS, not in the pod."
    exit 0
    ;;
  deploy) ;;
  *)
    echo "Unknown mode '$MODE'. Use: deploy | diff | verify | logs | smoke | uninstall" >&2
    exit 1
    ;;
esac

echo "== Polaris install ==============================================="

echo "[1/4] Checking cluster access..."
kubectl get nodes >/dev/null 2>&1 \
  || { echo "ERROR: kubectl can't reach the cluster. Run: aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION" >&2; exit 1; }

echo "[2/4] Checking prerequisites..."
require_chart
kubectl get serviceaccount data-platform-workload -n "$NAMESPACE" >/dev/null 2>&1 \
  || { echo "ERROR: ServiceAccount 'data-platform-workload' missing. Run 01_create_namespace_and_sa_prod.sh first." >&2; exit 1; }
kubectl get secret polaris-persistence -n "$NAMESPACE" >/dev/null 2>&1 \
  || { echo "ERROR: Secret 'polaris-persistence' missing. Run 02_create_persistence_secret_prod.sh first." >&2; exit 1; }
# Without a bootstrapped realm the server starts and then fails every request,
# which looks like a networking problem rather than a missing schema.
aws secretsmanager describe-secret --secret-id data-platform-prod-polaris-root-credentials --region "$REGION" >/dev/null 2>&1 \
  || { echo "ERROR: realm not bootstrapped. Run 03_bootstrap_polaris_realm_prod.sh first." >&2; exit 1; }
# values.yaml pins the pod to workload=critical; without such a node it would
# sit Pending with a message that is easy to misread.
[ -n "$(kubectl get nodes -l workload=critical -o name 2>/dev/null)" ] \
  || { echo "ERROR: no node labelled workload=critical (the ng-ondemand group sets it)." >&2; exit 1; }
echo "      chart: $(grep -E '^version:' "$CHART_PATH/Chart.yaml") / $(grep -E '^appVersion:' "$CHART_PATH/Chart.yaml")"

echo "[3/4] helm upgrade --install from $CHART_PATH ..."
helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  --wait --timeout 5m

echo "[4/4] Pods:"
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=polaris -o wide

cat <<EOF

Polaris is up.

  ./04_install_polaris_prod.sh smoke    # hit the Iceberg REST config endpoint
  ./04_install_polaris_prod.sh logs     # tail logs

Next: register the catalog (name, S3 base location, storage role ARN) against
the management API -- that is what points Polaris at
s3://data-store-prod-warehouse and completes the credential-vending chain.
EOF
