#!/usr/bin/env bash
#
# 03_bootstrap_polaris_realm_prod.sh
#
# Polaris needs its JDBC schema created and a root principal (client
# id/secret) registered before the server will start successfully — this is
# a one-time operation per realm, done with the apache/polaris-admin-tool
# image (see: https://polaris.apache.org/.../helm-chart/production/#bootstrapping-realms).
#
# The root client id/secret generated here are how you (or later, Trino/
# Spark setup scripts) authenticate to Polaris's management API to create
# catalogs, principal roles, and grants. They are stored in Secrets Manager,
# never printed in full, and re-used (not regenerated) on re-run.
#
# Usage:
#   ./03_bootstrap_polaris_realm_prod.sh          # bootstrap (skips if already done)
#   ./03_bootstrap_polaris_realm_prod.sh verify   # check status only
#
set -euo pipefail

REGION="ap-southeast-1"
NAMESPACE="data-platform"
REALM="data-platform-prod"
SECRETS_MANAGER_SECRET="data-platform-prod-polaris-root-credentials"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws
need kubectl

echo "== Polaris realm bootstrap ($MODE) ================================"

if [ "$MODE" = "verify" ]; then
  aws secretsmanager describe-secret --secret-id "$SECRETS_MANAGER_SECRET" --region "$REGION" \
    --query '{Name:Name,LastChanged:LastChangedDate}' --output table 2>/dev/null \
    || echo "  (not bootstrapped yet)"
  exit 0
fi

if aws secretsmanager describe-secret --secret-id "$SECRETS_MANAGER_SECRET" --region "$REGION" >/dev/null 2>&1; then
  echo "Already bootstrapped (found existing secret '$SECRETS_MANAGER_SECRET'). Skipping."
  echo "If you need to re-bootstrap from scratch, delete that secret first and re-run."
  exit 0
fi

kubectl get secret polaris-persistence -n "$NAMESPACE" >/dev/null 2>&1 \
  || { echo "ERROR: k8s secret 'polaris-persistence' not found. Run 02_create_persistence_secret_prod.sh first." >&2; exit 1; }

echo "[1/2] Generating root credentials..."
ROOT_CLIENT_ID="root"
ROOT_CLIENT_SECRET="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)"

echo "[2/2] Running bootstrap job (apache/polaris-admin-tool)..."

# The database credentials are handed to the pod by REFERENCE, not by value.
#
# The obvious way to write this is what the upstream docs show:
#
#   --env="quarkus.datasource.password=$(kubectl get secret ... | base64 -d)"
#
# but that has two leaks. The local shell expands $(...) before invoking
# kubectl, so the password becomes a literal command-line argument -- visible
# in `ps` on this machine while the command runs. And kubectl then writes it
# into the Pod spec, where it sits in etcd for the pod's lifetime and shows up
# in `kubectl describe pod`.
#
# Using secretKeyRef instead means the Pod spec contains only "read this key
# from that Secret". The kubelet resolves it at container start, the value
# never crosses this machine, and nothing is written to etcd that wasn't
# already there.
#
# Note the env var names: Quarkus maps quarkus.datasource.password to
# QUARKUS_DATASOURCE_PASSWORD, so the uppercase/underscore form is what a
# secretKeyRef has to use.
kubectl run polaris-bootstrap \
  -n "$NAMESPACE" \
  --image=apache/polaris-admin-tool:1.5.0 \
  --restart=Never \
  --rm -i \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "polaris-bootstrap",
        "image": "apache/polaris-admin-tool:1.5.0",
        "args": ["bootstrap", "-r", "'"${REALM}"'", "-c", "'"${REALM},${ROOT_CLIENT_ID},${ROOT_CLIENT_SECRET}"'"],
        "stdin": true,
        "env": [
          { "name": "POLARIS_PERSISTENCE_TYPE", "value": "relational-jdbc" },
          { "name": "QUARKUS_DATASOURCE_USERNAME",
            "valueFrom": { "secretKeyRef": { "name": "polaris-persistence", "key": "username" } } },
          { "name": "QUARKUS_DATASOURCE_PASSWORD",
            "valueFrom": { "secretKeyRef": { "name": "polaris-persistence", "key": "password" } } },
          { "name": "QUARKUS_DATASOURCE_JDBC_URL",
            "valueFrom": { "secretKeyRef": { "name": "polaris-persistence", "key": "jdbcUrl" } } }
        ]
      }]
    }
  }'

# One value still cannot be passed by reference: ROOT_CLIENT_SECRET, because
# the admin tool only accepts it as an argument to `bootstrap -c`. It is
# generated fresh by this script moments earlier and stored straight into
# Secrets Manager below, so it is never read back from anywhere -- but it does
# appear in this pod's args. Kept as-is because the tool offers no alternative;
# noted here so the inconsistency is deliberate rather than overlooked.

echo "Storing root credentials in Secrets Manager ($SECRETS_MANAGER_SECRET)..."
aws secretsmanager create-secret \
  --name "$SECRETS_MANAGER_SECRET" \
  --region "$REGION" \
  --secret-string "{\"realm\":\"${REALM}\",\"clientId\":\"${ROOT_CLIENT_ID}\",\"clientSecret\":\"${ROOT_CLIENT_SECRET}\"}" \
  >/dev/null
unset ROOT_CLIENT_SECRET

echo ""
echo "Done. Root credentials saved to Secrets Manager, never printed."
echo "Next: ./04_install_polaris_prod.sh"
