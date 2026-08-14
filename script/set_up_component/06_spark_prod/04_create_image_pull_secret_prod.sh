#!/usr/bin/env bash
#
# 04_create_image_pull_secret_prod.sh
#
# Gives the `spark` namespace credentials to pull from Harbor.
#
# WHY THIS IS NEEDED AT ALL
# --------------------------
# The `ice-berg-platform` project is Private, which is the right choice -- a
# public project means anyone who can reach harbor.nopega.net can enumerate and
# download the platform's images. The cost of that choice is that Kubernetes
# needs a credential, and a missing one does not fail loudly: the driver pod is
# created, sits in ImagePullBackOff, and the SparkApplication reports SUBMITTED
# forever. Nothing in `kubectl get sparkapplication` mentions the registry.
#
# WHY A ROBOT ACCOUNT AND NOT THE ADMIN PASSWORD
# ------------------------------------------------
# Using admin here would work in one command, and would put a credential that
# can delete every project and every image into a Secret readable by anything
# that can exec into a Spark pod. The robot created here can do exactly one
# thing: pull from one project. It cannot push, cannot delete, cannot log into
# the UI, and revoking it breaks nothing except image pulls.
#
# The robot's secret, like an AWS access key, is returned by the API exactly
# once. It goes straight into Secrets Manager and into the K8s Secret without
# being printed.
#
# Usage:
#   ./04_create_image_pull_secret_prod.sh          # create (idempotent)
#   ./04_create_image_pull_secret_prod.sh verify   # can the namespace pull?
#   ./04_create_image_pull_secret_prod.sh rotate   # new robot secret
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="ap-southeast-1"
NAMESPACE="spark"
REGISTRY="harbor.nopega.net"
HARBOR_PROJECT="ice-berg-platform"
ROBOT_SHORT="spark-puller"
K8S_SECRET="harbor-pull"
SM_ROBOT="data-platform-prod-harbor-robot-spark-puller"
SM_ADMIN="data-platform-prod-harbor-admin-password"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need kubectl; need aws; need curl; need python3

if [ "$MODE" = "verify" ]; then
  echo "=== secret ==="
  kubectl get secret "$K8S_SECRET" -n "$NAMESPACE" 2>/dev/null || echo "  not created"
  echo ""
  echo "=== which registry does it cover ==="
  # A dockerconfigjson naming a different host than the image does is mounted
  # without complaint and simply never used. Print the hosts it actually holds.
  kubectl get secret "$K8S_SECRET" -n "$NAMESPACE" \
    -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d 2>/dev/null \
    | python3 -c "import json,sys; print(' ', ', '.join(json.load(sys.stdin).get('auths',{}).keys()))" \
    2>/dev/null || echo "  unreadable"
  echo ""
  echo "=== robots Harbor knows about ==="
  ADMIN_PW="$(aws secretsmanager get-secret-value --region "$REGION" \
    --secret-id "$SM_ADMIN" --query SecretString --output text 2>/dev/null || true)"
  if [ -n "$ADMIN_PW" ]; then
    curl -fsS -u "admin:${ADMIN_PW}" "https://${REGISTRY}/api/v2.0/robots" 2>/dev/null \
      | python3 -c "
import json,sys
for r in json.load(sys.stdin) or []:
    print('  ', r['name'], '| disabled:', r.get('disable'), '| expires:', r.get('expires_at'))
" 2>/dev/null || echo "  could not query Harbor"
  else
    echo "  no admin password in Secrets Manager"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
echo "[1/4] Preflight..."
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || {
  echo "ERROR: namespace '${NAMESPACE}' does not exist." >&2
  echo "       Run ./01_create_namespace_and_sa_prod.sh first." >&2
  exit 1
}

ADMIN_PW="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$SM_ADMIN" --query SecretString --output text 2>/dev/null || true)"
[ -n "$ADMIN_PW" ] || {
  echo "ERROR: Harbor admin password not found in Secrets Manager." >&2
  echo "       ../05_harbor_prod/01_create_harbor_secrets_prod.sh creates it." >&2
  exit 1
}

# Fail here rather than at robot creation. Creating a robot scoped to a project
# that does not exist returns 404 with an empty body, which reads like the API
# itself is wrong.
curl -fsS -u "admin:${ADMIN_PW}" \
  "https://${REGISTRY}/api/v2.0/projects/${HARBOR_PROJECT}" >/dev/null 2>&1 || {
  echo "ERROR: Harbor project '${HARBOR_PROJECT}' does not exist, or the admin" >&2
  echo "       password is wrong. Create the project in the UI first." >&2
  exit 1
}
echo "      project ${HARBOR_PROJECT} reachable"

# ---------------------------------------------------------------------------
echo "[2/4] Robot account..."

restore_if_deleted() {
  local name="$1" deleted
  deleted="$(aws secretsmanager describe-secret --region "$REGION" \
    --secret-id "$name" --query 'DeletedDate' --output text 2>/dev/null || echo NONE)"
  if [ "$deleted" != "NONE" ] && [ "$deleted" != "None" ] && [ -n "$deleted" ]; then
    aws secretsmanager restore-secret --region "$REGION" --secret-id "$name" >/dev/null
  fi
}

create_robot() {
  # duration -1 = never expires. A robot that expires silently turns every
  # Spark job into ImagePullBackOff on a date nobody wrote down; rotation is
  # better handled deliberately, via `rotate`, than by a hidden clock.
  #
  # One permission, pull only. Push is what the CI credential does, and this
  # is not it.
  curl -fsS -u "admin:${ADMIN_PW}" -X POST \
    -H "Content-Type: application/json" \
    "https://${REGISTRY}/api/v2.0/robots" \
    -d "{
      \"name\": \"${ROBOT_SHORT}\",
      \"description\": \"Pulls platform images into the spark namespace\",
      \"duration\": -1,
      \"level\": \"project\",
      \"permissions\": [{
        \"kind\": \"project\",
        \"namespace\": \"${HARBOR_PROJECT}\",
        \"access\": [{ \"resource\": \"repository\", \"action\": \"pull\" }]
      }]
    }"
}

restore_if_deleted "$SM_ROBOT"
EXISTING="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$SM_ROBOT" --query SecretString --output text 2>/dev/null || true)"

if [ "$MODE" = "rotate" ] || [ -z "$EXISTING" ] || [ "$EXISTING" = "None" ]; then
  if [ "$MODE" = "rotate" ]; then
    # Harbor refuses to create a second robot with the same name, so the old
    # one has to go first. Between these two calls the namespace cannot pull;
    # that is acceptable for a rotate but not for a first install, which is
    # why this branch is not taken when the secret already exists.
    OLD_ID="$(curl -fsS -u "admin:${ADMIN_PW}" "https://${REGISTRY}/api/v2.0/robots" \
      | python3 -c "
import json,sys
want='robot\$${HARBOR_PROJECT}+${ROBOT_SHORT}'
print(next((str(r['id']) for r in (json.load(sys.stdin) or []) if r['name']==want), ''))
")"
    [ -n "$OLD_ID" ] && curl -fsS -u "admin:${ADMIN_PW}" -X DELETE \
      "https://${REGISTRY}/api/v2.0/robots/${OLD_ID}" >/dev/null
  fi

  ROBOT_JSON="$(create_robot)"
  ROBOT_NAME="$(printf '%s' "$ROBOT_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")"
  ROBOT_SECRET="$(printf '%s' "$ROBOT_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['secret'])")"

  STORED="$(python3 -c "
import json,sys
print(json.dumps({'name': sys.argv[1], 'secret': sys.argv[2]}))
" "$ROBOT_NAME" "$ROBOT_SECRET")"

  if aws secretsmanager describe-secret --region "$REGION" --secret-id "$SM_ROBOT" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --region "$REGION" \
      --secret-id "$SM_ROBOT" --secret-string "$STORED" >/dev/null
  else
    aws secretsmanager create-secret --region "$REGION" --name "$SM_ROBOT" \
      --description "Harbor robot that pulls ${HARBOR_PROJECT} images into the spark namespace" \
      --secret-string "$STORED" >/dev/null
  fi
  echo "      created ${ROBOT_NAME}"
else
  ROBOT_NAME="$(printf '%s' "$EXISTING" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")"
  ROBOT_SECRET="$(printf '%s' "$EXISTING" | python3 -c "import json,sys; print(json.load(sys.stdin)['secret'])")"
  echo "      reusing ${ROBOT_NAME}"
fi

# ---------------------------------------------------------------------------
echo "[3/4] Kubernetes pull secret..."
# --docker-server must be the bare host, with no scheme and no path. With
# https:// in front, the kubelet stores it under a key that never matches the
# image reference and falls back to anonymous, which on a private project is
# an authentication error rather than a configuration one.
kubectl create secret docker-registry "$K8S_SECRET" -n "$NAMESPACE" \
  --docker-server="$REGISTRY" \
  --docker-username="$ROBOT_NAME" \
  --docker-password="$ROBOT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "      ${NAMESPACE}/${K8S_SECRET} -> ${REGISTRY}"

# ---------------------------------------------------------------------------
echo "[4/4] Proving the credential actually pulls..."
# `kubectl create secret` validates nothing -- a wrong password produces a
# perfectly well-formed Secret. The only real test is making the kubelet use
# it, so this runs a throwaway pod that does nothing but pull the image.
TEST_POD="harbor-pull-test-$$"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_POD}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  imagePullSecrets:
    - name: ${K8S_SECRET}
  nodeSelector:
    workload: critical
  containers:
    - name: probe
      image: ${REGISTRY}/${HARBOR_PROJECT}/datapipeline:v1.0.0
      command: ["true"]
EOF

cleanup() { kubectl delete pod "$TEST_POD" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

# The image is ~1.5 GB, so allow for a cold pull on a node that has never seen
# it. A pull failure shows up long before the timeout.
DEADLINE=$(( $(date +%s) + 420 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  PHASE="$(kubectl get pod "$TEST_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  REASON="$(kubectl get pod "$TEST_POD" -n "$NAMESPACE" \
    -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
  case "$REASON" in
    ImagePullBackOff|ErrImagePull)
      echo "ERROR: the pull failed. Message from the kubelet:" >&2
      kubectl get events -n "$NAMESPACE" --field-selector "involvedObject.name=${TEST_POD}" \
        -o custom-columns=REASON:.reason,MESSAGE:.message --no-headers >&2 || true
      exit 1
      ;;
  esac
  [ "$PHASE" = "Succeeded" ] && break
  sleep 5
done

[ "$PHASE" = "Succeeded" ] || {
  echo "ERROR: the probe pod never completed (last phase: ${PHASE:-unknown})." >&2
  exit 1
}
echo "      pulled ${REGISTRY}/${HARBOR_PROJECT}/datapipeline:v1.0.0 successfully"

cat <<EOF

The spark namespace can pull from Harbor.

Every SparkApplication must reference this secret explicitly -- it is not
namespace-wide. 06_smoke_test.yaml already does:

  spec:
    imagePullSecrets:
      - ${K8S_SECRET}

Attaching it to the 'spark' ServiceAccount instead would make it implicit for
every pod in the namespace, which is more convenient and hides the dependency.
Keeping it in the SparkApplication means a job's image source is readable from
the job's own definition.
EOF
