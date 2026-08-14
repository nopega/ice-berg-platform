#!/usr/bin/env bash
#
# 02_install_spark_operator_prod.sh
#
# Installs the Kubeflow Spark Operator -- the controller that turns a
# SparkApplication object into real driver and executor pods.
#
# VENDOR THE CHART FIRST (once, then commit it):
#
#     helm repo add spark-operator https://kubeflow.github.io/spark-operator
#     helm repo update
#     helm pull spark-operator/spark-operator --version 2.5.0 --untar --untardir ./chart
#
# CONFIGURATION LIVES IN chart/spark-operator/values.yaml
# ---------------------------------------------------------
# Same convention as every other component here: the vendored values.yaml is
# edited in place and each deviation carries a "CHANGED (data-platform)"
# comment saying why.
#
#     grep -n "data-platform)" chart/spark-operator/values.yaml
#
# WHAT THIS ACTUALLY INSTALLS
# -----------------------------
#   1. CRDs -- SparkApplication and ScheduledSparkApplication. After this,
#      `kubectl get sparkapplications` is a valid command.
#   2. A controller pod that watches for those objects and creates pods.
#   3. An admission webhook that injects volumes, initContainers, nodeSelectors
#      and tolerations into the pods Spark generates. Spark's own submit path
#      cannot set those, so without the webhook they are silently dropped.
#
# Nothing here runs a Spark job. It teaches the cluster what a Spark job IS.
#
# Usage:
#   ./02_install_spark_operator_prod.sh            # install or upgrade
#   ./02_install_spark_operator_prod.sh diff       # render manifests, apply nothing
#   ./02_install_spark_operator_prod.sh verify     # pods, CRDs, webhook, permissions
#   ./02_install_spark_operator_prod.sh logs       # tail the controller
#   ./02_install_spark_operator_prod.sh uninstall  # remove (CRDs are KEPT)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="spark-operator"
NAMESPACE="spark-operator"
JOB_NAMESPACE="spark"
CHART_VERSION="2.5.0"
CHART_PATH="$SCRIPT_DIR/chart/spark-operator"
SA_NAME="spark"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need kubectl; need helm

case "$MODE" in
  logs)
    kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/name=spark-operator \
      --tail=80 --prefix -f
    exit 0
    ;;

  uninstall)
    helm uninstall "$RELEASE" -n "$NAMESPACE" || true
    cat <<EOF

Release removed. The CRDs are deliberately LEFT IN PLACE.

Deleting a CRD deletes every object of that kind with it -- including any
SparkApplication currently running, whose driver and executor pods would then
be orphaned rather than cleaned up. Remove them by hand only when no jobs
exist:

  kubectl delete crd sparkapplications.sparkoperator.k8s.io
  kubectl delete crd scheduledsparkapplications.sparkoperator.k8s.io
EOF
    exit 0
    ;;

  verify)
    echo "=== release ==="
    helm status "$RELEASE" -n "$NAMESPACE" --output json 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(' ', d['name'], d['info']['status'], 'rev', d['version'])" \
      2>/dev/null || echo "  not installed"
    echo ""
    echo "=== pods ==="
    kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || echo "  none"
    echo ""
    echo "=== CRDs (this is what makes 'kind: SparkApplication' valid) ==="
    kubectl get crd 2>/dev/null | grep -E 'NAME|sparkoperator' || echo "  none"
    echo ""
    echo "=== which namespaces the controller watches ==="
    # An operator watching every namespace when it should watch one is not
    # visible from `get pods`; it is an argument on the container.
    kubectl get deploy -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.template.spec.containers[*]}{.args}{"\n"}{end}{end}' 2>/dev/null \
      || echo "  n/a"
    echo ""
    echo "=== webhook (without it, volumes and initContainers are dropped) ==="
    kubectl get mutatingwebhookconfiguration 2>/dev/null | grep -E 'NAME|spark' || echo "  none"
    echo ""
    echo "=== can Airflow submit a job now that the CRD exists? ==="
    printf '  airflow-worker create sparkapplications : %s\n' \
      "$(kubectl auth can-i create sparkapplications -n "$JOB_NAMESPACE" \
           --as='system:serviceaccount:airflow:airflow-worker' 2>/dev/null || echo '?')"
    echo ""
    echo "=== jobs currently known to the cluster ==="
    kubectl get sparkapplications -A 2>/dev/null || echo "  none (CRD may not be installed)"
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
echo "[1/5] Preflight..."

[ -d "$CHART_PATH" ] || {
  echo "ERROR: chart not found at ${CHART_PATH}" >&2
  echo "       Vendor it first:" >&2
  echo "         helm repo add spark-operator https://kubeflow.github.io/spark-operator" >&2
  echo "         helm repo update" >&2
  echo "         helm pull spark-operator/spark-operator --version ${CHART_VERSION} --untar --untardir \"$SCRIPT_DIR/chart\"" >&2
  exit 1
}

ACTUAL_VERSION="$(python3 -c "
import yaml
print(yaml.safe_load(open('${CHART_PATH}/Chart.yaml'))['version'])
" 2>/dev/null || echo unknown)"
if [ "$ACTUAL_VERSION" != "$CHART_VERSION" ]; then
  echo "      WARNING: vendored chart is ${ACTUAL_VERSION}, this script expects ${CHART_VERSION}."
  echo "               Check the CHANGED lines in chart/spark-operator/values.yaml"
  echo "               still match this chart's value names."
else
  echo "      chart ${CHART_VERSION} present"
fi

# The job namespace and its ServiceAccount must exist BEFORE the operator,
# because values.yaml sets spark.serviceAccount.create=false. If they
# are missing, the operator installs fine and every job fails to schedule with
# a ServiceAccount-not-found error on the driver pod.
kubectl get namespace "$JOB_NAMESPACE" >/dev/null 2>&1 || {
  echo "ERROR: namespace '${JOB_NAMESPACE}' does not exist." >&2
  echo "       Run ./01_create_namespace_and_sa_prod.sh first." >&2
  exit 1
}

SA_ROLE="$(kubectl get sa "$SA_NAME" -n "$JOB_NAMESPACE" \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || true)"
if [ -z "$SA_ROLE" ]; then
  echo "ERROR: ServiceAccount ${SA_NAME} in namespace ${JOB_NAMESPACE} is missing" >&2
  echo "       or has no IRSA annotation. Run ./01_create_namespace_and_sa_prod.sh." >&2
  exit 1
fi
echo "      ${JOB_NAMESPACE}/${SA_NAME} -> ${SA_ROLE}"

CRITICAL_NODES="$(kubectl get nodes -l workload=critical --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[ "$CRITICAL_NODES" -gt 0 ] || {
  echo "ERROR: no node labelled workload=critical. The controller and webhook" >&2
  echo "       are pinned there and would stay Pending." >&2
  exit 1
}
echo "      ${CRITICAL_NODES} critical node(s)"

# ---------------------------------------------------------------------------
if [ "$MODE" = "diff" ]; then
  echo "[2/5] Rendering manifests (nothing is applied)..."
  helm template "$RELEASE" "$CHART_PATH" -n "$NAMESPACE"
  exit 0
fi

echo "[2/5] Installing..."
helm upgrade --install "$RELEASE" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --wait --timeout 10m

echo "[3/5] Pods..."
kubectl get pods -n "$NAMESPACE" -o wide

echo "[4/5] CRDs..."
for crd in sparkapplications.sparkoperator.k8s.io scheduledsparkapplications.sparkoperator.k8s.io; do
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    echo "      ${crd}"
  else
    echo "ERROR: CRD ${crd} was not installed. Without it, a SparkApplication" >&2
    echo "       cannot even be created -- kubectl would reject the kind." >&2
    exit 1
  fi
done

echo "[5/5] Re-checking Airflow's permission now that the CRD exists..."
# This deliberately failed on the first run of 01_, because the CRD did not
# exist yet for the authorizer to reason about. It should say yes now.
AIRFLOW_SUBMIT="$(kubectl auth can-i create sparkapplications -n "$JOB_NAMESPACE" \
  --as='system:serviceaccount:airflow:airflow-worker' 2>/dev/null || echo no)"
echo "      airflow-worker can create sparkapplications: ${AIRFLOW_SUBMIT}"
[ "$AIRFLOW_SUBMIT" = "yes" ] || \
  echo "      WARNING: Airflow cannot submit jobs. Re-run ./01_create_namespace_and_sa_prod.sh."

cat <<EOF

The cluster now understands Spark jobs.

Nothing is running: the operator is idle until a SparkApplication exists.
Prove the whole chain -- image pull from Harbor, IRSA credentials, Polaris
catalog, S3 write -- with the smoke test:

  kubectl apply -f 06_smoke_test.yaml
  kubectl get sparkapplication -n ${JOB_NAMESPACE} -w

Expected progression: NEW -> SUBMITTED -> RUNNING -> COMPLETED.

If it sticks at SUBMITTED, read the controller:
  ./02_install_spark_operator_prod.sh logs

If the driver starts and dies, read the driver itself:
  kubectl logs -n ${JOB_NAMESPACE} <name>-driver
EOF
