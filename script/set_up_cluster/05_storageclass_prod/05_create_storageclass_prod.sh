#!/usr/bin/env bash
#
# 05_create_storageclass_prod.sh
#
# Creates the cluster's default StorageClass (gp3, EBS-backed).
#
# This is cluster plumbing rather than a component: nothing here belongs to
# Harbor or Prometheus specifically, but neither can run without it. It lives
# under set_up_cluster/ for that reason.
#
# Safe to re-run. Applying an unchanged StorageClass is a no-op.
#
# Usage:
#   ./05_create_storageclass_prod.sh          # create
#   ./05_create_storageclass_prod.sh verify   # report state, change nothing
#   ./05_create_storageclass_prod.sh test     # provision a 1Gi volume and delete it
#   ./05_create_storageclass_prod.sh delete   # remove the StorageClass
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/gp3-storageclass.yaml"
SC_NAME="gp3"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need kubectl

case "$MODE" in
  verify)
    echo "=== storage classes ==="
    kubectl get storageclass 2>/dev/null || echo "  none"
    echo ""
    echo "=== EBS CSI driver pods ==="
    # The StorageClass is only a declaration. Without the controller running,
    # a PVC referencing it stays Pending with no obvious explanation.
    # Label is `app=ebs-csi-controller`, which is what the EKS *managed addon*
    # applies. The upstream Helm chart uses
    # app.kubernetes.io/name=aws-ebs-csi-driver instead -- matching on that
    # finds nothing on a cluster using the addon, and reports a healthy driver
    # as missing.
    kubectl get pods -n kube-system -l app=ebs-csi-controller \
      -o wide 2>/dev/null || echo "  none -- is the aws-ebs-csi-driver addon installed?"
    echo ""
    echo "=== PVCs still unbound anywhere in the cluster ==="
    kubectl get pvc -A 2>/dev/null | awk 'NR==1 || $3!="Bound"' || echo "  none"
    exit 0
    ;;

  test)
    # Proves the whole chain end to end: StorageClass -> CSI controller -> IAM
    # permission to call ec2:CreateVolume -> attachment to a node. Each link
    # fails differently and only the last one is visible from `kubectl get sc`.
    echo "Creating a throwaway PVC and a pod to consume it..."
    kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gp3-smoke-test
  namespace: default
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: gp3
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: gp3-smoke-test
  namespace: default
spec:
  nodeSelector:
    workload: critical
  containers:
    - name: writer
      image: public.ecr.aws/docker/library/busybox:1.36
      command: ["sh", "-c", "echo ok > /data/probe && cat /data/probe && sleep 20"]
      volumeMounts:
        - { name: vol, mountPath: /data }
  volumes:
    - name: vol
      persistentVolumeClaim:
        claimName: gp3-smoke-test
  restartPolicy: Never
EOF
    echo ""
    echo "Waiting for the volume to bind and the pod to run (up to 3 min)..."
    # The PVC cannot bind until the pod is scheduled -- that is what
    # WaitForFirstConsumer means -- so the pod, not the PVC, is what to wait on.
    if kubectl wait --for=condition=Ready pod/gp3-smoke-test -n default --timeout=180s 2>/dev/null; then
      echo ""
      kubectl get pvc gp3-smoke-test -n default
      echo ""
      echo "PASS -- the volume was provisioned, attached and written to."
    else
      echo ""
      echo "FAIL -- the pod did not become Ready. What the events say:"
      kubectl describe pvc gp3-smoke-test -n default | sed -n '/Events:/,$p'
      kubectl describe pod gp3-smoke-test -n default | sed -n '/Events:/,$p'
    fi
    echo ""
    echo "Cleaning up..."
    kubectl delete pod gp3-smoke-test -n default --ignore-not-found --wait=true >/dev/null
    kubectl delete pvc gp3-smoke-test -n default --ignore-not-found >/dev/null
    echo "Done. reclaimPolicy is Delete, so the EBS volume is removed with the PVC."
    exit 0
    ;;

  delete)
    # Existing PersistentVolumes keep working -- a PV records its parameters at
    # provisioning time and does not consult the class afterwards. Only NEW
    # PVCs that omit storageClassName are affected.
    kubectl delete -f "$MANIFEST" --ignore-not-found
    echo "Removed. Volumes already provisioned are unaffected; new PVCs without"
    echo "an explicit storageClassName will now stay Pending."
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
echo "[1/3] Checking the EBS CSI driver is present..."
if ! kubectl get pods -n kube-system -l app=ebs-csi-controller \
     --no-headers 2>/dev/null | grep -q Running; then
  cat >&2 <<'EOF'
ERROR: the aws-ebs-csi-driver controller is not running in kube-system.

  The StorageClass below would be created successfully but no volume would
  ever be provisioned from it. Install the addon first:

    eksctl create addon --name aws-ebs-csi-driver --cluster <cluster> \
      --region ap-southeast-1

  It is already declared in 02_eks_cluster_prod/eks-cluster.yaml, so on a
  cluster built from that file this check should pass.
EOF
  exit 1
fi
echo "      controller is running"

echo "[2/3] Checking for an existing default StorageClass..."
# Two classes both marked default is a real configuration error: Kubernetes
# picks one arbitrarily, so identical PVCs can land on different storage.
EXISTING_DEFAULT="$(kubectl get storageclass -o json 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
for i in d.get('items',[]):
    a=i['metadata'].get('annotations',{}) or {}
    if a.get('storageclass.kubernetes.io/is-default-class')=='true':
        print(i['metadata']['name'])
" || true)"

if [ -n "$EXISTING_DEFAULT" ] && [ "$EXISTING_DEFAULT" != "$SC_NAME" ]; then
  echo "      WARNING: '${EXISTING_DEFAULT}' is already the default."
  echo "      Two defaults is ambiguous. Remove the annotation from it with:"
  echo "        kubectl patch storageclass ${EXISTING_DEFAULT} -p \\"
  echo "          '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"false\"}}}'"
elif [ -n "$EXISTING_DEFAULT" ]; then
  echo "      '${SC_NAME}' is already the default -- re-applying is a no-op"
else
  echo "      no default set yet"
fi

echo "[3/3] Applying..."
kubectl apply -f "$MANIFEST"

echo ""
kubectl get storageclass

cat <<'EOF'

The default StorageClass is in place. Nothing changes for workloads already
running -- this only affects PVCs created from now on.

Worth knowing before the next component:

  volumeBindingMode is WaitForFirstConsumer, so a new PVC sits in Pending
  until a pod actually wants it. That is correct behaviour, not a fault.
  A PVC with no pod will stay Pending indefinitely and should not be
  investigated as a problem.

Prove the full chain works before relying on it:

  ./05_create_storageclass_prod.sh test
EOF
