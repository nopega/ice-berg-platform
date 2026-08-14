#!/usr/bin/env bash
#
# 01_create_harbor_secrets_prod.sh
#
# Creates the harbor namespace and every secret the chart needs, including the
# S3 access key the registry authenticates with.
#
# WHY AN ACCESS KEY AND NOT IRSA: see the header of
# 00_create_harbor_bucket_and_iam_prod.sh. Short version -- the S3 driver in
# the distribution release Harbor 2.15.1 bundles has a hardcoded credential
# chain with no web-identity provider in it, so an IRSA token is projected
# into the pod and then ignored.
#
# WHAT THE SECRETS ARE, AND WHY NONE IS OPTIONAL
# ------------------------------------------------
#   s3 access key   -- the registry's only way to reach the bucket. Created
#                      here rather than in 00_ because AWS returns the secret
#                      half exactly once, at creation: it has to go straight
#                      into Secrets Manager without being printed.
#
#   admin password  -- the chart's default is the literal string
#                      "Harbor12345", published in its own documentation. A
#                      registry reachable on the internet with a documented
#                      default password is not a hypothetical risk.
#
#   secretKey       -- a 16-character key Harbor uses to encrypt stored
#                      credentials (robot account tokens, replication
#                      endpoints). If the chart generates it, `helm upgrade`
#                      generates a *different* one, and every previously
#                      encrypted value becomes undecryptable. The symptom is
#                      robot accounts silently failing to authenticate after
#                      an unrelated upgrade. Pinning it here removes that
#                      failure mode entirely.
#
# Both live in AWS Secrets Manager as the source of truth and are mirrored into
# Kubernetes, so re-creating the cluster does not rotate them.
#
# Usage:
#   ./01_create_harbor_secrets_prod.sh              # create (idempotent)
#   ./01_create_harbor_secrets_prod.sh verify       # report state
#   ./01_create_harbor_secrets_prod.sh show-admin   # print the admin password
#   ./01_create_harbor_secrets_prod.sh rotate-admin # new admin password
#   ./01_create_harbor_secrets_prod.sh rotate-s3    # new S3 access key
#
set -euo pipefail

REGION="ap-southeast-1"
NAMESPACE="harbor"
IAM_USER="data-platform-prod-harbor-registry"
SM_S3KEY="data-platform-prod-harbor-registry-s3-key"
K8S_S3_SECRET="harbor-registry-s3"
SM_ADMIN="data-platform-prod-harbor-admin-password"
SM_SECRETKEY="data-platform-prod-harbor-secret-key"
SM_DBPASS="data-platform-prod-harbor-database-password"
K8S_ADMIN_SECRET="harbor-admin-password"
K8S_SECRETKEY_SECRET="harbor-secret-key"
K8S_DBPASS_SECRET="harbor-database-password"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need kubectl; need aws; need openssl; need python3

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# Handles all three states a Secrets Manager secret can be in: absent, present,
# and scheduled-for-deletion. The third blocks both create-secret AND
# put-secret-value with "marked for deletion", which is not obvious from either
# error, so it is checked explicitly rather than discovered.
store_sm_secret() {
  local name="$1" value="$2" desc="$3" deleted
  deleted="$(aws secretsmanager describe-secret --region "$REGION" \
    --secret-id "$name" --query 'DeletedDate' --output text 2>/dev/null || echo NONE)"
  if [ "$deleted" != "NONE" ] && [ "$deleted" != "None" ] && [ -n "$deleted" ]; then
    echo "      ${name} was scheduled for deletion -- restoring"
    aws secretsmanager restore-secret --region "$REGION" --secret-id "$name" >/dev/null
  fi
  if aws secretsmanager describe-secret --region "$REGION" --secret-id "$name" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --region "$REGION" \
      --secret-id "$name" --secret-string "$value" >/dev/null
  else
    aws secretsmanager create-secret --region "$REGION" \
      --name "$name" --description "$desc" --secret-string "$value" >/dev/null
  fi
}

# Reads an existing value, or generates and stores one. Generating only when
# absent is what makes re-running this script safe: a second run must not
# invalidate the key that already encrypted things.
get_or_create_sm_secret() {
  local name="$1" generator="$2" desc="$3" deleted existing
  deleted="$(aws secretsmanager describe-secret --region "$REGION" \
    --secret-id "$name" --query 'DeletedDate' --output text 2>/dev/null || echo NONE)"
  if [ "$deleted" != "NONE" ] && [ "$deleted" != "None" ] && [ -n "$deleted" ]; then
    aws secretsmanager restore-secret --region "$REGION" --secret-id "$name" >/dev/null
  fi
  existing="$(aws secretsmanager get-secret-value --region "$REGION" \
    --secret-id "$name" --query SecretString --output text 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "None" ]; then
    printf '%s' "$existing"
    return
  fi
  local generated
  generated="$(eval "$generator")"
  store_sm_secret "$name" "$generated" "$desc"
  printf '%s' "$generated"
}

case "$MODE" in
  verify)
    echo "=== namespace ==="
    kubectl get namespace "$NAMESPACE" 2>/dev/null || echo "  not created"
    echo ""
    echo "=== s3 access key ==="
    # Compare the key ID in Kubernetes against the ones IAM knows about. They
    # drift when a key is rotated in one place only, and the symptom is an
    # InvalidAccessKeyId on push that looks like a permissions problem.
    K8S_KEY_ID="$(kubectl get secret "$K8S_S3_SECRET" -n "$NAMESPACE" \
      -o jsonpath='{.data.REGISTRY_STORAGE_S3_ACCESSKEY}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    echo "  in kubernetes: ${K8S_KEY_ID:-MISSING}"
    echo "  in iam:        $(aws iam list-access-keys --user-name "$IAM_USER" \
                              --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || echo 'none')"
    echo ""
    echo "=== kubernetes secrets ==="
    for s in "$K8S_S3_SECRET" "$K8S_ADMIN_SECRET" "$K8S_SECRETKEY_SECRET" "$K8S_DBPASS_SECRET"; do
      if kubectl get secret "$s" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "  ${s}: present"
      else
        echo "  ${s}: MISSING"
      fi
    done
    echo ""
    echo "=== secrets manager ==="
    for s in "$SM_S3KEY" "$SM_ADMIN" "$SM_SECRETKEY" "$SM_DBPASS"; do
      aws secretsmanager describe-secret --region "$REGION" --secret-id "$s" \
        --query '[Name,DeletedDate]' --output text 2>/dev/null || echo "  ${s}: absent"
    done
    exit 0
    ;;

  show-admin)
    echo "user:     admin"
    printf 'password: '
    aws secretsmanager get-secret-value --region "$REGION" \
      --secret-id "$SM_ADMIN" --query SecretString --output text
    exit 0
    ;;

  rotate-admin)
    # Rotating the admin password does NOT touch secretKey. They are separate
    # on purpose: one is a login credential and safe to change at any time, the
    # other is an encryption key and changing it destroys stored data.
    NEW_PW="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)Aa1"
    store_sm_secret "$SM_ADMIN" "$NEW_PW" "Harbor admin password"
    kubectl create secret generic "$K8S_ADMIN_SECRET" -n "$NAMESPACE" \
      --from-literal=HARBOR_ADMIN_PASSWORD="$NEW_PW" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    cat <<EOF
Stored. Kubernetes and Secrets Manager now agree, but Harbor itself does not:
the running core pod read the old value at startup.

  kubectl rollout restart deployment/harbor-core -n ${NAMESPACE}

Note that Harbor treats the admin password as authoritative only on FIRST
start. Once the database exists, this variable is ignored and the password
must be changed in the UI. Rotating here keeps the record accurate for a
rebuild; it does not change a running instance.
EOF
    exit 0
    ;;

  rotate-s3)
    # Order matters. Create the new key FIRST, then delete the old ones: doing
    # it the other way round leaves the running registry holding a key that no
    # longer exists, and every pull fails until the new one is deployed.
    echo "Creating a new access key..."
    NEW_JSON="$(aws iam create-access-key --user-name "$IAM_USER" \
      --query 'AccessKey.{AccessKeyId:AccessKeyId,SecretAccessKey:SecretAccessKey}' \
      --output json)"
    NEW_ID="$(printf '%s' "$NEW_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['AccessKeyId'])")"
    NEW_SECRET="$(printf '%s' "$NEW_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['SecretAccessKey'])")"
    store_sm_secret "$SM_S3KEY" "$NEW_JSON" "Harbor registry S3 access key"
    kubectl create secret generic "$K8S_S3_SECRET" -n "$NAMESPACE" \
      --from-literal=REGISTRY_STORAGE_S3_ACCESSKEY="$NEW_ID" \
      --from-literal=REGISTRY_STORAGE_S3_SECRETKEY="$NEW_SECRET" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    echo "      new key ${NEW_ID} stored"
    cat <<EOF

Roll it out BEFORE deleting the old key -- the registry still holds the old
one in memory until it restarts:

  kubectl rollout restart deployment/harbor-registry -n ${NAMESPACE}
  kubectl rollout status  deployment/harbor-registry -n ${NAMESPACE}

Then confirm a push works, and only then remove the superseded keys:

  ./01_create_harbor_secrets_prod.sh verify     # lists every key IAM knows
  aws iam delete-access-key --user-name ${IAM_USER} --access-key-id <old-id>

IAM allows a maximum of two keys per user, so an abandoned rotation blocks the
next one. 'verify' reports the count for exactly that reason.
EOF
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
echo "[1/5] Namespace..."
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE" >/dev/null
echo "      ${NAMESPACE}"

echo "[2/5] S3 access key for the registry..."
aws iam get-user --user-name "$IAM_USER" >/dev/null 2>&1 || {
  echo "ERROR: IAM user ${IAM_USER} does not exist." >&2
  echo "       Run ./00_create_harbor_bucket_and_iam_prod.sh first." >&2
  exit 1
}

# IAM caps a user at two access keys. Creating one when two already exist fails
# with LimitExceeded, which reads like a quota problem rather than what it is:
# a rotation nobody finished.
KEY_COUNT="$(aws iam list-access-keys --user-name "$IAM_USER" \
  --query 'length(AccessKeyMetadata)' --output text)"
if [ "$KEY_COUNT" -ge 2 ]; then
  echo "      WARNING: ${IAM_USER} already has ${KEY_COUNT} access keys."
  echo "               Finish the rotation before creating another --"
  echo "               ./01_create_harbor_secrets_prod.sh verify"
fi

S3_KEY_JSON="$(get_or_create_sm_secret "$SM_S3KEY" \
  "aws iam create-access-key --user-name '${IAM_USER}' --query 'AccessKey.{AccessKeyId:AccessKeyId,SecretAccessKey:SecretAccessKey}' --output json" \
  "Harbor registry S3 access key -- the registry's only credential for s3://data-store-prod-registry")"
S3_KEY_ID="$(printf '%s' "$S3_KEY_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['AccessKeyId'])")"
S3_KEY_SECRET="$(printf '%s' "$S3_KEY_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['SecretAccessKey'])")"

# Secrets Manager can hold a key that IAM no longer has -- someone deletes it
# in the console, and nothing here notices until a push fails with
# InvalidAccessKeyId, which reads like a typo rather than a deleted credential.
aws iam list-access-keys --user-name "$IAM_USER" \
  --query 'AccessKeyMetadata[].AccessKeyId' --output text | tr '\t' '\n' \
  | grep -qx "$S3_KEY_ID" || {
  echo "ERROR: key ${S3_KEY_ID} is in Secrets Manager but IAM does not have it." >&2
  echo "       It was deleted outside this script. Issue a new one:" >&2
  echo "         ./01_create_harbor_secrets_prod.sh rotate-s3" >&2
  exit 1
}

# The two key names are dictated by the Harbor chart, not chosen here --
# see imageChartStorage.s3.existingSecret in chart/harbor/values.yaml. A
# secret with different key names is mounted successfully and ignored.
kubectl create secret generic "$K8S_S3_SECRET" -n "$NAMESPACE" \
  --from-literal=REGISTRY_STORAGE_S3_ACCESSKEY="$S3_KEY_ID" \
  --from-literal=REGISTRY_STORAGE_S3_SECRETKEY="$S3_KEY_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "      ${S3_KEY_ID} (secret half never printed)"

echo "[3/5] Admin password..."
# Harbor rejects passwords without an uppercase letter, a lowercase letter and
# a digit, and does so at first login rather than at install -- so a password
# that fails the rule produces a working deployment nobody can log into. The
# 'Aa1' suffix makes the rule structurally impossible to violate.
ADMIN_PW="$(get_or_create_sm_secret "$SM_ADMIN" \
  "openssl rand -base64 24 | tr -d '/+=' | cut -c1-20 | sed 's/\$/Aa1/'" \
  "Harbor admin password")"
kubectl create secret generic "$K8S_ADMIN_SECRET" -n "$NAMESPACE" \
  --from-literal=HARBOR_ADMIN_PASSWORD="$ADMIN_PW" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "      stored (read it with: ./01_create_harbor_secrets_prod.sh show-admin)"

echo "[4/5] secretKey..."
# Exactly 16 characters -- Harbor uses it as an AES-128 key and refuses to
# start with anything else, reporting only "invalid secret key length".
SECRET_KEY="$(get_or_create_sm_secret "$SM_SECRETKEY" \
  "openssl rand -hex 8" \
  "Harbor secretKey -- encrypts stored credentials. Changing it makes existing encrypted values unreadable.")"
if [ "${#SECRET_KEY}" -ne 16 ]; then
  echo "ERROR: secretKey is ${#SECRET_KEY} characters, must be exactly 16." >&2
  exit 1
fi
kubectl create secret generic "$K8S_SECRETKEY_SECRET" -n "$NAMESPACE" \
  --from-literal=secretKey="$SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "      stored (16 chars, pinned -- never regenerated by helm upgrade)"

echo "[5/5] Internal Postgres password..."
# The chart's default is the literal string "changeit". The database is only
# reachable inside the cluster, so this is not the most urgent credential on
# the platform -- but a default password on a database holding every project
# definition and scan result is the kind of thing that is trivial to fix now
# and awkward to explain later.
#
# Alphanumeric only: this value ends up inside a Postgres connection URI, and
# a '/' or '@' in a password silently truncates the URI rather than failing.
DB_PASS="$(get_or_create_sm_secret "$SM_DBPASS" \
  "openssl rand -hex 20" \
  "Harbor internal Postgres password")"
# Key name is fixed by the chart -- it reads .data.password from this secret.
kubectl create secret generic "$K8S_DBPASS_SECRET" -n "$NAMESPACE" \
  --from-literal=password="$DB_PASS" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "      stored"

cat <<EOF

Namespace, ServiceAccount and all three secrets are in place.

  ./02_install_harbor_prod.sh

One thing worth knowing before the install: the admin password is only read on
FIRST start, when Harbor initialises an empty database. After that the value in
the secret is ignored and the password lives in Postgres. Changing it later
means the UI, not this script.
EOF
