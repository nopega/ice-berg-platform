#!/usr/bin/env bash
#
# 07_deploy_history_server_prod.sh
#
# Deploys the Spark History Server, which is what makes a finished Spark job
# inspectable.
#
# WHY A DRIVER CANNOT DO THIS
# -----------------------------
# A Spark driver serves its own UI on port 4040, and that UI is gone the moment
# the driver exits. Two independent reasons it cannot be given a hostname:
#
#   1. It only exists while a job runs. This pipeline runs once a day for a few
#      minutes, so the `spark` namespace is empty the rest of the time.
#   2. Its name carries a random suffix that changes every run --
#      taxi-bronze-20240115-mtb9nwth, then -ua6l2sko, then -3cl22jz7. A Service
#      selector has nothing stable to match.
#
# `delete_on_termination: false` in the DAG keeps the pod OBJECT afterwards so
# `kubectl logs` still works, but the pod is Completed. Nothing answers on 4040.
#
# The History Server reads the event logs the drivers already write to
# s3://data-store-prod-logs/spark-events/ and renders the same UI from them.
#
# WHY IT NEEDS NO NEW IAM
# -------------------------
# It runs as the `spark` ServiceAccount, whose IRSA role already has GetObject
# and ListBucket on that prefix -- the same grants the drivers use to write
# there. Reading back what you wrote needs nothing extra.
#
# Usage:
#   ./07_deploy_history_server_prod.sh          # apply
#   ./07_deploy_history_server_prod.sh verify   # is it serving, and does it see anything
#   ./07_deploy_history_server_prod.sh logs
#   ./07_deploy_history_server_prod.sh ui       # port-forward to localhost:18080
#   ./07_deploy_history_server_prod.sh delete
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="spark"
MANIFEST="$SCRIPT_DIR/history-server.yaml"
DEPLOY="spark-history-server"
LOGS_BUCKET="data-store-prod-logs"
EVENTLOG_PREFIX="spark-events"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need kubectl

case "$MODE" in
  logs)
    kubectl logs -n "$NAMESPACE" "deploy/${DEPLOY}" --tail=100 -f
    exit 0
    ;;
  ui)
    echo "History Server -> http://localhost:18080"
    kubectl port-forward -n "$NAMESPACE" "svc/${DEPLOY}" 18080:80
    exit 0
    ;;
  delete)
    kubectl delete -f "$MANIFEST" --ignore-not-found
    echo "Deleted. The event logs in S3 are untouched -- redeploying reads the"
    echo "same history back."
    exit 0
    ;;
  verify)
    echo "=== pod ==="
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=spark-history-server -o wide 2>/dev/null \
      || echo "  not deployed"
    echo ""
    echo "=== event logs in S3 ==="
    # The distinction that matters: a History Server with no applications is
    # either broken or simply looking at an empty prefix, and those are fixed
    # very differently.
    if command -v aws >/dev/null 2>&1; then
      aws s3 ls "s3://${LOGS_BUCKET}/${EVENTLOG_PREFIX}/" 2>/dev/null | tail -5 || echo "  cannot list"
    else
      echo "  (aws not in PATH)"
    fi
    echo ""
    echo "=== applications the server can see ==="
    # Asked from inside the pod so this works before DNS and the ALB exist.
    kubectl exec -n "$NAMESPACE" "deploy/${DEPLOY}" -- \
      sh -c 'command -v curl >/dev/null && curl -s localhost:18080/api/v1/applications || echo "(no curl in image; use the ui mode)"' 2>/dev/null \
      | head -c 400 || echo "  pod not ready"
    echo ""
    exit 0
    ;;
  deploy) ;;
  *) echo "Usage: $0 [deploy|verify|logs|ui|delete]" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
echo "[1/3] Preflight..."
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || {
  echo "ERROR: namespace '${NAMESPACE}' does not exist." >&2
  echo "       Run ./01_create_namespace_and_sa_prod.sh first." >&2
  exit 1
}
kubectl get serviceaccount spark -n "$NAMESPACE" >/dev/null 2>&1 || {
  echo "ERROR: ServiceAccount 'spark' missing. It carries the IRSA annotation" >&2
  echo "       that lets this read the event logs." >&2
  exit 1
}
kubectl get secret harbor-pull -n "$NAMESPACE" >/dev/null 2>&1 || {
  echo "ERROR: 'harbor-pull' missing; the image cannot be pulled." >&2
  echo "       Run ./04_create_image_pull_secret_prod.sh first." >&2
  exit 1
}
echo "      namespace, ServiceAccount and pull secret present"

echo "[2/3] Applying..."
kubectl apply -f "$MANIFEST"

echo "[3/3] Waiting for it to become ready..."
# A failure here is almost always one of three things, and the rollout message
# does not distinguish them: the image cannot be pulled, the IRSA role cannot
# read the bucket, or the log directory is empty and S3A rejects a prefix that
# does not exist as an object.
if ! kubectl rollout status -n "$NAMESPACE" "deploy/${DEPLOY}" --timeout=180s; then
  echo ""
  echo "Not ready. The log usually names the cause directly:" >&2
  echo "  $0 logs" >&2
  echo "" >&2
  echo "  AccessDenied      -> the spark IRSA role lost its read on" >&2
  echo "                       s3://${LOGS_BUCKET}/${EVENTLOG_PREFIX}" >&2
  echo "  ImagePullBackOff  -> harbor-pull, or Harbor is down" >&2
  echo "  FileNotFound      -> the ${EVENTLOG_PREFIX}/ prefix has no directory" >&2
  echo "                       marker; 00_create_spark_irsa_prod.sh creates it" >&2
  exit 1
fi

echo ""
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=spark-history-server

cat <<EOF

Serving on the cluster-internal Service ${DEPLOY}:80.

  $0 ui        # http://localhost:18080 without waiting for the ALB
  $0 verify    # what it can see, and what is actually in S3

To publish it at spark.nopega.net, the Ingress rule already exists in
set_up_public_access/ingress-public.yaml. Apply it and the DNS
row is generated for you:

  cd ../../set_up_public_access
  ./02_apply_public_ingress_prod.sh

An empty application list is not a fault. Event logs appear only after a Spark
job has finished -- run the DAG once, then look again.
EOF
