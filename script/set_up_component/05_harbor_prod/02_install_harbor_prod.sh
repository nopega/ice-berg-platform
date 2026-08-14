#!/usr/bin/env bash
#
# 02_install_harbor_prod.sh
#
# Installs Harbor 2.15.1 from the Helm chart vendored at ./chart/harbor.
#
# VENDOR THE CHART FIRST (once, then commit it):
#
#     helm repo add harbor https://helm.goharbor.io
#     helm repo update
#     helm pull harbor/harbor --version 1.19.1 --untar --untardir ./chart
#
# CONFIGURATION LIVES IN chart/harbor/values.yaml
# -------------------------------------------------
# Same convention as Trino and Airflow: the vendored chart's values.yaml is
# edited in place and every deviation from the chart default carries a
# "CHANGED (data-platform)" comment saying why.
#
#     grep -n "data-platform)" chart/harbor/values.yaml
#
# The one exception is the internal Postgres password -- see step 2 below.
#
# Usage:
#   ./02_install_harbor_prod.sh            # install or upgrade
#   ./02_install_harbor_prod.sh diff       # render the manifests, apply nothing
#   ./02_install_harbor_prod.sh verify     # pods, PVCs, S3 wiring, admin URL
#   ./02_install_harbor_prod.sh ui         # port-forward to localhost:18081
#   ./02_install_harbor_prod.sh logs       # tail core + registry
#   ./02_install_harbor_prod.sh uninstall  # remove the release (PVCs are kept)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="harbor"
NAMESPACE="harbor"
CHART_VERSION="1.19.1"
CHART_PATH="$SCRIPT_DIR/chart/harbor"
REGISTRY_BUCKET="data-store-prod-registry"
REGION="ap-southeast-1"
K8S_S3_SECRET="harbor-registry-s3"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need kubectl; need helm

case "$MODE" in
  ui)
    cat <<EOF
Port-forwarding the Harbor portal to http://localhost:18081

  user:     admin
  password: ./01_create_harbor_secrets_prod.sh show-admin

Note that pushing images to localhost:18081 will NOT work: externalURL is
https://harbor.nopega.net, so the registry redirects clients there regardless
of how they reached it. This is for looking at the UI only.

Ctrl-C to stop.
EOF
    kubectl port-forward -n "$NAMESPACE" svc/harbor 18081:80
    exit 0
    ;;

  logs)
    kubectl logs -n "$NAMESPACE" -l app=harbor --tail=60 --prefix \
      --max-log-requests=10 -f
    exit 0
    ;;

  uninstall)
    helm uninstall "$RELEASE" -n "$NAMESPACE" || true
    cat <<EOF

Release removed. Two things deliberately survive:

  PVCs   -- persistence.resourcePolicy is "keep", so the Postgres volume with
            every project, robot account and scan result is still there. A
            reinstall picks up where this left off.
            Remove them only if that is genuinely the intent:
              kubectl delete pvc -n ${NAMESPACE} --all

  S3     -- s3://${REGISTRY_BUCKET} still holds every image layer. Nothing in
            this script touches it.
EOF
    exit 0
    ;;

  verify)
    echo "=== release ==="
    helm status "$RELEASE" -n "$NAMESPACE" --output json 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); i=d['info']; print(' ', d['name'], i['status'], 'rev', d['version'])" \
      2>/dev/null || echo "  not installed"
    echo ""
    echo "=== pods ==="
    kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || echo "  none"
    echo ""
    echo "=== PVCs (all should be Bound -- Pending means no StorageClass) ==="
    kubectl get pvc -n "$NAMESPACE" 2>/dev/null || echo "  none"
    echo ""
    echo "=== does the registry pod actually hold the S3 key? ==="
    # The pod can be Running with no credential at all: the Secret is mounted
    # by name, and a missing or misnamed one produces an empty variable rather
    # than a failed start. The push then fails with
    # "NoCredentialProviders: no valid providers in chain", which says nothing
    # about which secret was expected.
    #
    # Only the ACCESSKEY is printed. The secret half stays unprinted on
    # purpose -- a verify command should be safe to paste into a chat.
    REG_POD="$(kubectl get pods -n "$NAMESPACE" -l component=registry \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -n "$REG_POD" ]; then
      echo "  pod: ${REG_POD}"
      kubectl exec -n "$NAMESPACE" "$REG_POD" -c registry -- env 2>/dev/null \
        | grep -E '^REGISTRY_STORAGE_S3_ACCESSKEY=' \
        || echo "  NO S3 KEY IN THE POD -- check that secret ${K8S_S3_SECRET} exists"
      kubectl exec -n "$NAMESPACE" "$REG_POD" -c registry -- sh -c \
        '[ -n "$REGISTRY_STORAGE_S3_SECRETKEY" ] && echo "  secret half: present" || echo "  secret half: EMPTY"' \
        2>/dev/null || true
    else
      echo "  no registry pod"
    fi
    echo ""
    echo "=== has anything reached the bucket yet? ==="
    aws s3 ls "s3://${REGISTRY_BUCKET}/" --recursive --region "$REGION" 2>/dev/null \
      | head -5 || echo "  empty (expected until the first push)"
    echo ""
    echo "=== reachability ==="
    echo "  https://harbor.nopega.net -- requires the Public Hostname mapping in"
    echo "  Cloudflare:  harbor  ->  HTTP  ->  harbor.harbor.svc.cluster.local:80"
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# Preflight. Each of these produces a confusing failure much later if missed.
# ---------------------------------------------------------------------------
echo "[1/6] Preflight..."

[ -d "$CHART_PATH" ] || {
  echo "ERROR: chart not found at ${CHART_PATH}" >&2
  echo "       Vendor it first:" >&2
  echo "         helm repo add harbor https://helm.goharbor.io" >&2
  echo "         helm repo update" >&2
  echo "         helm pull harbor/harbor --version ${CHART_VERSION} --untar --untardir \"$SCRIPT_DIR/chart\"" >&2
  exit 1
}

# Confirm the vendored chart is the version this file was written against. A
# silently newer chart is how a values key gets ignored without any error.
ACTUAL_VERSION="$(python3 -c "
import yaml
print(yaml.safe_load(open('${CHART_PATH}/Chart.yaml'))['version'])
" 2>/dev/null || echo unknown)"
if [ "$ACTUAL_VERSION" != "$CHART_VERSION" ]; then
  echo "      WARNING: vendored chart is ${ACTUAL_VERSION}, this script expects ${CHART_VERSION}."
  echo "               Check the CHANGED lines in chart/harbor/values.yaml still"
  echo "               match this chart's value names."
else
  echo "      chart ${CHART_VERSION} present"
fi

# Secrets. All three are referenced by chart/harbor/values.yaml; a missing one makes
# helm render a reference to a Secret that does not exist, and the pod sits in
# CreateContainerConfigError, which does not mention the secret's name.
MISSING=""
for s in "$K8S_S3_SECRET" harbor-admin-password harbor-secret-key harbor-database-password; do
  kubectl get secret "$s" -n "$NAMESPACE" >/dev/null 2>&1 || MISSING="$MISSING $s"
done
if [ -n "$MISSING" ]; then
  echo "ERROR: missing Kubernetes secret(s):${MISSING}" >&2
  echo "       Run ./01_create_harbor_secrets_prod.sh first." >&2
  exit 1
fi
echo "      all four secrets present"

# The two key names inside the S3 secret are dictated by the chart. A secret
# that exists with the wrong key names passes the check above and then mounts
# empty variables, which fails at first push rather than at install.
for k in REGISTRY_STORAGE_S3_ACCESSKEY REGISTRY_STORAGE_S3_SECRETKEY; do
  kubectl get secret "$K8S_S3_SECRET" -n "$NAMESPACE" \
    -o jsonpath="{.data.$k}" 2>/dev/null | grep -q . || {
    echo "ERROR: secret ${K8S_S3_SECRET} has no key '${k}'." >&2
    echo "       The chart reads exactly this name. Re-run" >&2
    echo "       ./01_create_harbor_secrets_prod.sh." >&2
    exit 1
  }
done
echo "      ${K8S_S3_SECRET} has both keys the chart expects"

# A default StorageClass. Harbor requests four PVCs; with no class they stay
# Pending and the pods report an unbound-PVC scheduling error that reads like
# a capacity problem.
DEFAULT_SC="$(kubectl get storageclass -o json 2>/dev/null | python3 -c "
import json,sys
for i in json.load(sys.stdin).get('items',[]):
    a=i['metadata'].get('annotations',{}) or {}
    if a.get('storageclass.kubernetes.io/is-default-class')=='true':
        print(i['metadata']['name'])
" || true)"
if [ -z "$DEFAULT_SC" ]; then
  echo "ERROR: no default StorageClass in this cluster." >&2
  echo "       Harbor needs four PersistentVolumeClaims; without one they will" >&2
  echo "       all stay Pending. Run:" >&2
  echo "         ../../../set_up_cluster/05_storageclass_prod/05_create_storageclass_prod.sh" >&2
  exit 1
fi
echo "      default StorageClass: ${DEFAULT_SC}"

# Capacity. Harbor is eight pods requesting roughly 900m CPU and 2.1Gi memory
# in total, all pinned to workload=critical.
CRITICAL_NODES="$(kubectl get nodes -l workload=critical --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "$CRITICAL_NODES" -eq 0 ]; then
  echo "ERROR: no node labelled workload=critical." >&2
  exit 1
elif [ "$CRITICAL_NODES" -lt 3 ]; then
  cat <<EOF
      WARNING: only ${CRITICAL_NODES} node(s) labelled workload=critical.

      Harbor adds ~900m CPU / ~2.1Gi of requests on top of Polaris, Trino,
      Airflow and cloudflared. The node count was raised to 3 specifically to
      absorb this. With fewer, expect some Harbor pods to sit Pending on
      Insufficient cpu.

        script/scale/scale_up.sh
EOF
else
  echo "      ${CRITICAL_NODES} critical nodes"
fi

# ---------------------------------------------------------------------------
if [ "$MODE" = "diff" ]; then
  echo "[2/6] Rendering manifests (nothing is applied)..."
  helm template "$RELEASE" "$CHART_PATH" -n "$NAMESPACE"
  exit 0
fi

echo "[2/6] Fetching the database password..."
# chart/harbor/values.yaml deliberately leaves database.internal.password empty.
# Chart 1.19.1 offers no `existingSecret` for it -- only a literal password
# whose default is "changeit" -- so committing the real one would put a live
# credential in git. It is injected here instead. --set-file, not --set: a --set
# value appears in the process list for anyone running `ps` on this machine.
DB_PASS_FILE="$(mktemp)"
trap 'rm -f "$DB_PASS_FILE"' EXIT
aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id data-platform-prod-harbor-database-password \
  --query SecretString --output text 2>/dev/null | tr -d '\n' > "$DB_PASS_FILE" || true
if [ ! -s "$DB_PASS_FILE" ]; then
  echo "ERROR: could not read data-platform-prod-harbor-database-password." >&2
  echo "       Run ./01_create_harbor_secrets_prod.sh first." >&2
  exit 1
fi
echo "      read from Secrets Manager ($(wc -c < "$DB_PASS_FILE" | tr -d ' ') chars)"

echo "[3/6] Installing..."
# --wait, and no Helm-hook concerns here: unlike the Airflow chart, Harbor has
# no post-install hook that other resources block on, so waiting cannot
# deadlock. The 15m timeout is generous because Trivy downloads its
# vulnerability database on first start.
helm upgrade --install "$RELEASE" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set-file database.internal.password="$DB_PASS_FILE" \
  --wait --timeout 15m

echo "[4/6] Pods..."
kubectl get pods -n "$NAMESPACE" -o wide

echo "[5/6] PVCs..."
kubectl get pvc -n "$NAMESPACE"

echo "[6/6] Checking the registry can actually see S3..."
REG_POD="$(kubectl get pods -n "$NAMESPACE" -l component=registry \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -n "$REG_POD" ]; then
  if kubectl exec -n "$NAMESPACE" "$REG_POD" -c registry -- env 2>/dev/null \
     | grep -q '^AWS_WEB_IDENTITY_TOKEN_FILE='; then
    echo "      IRSA token is mounted into ${REG_POD}"
  else
    echo "      WARNING: no AWS_WEB_IDENTITY_TOKEN_FILE in the registry pod."
    echo "               Pushes will fail with 403. Usually means the pod started"
    echo "               before the ServiceAccount was annotated:"
    echo "                 kubectl rollout restart deployment/harbor-registry -n ${NAMESPACE}"
  fi
fi

cat <<EOF

Harbor is running, but not yet reachable from outside.

1. Map the hostname in Cloudflare
   Networks -> Tunnels -> aws-tunnel -> Public Hostname -> Add

     Subdomain : harbor
     Domain    : nopega.net
     Type      : HTTP
     URL       : harbor.harbor.svc.cluster.local:80

2. Do NOT put Cloudflare Access in front of it

   Access challenges requests with an interactive login. Docker and containerd
   cannot answer that, so 'docker login harbor.nopega.net' would fail with an
   HTML page where it expects a token. Harbor has its own authentication and
   robot accounts -- that is the layer to rely on here.

   This is the one hostname on the tunnel that is deliberately left without
   Access. If that trade is unacceptable, the alternative is to keep Harbor
   off the tunnel entirely and push to it only from inside the cluster.

3. Log in and create the project the Spark image will live in

     ./01_create_harbor_secrets_prod.sh show-admin
     docker login harbor.nopega.net

   Then in the UI: Projects -> New Project -> name 'platform', private,
   and enable "Prevent vulnerable images from running" with severity High.

Verify:

  ./02_install_harbor_prod.sh verify
EOF
