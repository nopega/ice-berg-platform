#!/usr/bin/env bash
#
# 01_create_namespace_and_sa_prod.sh
#
# Creates the `spark` namespace, the ServiceAccount its driver and executor
# pods run as, and the RBAC that lets a driver create its own executors and
# lets Airflow submit jobs.
#
# All of it is in namespace-and-rbac.yaml; this script only substitutes the
# IAM role ARN (which contains the AWS account ID) and applies it.
#
# Usage:
#   ./01_create_namespace_and_sa_prod.sh          # create (idempotent)
#   ./01_create_namespace_and_sa_prod.sh verify   # report state
#   ./01_create_namespace_and_sa_prod.sh delete   # remove namespace and RBAC
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="ap-southeast-1"
NAMESPACE="spark"
SA_NAME="spark"
ROLE_NAME="data-platform-prod-spark-irsa-role"
MANIFEST="$SCRIPT_DIR/namespace-and-rbac.yaml"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need kubectl; need aws

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

case "$MODE" in
  verify)
    echo "=== namespace ==="
    kubectl get namespace "$NAMESPACE" 2>/dev/null || echo "  not created"
    echo ""
    echo "=== service account and its IRSA annotation ==="
    kubectl get sa "$SA_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.metadata.name}{"  ->  "}{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}' \
      2>/dev/null || echo "  not created"
    echo ""
    echo "=== roles and bindings ==="
    kubectl get role,rolebinding -n "$NAMESPACE" 2>/dev/null || echo "  none"
    echo ""
    echo "=== can a driver actually create executors? ==="
    # The authoritative answer, straight from the API server's own authorizer.
    # Reading the Role YAML only tells you what was intended.
    for verb in create delete; do
      printf '  %-8s pods : %s\n' "$verb" \
        "$(kubectl auth can-i "$verb" pods -n "$NAMESPACE" \
             --as="system:serviceaccount:${NAMESPACE}:${SA_NAME}" 2>/dev/null || echo '?')"
    done
    echo ""
    echo "=== can Airflow submit a SparkApplication? ==="
    printf '  create sparkapplications : %s\n' \
      "$(kubectl auth can-i create sparkapplications -n "$NAMESPACE" \
           --as='system:serviceaccount:airflow:airflow-worker' 2>/dev/null || echo '?')"
    # Should be "no". Airflow declares intent; it does not run containers here.
    printf '  create pods (want: no)   : %s\n' \
      "$(kubectl auth can-i create pods -n "$NAMESPACE" \
           --as='system:serviceaccount:airflow:airflow-worker' 2>/dev/null || echo '?')"
    exit 0
    ;;

  delete)
    kubectl delete -f <(sed "s|__SPARK_ROLE_ARN__|${ROLE_ARN}|g" "$MANIFEST") --ignore-not-found
    cat <<EOF

Namespace removed, and every SparkApplication in it with it.

The IAM role survives -- remove it separately if that is the intent:
  ./00_create_spark_irsa_prod.sh delete
EOF
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
echo "[1/3] Checking the IAM role exists..."
aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || {
  echo "ERROR: IAM role ${ROLE_NAME} does not exist." >&2
  echo "       Run ./00_create_spark_irsa_prod.sh first." >&2
  echo "" >&2
  echo "       Annotating a ServiceAccount with a role ARN that does not exist" >&2
  echo "       produces pods that start normally and fail on their first S3" >&2
  echo "       call with AccessDenied -- which is a much worse place to find" >&2
  echo "       out than here." >&2
  exit 1
}
echo "      ${ROLE_ARN}"

echo "[2/3] Applying namespace, ServiceAccount and RBAC..."
sed "s|__SPARK_ROLE_ARN__|${ROLE_ARN}|g" "$MANIFEST" | kubectl apply -f -

echo "[3/3] Asking the API server what these identities can actually do..."
DRIVER_CREATE="$(kubectl auth can-i create pods -n "$NAMESPACE" \
  --as="system:serviceaccount:${NAMESPACE}:${SA_NAME}" 2>/dev/null || echo no)"
echo "      spark SA can create pods            : ${DRIVER_CREATE}"
[ "$DRIVER_CREATE" = "yes" ] || {
  echo "ERROR: the driver cannot create executor pods. Jobs would hang at" >&2
  echo "       'Initial job has not accepted any resources'." >&2
  exit 1
}

# The SparkApplication CRD does not exist until the operator is installed, so
# this check is informational rather than fatal on a first run.
AIRFLOW_SUBMIT="$(kubectl auth can-i create sparkapplications -n "$NAMESPACE" \
  --as='system:serviceaccount:airflow:airflow-worker' 2>/dev/null || echo no)"
echo "      airflow SA can submit SparkApplication: ${AIRFLOW_SUBMIT}"

AIRFLOW_PODS="$(kubectl auth can-i create pods -n "$NAMESPACE" \
  --as='system:serviceaccount:airflow:airflow-worker' 2>/dev/null || echo no)"
echo "      airflow SA can create pods (want no)  : ${AIRFLOW_PODS}"
[ "$AIRFLOW_PODS" = "no" ] || echo "      WARNING: Airflow can create arbitrary pods here. That is wider than intended."

cat <<EOF

Namespace and identities ready.

If 'airflow SA can submit SparkApplication' says no, that is expected on a
first run: the CRD it refers to does not exist until the operator is
installed. Re-run 'verify' after the next step and it should say yes.

  ./02_install_spark_operator_prod.sh
EOF
