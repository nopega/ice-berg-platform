#!/usr/bin/env bash
#
# 03_install_trino_prod.sh
#
# Installs Trino from the Helm chart vendored at ./chart/trino.
#
# The chart was downloaded once with:
#     helm repo add trino https://trinodb.github.io/charts
#     helm pull trino/trino --version 1.42.2 --untar --untardir ./chart
#
# Chart 1.42.2 ships appVersion 480. Note that Trino's latest release is 483 --
# the chart lags a few versions behind. We run 480 rather than overriding
# image.tag, because 480 is the version the chart's own templates and config
# properties were tested against, and this platform's whole version policy is
# "pick pairings that are known to work together" rather than "newest of
# everything" (the same reasoning that put Spark at 4.0.4 instead of 4.2.0).
#
# CONFIGURATION LIVES IN chart/trino/values.yaml
# ----------------------------------------------
# No separate overrides file. Every deviation from upstream defaults is edited
# in place and marked, so this lists the complete set of decisions:
#     grep -n "data-platform)" chart/trino/values.yaml
#
#   catalogs           + data_platform (Iceberg REST -> Polaris, vended creds)
#   envFrom            + trino-polaris-credentials Secret
#   serviceAccount     "" -> data-platform-workload  (IRSA)
#   resourceGroups     {} -> team_a / team_b / etl / other isolation
#   server.workers     2 -> 1
#   server.autoscaling off -> on, max 3
#   query.maxMemory    4GB -> 2GB
#   coordinator heap   8G -> 1500M      | worker heap 8G -> 3G
#   coordinator node   workload=critical | worker node workload=critical too
#                      (workers were on spot; moved off -- see values.yaml)
#   resources          set for both
#
# Usage:
#   ./03_install_trino_prod.sh            # install / upgrade
#   ./03_install_trino_prod.sh diff       # render manifests locally, apply nothing
#   ./03_install_trino_prod.sh verify     # report status, change nothing
#   ./03_install_trino_prod.sh sql        # open an interactive Trino CLI
#   ./03_install_trino_prod.sh smoke      # run the end-to-end query checks
#   ./03_install_trino_prod.sh logs       # tail coordinator logs
#   ./03_install_trino_prod.sh uninstall  # remove the release
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="data-platform"
RELEASE_NAME="trino"
CHART_PATH="$SCRIPT_DIR/chart/trino"
CLUSTER_NAME="data-platform-prod"
REGION="ap-southeast-1"
CATALOG="data_platform"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH. On macOS: brew install $1" >&2; exit 1; }; }
need helm
need kubectl

require_chart() {
  [ -f "$CHART_PATH/Chart.yaml" ] || {
    echo "ERROR: no chart at $CHART_PATH" >&2
    echo "       helm repo add trino https://trinodb.github.io/charts" >&2
    echo "       helm pull trino/trino --version 1.42.2 --untar --untardir \"$SCRIPT_DIR/chart\"" >&2
    exit 1
  }
}

# Runs SQL through the trino CLI that ships inside the coordinator image, so
# there is nothing extra to install locally and the query travels the same
# in-cluster path a real client would use.
trino_sql() {
  kubectl exec -i -n "$NAMESPACE" deploy/trino-coordinator -- \
    trino --server localhost:8080 --user "${TRINO_USER:-etl_setup}" --output-format=ALIGNED --execute "$1"
}

case "$MODE" in
  verify)
    echo "== Chart on disk =="
    if [ -f "$CHART_PATH/Chart.yaml" ]; then
      grep -E '^(name|version|appVersion):' "$CHART_PATH/Chart.yaml"
      echo "  local edits: $(grep -c 'data-platform)' "$CHART_PATH/values.yaml") annotated lines"
    else
      echo "  (missing)"
    fi
    echo ""
    echo "== Prerequisites =="
    kubectl get secret trino-polaris-credentials -n "$NAMESPACE" >/dev/null 2>&1 \
      && echo "  Secret trino-polaris-credentials: present" || echo "  Secret: MISSING (run 01_)"
    kubectl get svc polaris -n "$NAMESPACE" >/dev/null 2>&1 \
      && echo "  Polaris Service: present" || echo "  Polaris: MISSING"
    echo ""
    echo "== Release =="
    helm status "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null | head -10 || echo "  (not installed yet)"
    echo ""
    echo "== Pods =="
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=trino -o wide 2>/dev/null || echo "  (none)"
    echo ""
    echo "== HPA =="
    kubectl get hpa -n "$NAMESPACE" 2>/dev/null || echo "  (none)"
    exit 0
    ;;
  diff)
    require_chart
    helm template "$RELEASE_NAME" "$CHART_PATH" --namespace "$NAMESPACE"
    exit 0
    ;;
  logs)
    kubectl logs -n "$NAMESPACE" deploy/trino-coordinator --tail=100 -f
    exit 0
    ;;
  sql)
    echo "Connecting as user '${TRINO_USER:-etl_setup}'. Try: SHOW CATALOGS;   \\q to quit"
    kubectl exec -it -n "$NAMESPACE" deploy/trino-coordinator -- \
      trino --server localhost:8080 --user "${TRINO_USER:-etl_setup}"
    exit 0
    ;;
  smoke)
    echo "== 1. Trino itself is alive (tpch needs no storage at all) =="
    trino_sql "SELECT count(*) AS nations FROM tpch.tiny.nation"

    echo ""
    echo "== 2. Trino can see the Polaris catalog =="
    trino_sql "SHOW CATALOGS"

    echo ""
    echo "== 3. Trino can talk to Polaris over the REST API =="
    # This is the call that fails if the OAuth2 credential or the REST URI is
    # wrong. An empty result is correct on a fresh catalog; an error is not.
    trino_sql "SHOW SCHEMAS FROM ${CATALOG}"

    echo ""
    echo "== 4. Resource groups are loaded =="
    trino_sql "SELECT resource_group_id FROM system.runtime.queries WHERE query_id = (SELECT max(query_id) FROM system.runtime.queries)"

    echo ""
    echo "== 5. Workers have joined =="
    trino_sql "SELECT node_id, state FROM system.runtime.nodes"

    cat <<EOF

If all five passed, the read path is proven end to end:
  Trino -> Polaris (OAuth2 + REST) -> RDS pointer lookup -> vended S3 creds

Writing is not covered here: creating a table exercises the S3 credential
vending path, and is the next thing to test.
  ./03_install_trino_prod.sh sql
  CREATE SCHEMA ${CATALOG}.demo;
EOF
    exit 0
    ;;
  uninstall)
    read -r -p "Uninstall release '$RELEASE_NAME' from namespace '$NAMESPACE'? [y/N] " ans
    [ "$ans" = "y" ] || { echo "Aborted."; exit 0; }
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
    echo "Release removed. Iceberg tables are untouched -- they live in Polaris"
    echo "and S3, not in Trino. Re-installing picks them all up again."
    exit 0
    ;;
  deploy) ;;
  *)
    echo "Unknown mode '$MODE'. Use: deploy | diff | verify | sql | smoke | logs | uninstall" >&2
    exit 1
    ;;
esac

echo "== Trino install ================================================="

echo "[1/5] Checking cluster access..."
kubectl get nodes >/dev/null 2>&1 \
  || { echo "ERROR: kubectl can't reach the cluster. Run: aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION" >&2; exit 1; }

echo "[2/5] Checking prerequisites..."
require_chart
kubectl get serviceaccount data-platform-workload -n "$NAMESPACE" >/dev/null 2>&1 \
  || { echo "ERROR: ServiceAccount 'data-platform-workload' missing. Run 01_iceberg_catalog_and_polaris_prod/01_create_namespace_and_sa_prod.sh." >&2; exit 1; }
kubectl get secret trino-polaris-credentials -n "$NAMESPACE" >/dev/null 2>&1 \
  || { echo "ERROR: Secret 'trino-polaris-credentials' missing. Run ./01_create_trino_secret_prod.sh first." >&2; exit 1; }
# The public ALB must never front an unauthenticated Trino coordinator. Both
# Secrets are created before every chart install so Helm cannot successfully
# roll out a pod that only fails later with CreateContainerConfigError.
for secret in trino-password-authentication trino-internal-communication; do
  kubectl get secret "$secret" -n "$NAMESPACE" >/dev/null 2>&1 || {
    echo "ERROR: Secret '${secret}' missing. Run ./02_create_trino_auth_secrets_prod.sh first." >&2
    exit 1
  }
done
# Trino is useless without a catalog to point at; fail here rather than after
# a five-minute rollout that ends in connection errors.
kubectl get svc polaris -n "$NAMESPACE" >/dev/null 2>&1 \
  || { echo "ERROR: the Polaris Service is not present -- Trino has nothing to query." >&2; exit 1; }

echo "[3/5] Checking node capacity for the requested placement..."
# Both the coordinator and the workers now want workload=critical nodes. The
# workers used to require a workload=batch (spot) node; that requirement was
# removed when they moved to on-demand -- see the nodeSelector comment in
# chart/trino/values.yaml for why. ng-spot can therefore sit at zero whenever
# no Spark job is running.
#
# Without this check the install "succeeds" and the pods sit Pending, which
# reads like a Trino problem rather than a capacity one.
CRITICAL_NODES="$(kubectl get nodes -l workload=critical -o name 2>/dev/null | wc -l | tr -d ' ')"
if [ "$CRITICAL_NODES" -lt 1 ]; then
  echo "ERROR: no node labelled workload=critical (the ng-ondemand group). Run scale/scale_up.sh." >&2
  exit 1
fi
if [ "$CRITICAL_NODES" -lt 2 ]; then
  cat >&2 <<EOF
WARNING: only one workload=critical node.

  The coordinator (300m/2Gi) and one worker (800m/4Gi) now share this group
  with Polaris and Airflow. On a single m5.large (~1.9 vCPU / 7Gi allocatable)
  that will not fit, and the pod that misses out stays Pending with no error
  from helm until --wait times out.

  Add the second node:
    eksctl scale nodegroup --cluster $CLUSTER_NAME --region $REGION \\
      --name ng-ondemand --nodes 2 --nodes-min 1

EOF
fi
echo "      critical: ${CRITICAL_NODES} node(s), batch: $(kubectl get nodes -l workload=batch -o name 2>/dev/null | wc -l | tr -d ' ') node(s) (batch is only needed by Spark)"

echo "[4/5] helm upgrade --install from $CHART_PATH ..."
echo "      chart $(grep -E '^version:' "$CHART_PATH/Chart.yaml") / Trino $(grep -E '^appVersion:' "$CHART_PATH/Chart.yaml")"
helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  --wait --timeout 10m

echo "[5/5] Pods:"
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=trino -o wide

cat <<EOF

Trino is up.

  ./03_install_trino_prod.sh smoke   # five end-to-end checks
  ./03_install_trino_prod.sh sql     # interactive CLI
  ./03_install_trino_prod.sh logs

The Service is ClusterIP. To reach it from your Mac (JDBC, DBeaver, etc.):
  kubectl port-forward -n $NAMESPACE svc/trino 8080:8080
  # then jdbc:trino://localhost:8080  with any username; the resource group
  # is chosen from that username (team_a*, team_b*, etl*, else 'other')
EOF
