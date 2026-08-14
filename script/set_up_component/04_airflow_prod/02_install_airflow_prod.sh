#!/usr/bin/env bash
#
# 02_install_airflow_prod.sh
#
# Installs Apache Airflow 3.2.2 from the Helm chart vendored at ./chart/airflow.
#
# 3.2.2, not the 3.2.0 originally planned: chart 1.22.0 declares
# `appVersion: 3.2.2` and that is the application version this chart release
# was tested against. `defaultAirflowTag` is left at the chart's default rather
# than pinned downwards -- see docs/STACK_SUMMARY.md, "Why 3.2.2 and not 3.2.0".
#
# The chart was downloaded once with:
#     helm repo add apache-airflow https://airflow.apache.org
#     helm repo update
#     helm pull apache-airflow/airflow --version 1.22.0 --untar --untardir ./chart
#
# and is committed as part of the answer. This script does NOT re-download it:
# the copy on disk is the source of truth, so what gets applied is exactly what
# can be read in this repository.
#
# CONFIGURATION LIVES IN chart/airflow/values.yaml
# ------------------------------------------------
# No separate overrides file. Every deviation from upstream is edited in place
# and marked, so the complete set of decisions is:
#     grep -n "data-platform)" chart/airflow/values.yaml
#
# WHY KubernetesExecutor
# -----------------------
# CeleryExecutor needs a Redis or RabbitMQ broker plus a pool of worker pods
# sitting idle waiting for tasks. This platform runs a handful of DAG runs per
# day, each task lasting minutes to hours, so a standing worker pool would be
# paid for around the clock to be busy for a fraction of it. KubernetesExecutor
# creates one pod per task and destroys it afterwards: idle cost is zero, and
# the ~20s pod startup is irrelevant next to task durations measured in minutes.
#
# The trade-off is real but does not apply here: KubernetesExecutor is a poor
# fit for thousands of sub-minute tasks, where pod startup would dominate.
#
# Usage:
#   ./02_install_airflow_prod.sh            # install / upgrade
#   ./02_install_airflow_prod.sh diff       # render manifests locally, apply nothing
#   ./02_install_airflow_prod.sh verify     # report status, change nothing
#   ./02_install_airflow_prod.sh ui         # port-forward the web UI
#   ./02_install_airflow_prod.sh logs       # tail scheduler logs
#   ./02_install_airflow_prod.sh uninstall  # remove the release
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="airflow"
RELEASE_NAME="airflow"
CHART_PATH="$SCRIPT_DIR/chart/airflow"
CHART_VERSION="1.22.0"
LOCAL_PORT="18080"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH. On macOS: brew install $1" >&2; exit 1; }; }
need helm
need kubectl

require_chart() {
  [ -f "$CHART_PATH/Chart.yaml" ] || {
    echo "ERROR: no chart at $CHART_PATH" >&2
    echo "       Download it with:" >&2
    echo "         helm repo add apache-airflow https://airflow.apache.org" >&2
    echo "         helm repo update" >&2
    echo "         helm pull apache-airflow/airflow --version ${CHART_VERSION} --untar --untardir \"$SCRIPT_DIR/chart\"" >&2
    exit 1
  }
}

case "$MODE" in
  uninstall)
    echo "Removing release '${RELEASE_NAME}' from namespace '${NAMESPACE}'..."
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" || true
    cat <<EOF

Release removed. Deliberately left behind:

  - the 'airflow' database in RDS (all DAG history and connections)
  - the Secrets created by 01_create_airflow_secrets_prod.sh
  - the ${NAMESPACE} namespace

Re-running the installer reconnects to the same database, so history survives.
To discard it as well, drop the database and delete the namespace by hand.
EOF
    exit 0
    ;;

  logs)
    kubectl logs -n "$NAMESPACE" -l component=scheduler --tail=100 -f
    exit 0
    ;;

  ui)
    echo "Airflow UI -> http://localhost:${LOCAL_PORT}"
    echo "Default login is admin / admin unless changed in values.yaml."
    echo "Ctrl-C to stop."
    kubectl port-forward -n "$NAMESPACE" "svc/${RELEASE_NAME}-api-server" "${LOCAL_PORT}:8080"
    exit 0
    ;;

  verify)
    echo "=== release ==="
    helm status "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null | head -12 || echo "  not installed"
    echo ""
    echo "=== pods ==="
    kubectl get pods -n "$NAMESPACE" 2>/dev/null || echo "  none"
    echo ""
    echo "=== database migration job ==="
    kubectl get jobs -n "$NAMESPACE" 2>/dev/null | grep -E 'NAME|migrate' || echo "  none"
    echo ""
    echo "=== DAGs the scheduler can see ==="
    SCHED="$(kubectl get pods -n "$NAMESPACE" -l component=scheduler \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -n "$SCHED" ]; then
      kubectl exec -n "$NAMESPACE" "$SCHED" -c scheduler -- airflow dags list 2>/dev/null \
        || echo "  (scheduler not ready yet)"
    else
      echo "  (no scheduler pod)"
    fi
    exit 0
    ;;
esac

require_chart

# ---------------------------------------------------------------------------
# Preflight. Each check exists because skipping it produces a failure that
# looks like something else entirely.
# ---------------------------------------------------------------------------
echo "[1/4] Preflight..."

# The migration Job runs on install and dies instantly without this Secret,
# leaving a failed Job that blocks the next attempt.
for s in airflow-metadata airflow-fernet-key airflow-api-secret-key airflow-jwt-secret; do
  kubectl get secret "$s" -n "$NAMESPACE" >/dev/null 2>&1 || {
    echo "ERROR: Secret '$s' is missing from namespace '$NAMESPACE'." >&2
    echo "       Run ./01_create_airflow_secrets_prod.sh first." >&2
    exit 1
  }
done
echo "      secrets present"

# Airflow's control plane must not run on spot: losing the scheduler mid-run
# orphans running task pods, and losing the API server drops the UI.
CRITICAL_NODES="$(kubectl get nodes -l workload=critical --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[ "$CRITICAL_NODES" -ge 1 ] || {
  echo "ERROR: no node labelled workload=critical." >&2
  echo "       Bring the on-demand group back: ../../../scale/scale_up.sh" >&2
  exit 1
}
echo "      ${CRITICAL_NODES} node(s) labelled workload=critical"

# git-sync fails in the worst possible way when misconfigured: it clones
# something, finds no DAGs under subPath, and Airflow shows an empty DAG list
# with no error in any log. Catch the unedited placeholder here instead.
if grep -qE '^\s+repo:\s*REPLACE_ME\s*$' "$CHART_PATH/values.yaml"; then
  cat >&2 <<'EOF'
ERROR: dags.gitSync.repo is still REPLACE_ME in chart/airflow/values.yaml.

  Airflow pulls DAGs from git rather than from a shared volume (an EBS PVC is
  ReadWriteOnce and cannot be mounted by pods across several nodes). Point it
  at the repository holding this project:

      dags:
        gitSync:
          repo: https://github.com/<you>/<this-repo>.git
          branch: main
          subPath: "problem2_answer/dags"

  A public HTTPS URL needs no credentials. For a private repo, also create a
  Secret and set dags.gitSync.credentialsSecret.
EOF
  exit 1
fi
echo "      gitSync repo configured"

# Capacity is the failure mode that wastes the most time, because Kubernetes
# reports it as a Pending pod with no error rather than as a rejected install.
# Airflow's control plane asks for roughly 1.1 CPU / 2.3Gi on top of whatever
# Polaris and the Trino coordinator already hold on the same nodes.
ALLOCATABLE_CPU="$(kubectl get nodes -l workload=critical \
  -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{"\n"}{end}' 2>/dev/null | head -1)"
echo "      (first critical node allocatable CPU: ${ALLOCATABLE_CPU:-unknown})"
echo "      if pods stay Pending after install, the node is full -- see NOTES at the"
echo "      bottom of chart/airflow/values.yaml for what to scale"

echo "[2/4] Chart..."
helm show chart "$CHART_PATH" | grep -E '^(name|version|appVersion):' | sed 's/^/      /'

if [ "$MODE" = "diff" ]; then
  echo "[3/4] Rendering manifests (nothing is applied)..."
  helm template "$RELEASE_NAME" "$CHART_PATH" -n "$NAMESPACE"
  exit 0
fi

echo "[3/4] Installing / upgrading..."
# --timeout is generous because the release blocks on a database migration Job
# against RDS, which on a t4g.micro takes a few minutes on a first install.
helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --wait \
  --timeout 15m

# The chart deploys the statsd-exporter and annotates its Service with
# prometheus.io/scrape, but ships no ServiceMonitor -- and the Prometheus
# Operator does not read those annotations. Without the object below the
# exporter runs and is never scraped, which nothing reports as a problem.
#
# Applied after the release because the Service it selects has to exist, and
# skipped rather than failed when the CRD is absent, so this script still works
# on a cluster where monitoring has not been installed.
if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  echo "      applying the StatsD ServiceMonitor..."
  kubectl apply -f "$SCRIPT_DIR/statsd-servicemonitor.yaml" >/dev/null
else
  echo "      NOTE: ServiceMonitor CRD not found; Airflow's metrics will be"
  echo "            served but not collected. Install"
  echo "            set_up_cluster/06_monitoring_prod, then re-run this."
fi

echo "[4/4] Result:"
kubectl get pods -n "$NAMESPACE"

cat <<EOF

Airflow is up.

  ./02_install_airflow_prod.sh ui       # http://localhost:${LOCAL_PORT}
  ./02_install_airflow_prod.sh verify   # pods, migration job, DAG list
  ./02_install_airflow_prod.sh logs     # scheduler logs

Next: the Spark Operator, so DAGs have something to submit jobs to.
EOF
