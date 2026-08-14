#!/usr/bin/env bash
#
# 00_create_grafana_secret_prod.sh
#
# Creates the Grafana admin credential, before the chart is installed.
#
# WHY THIS IS A SEPARATE STEP AND NOT A HELM VALUE
# --------------------------------------------------
# kube-prometheus-stack will happily take `grafana.adminPassword` in
# values.yaml. That puts the production password in a file that is read,
# diffed, and pasted into terminals -- and, in a repo meant to be submitted,
# read by someone else entirely.
#
# Generating it here means the plaintext exists in exactly two places: AWS
# Secrets Manager, and the Kubernetes Secret the pod mounts. values.yaml only
# names the Secret.
#
# WHY GRAFANA GETS A PASSWORD AT ALL WHEN IT IS BEHIND THE ALB
# --------------------------------------------------------------
# `grafana.nopega.net` is a public hostname. The ALB terminates TLS and
# forwards; it does not authenticate. Anonymous access, or the chart's default
# `admin/prom-operator`, would put a dashboard of the platform's internals --
# node names, namespaces, query patterns, which is a map for anyone probing it
# -- on the open internet.
#
# The stronger option is Cloudflare Access in front, as Harbor and Airflow use.
# That is worth doing and is not done here; a generated 32-character password
# is the floor, not the ceiling.
#
# Usage:
#   ./00_create_grafana_secret_prod.sh          # create (idempotent)
#   ./00_create_grafana_secret_prod.sh verify    # what exists where
#   ./00_create_grafana_secret_prod.sh show      # print the login
#   ./00_create_grafana_secret_prod.sh rotate    # new password, then reinstall
#
set -euo pipefail

REGION="ap-southeast-1"
NAMESPACE="monitoring"
ADMIN_USER="admin"
SM_ADMIN_PASSWORD="data-platform-prod-grafana-admin-password"
K8S_SECRET="grafana-admin-credentials"
GRAFANA_HOST="grafana.nopega.net"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws; need kubectl; need openssl

restore_if_deleted() {
  local name="$1" deleted
  deleted="$(aws secretsmanager describe-secret --region "$REGION" \
    --secret-id "$name" --query 'DeletedDate' --output text 2>/dev/null || true)"
  if [ -n "$deleted" ] && [ "$deleted" != "None" ]; then
    echo "      restoring ${name}, which was scheduled for deletion"
    aws secretsmanager restore-secret --region "$REGION" --secret-id "$name" >/dev/null
  fi
}

generate() {
  # Alphanumeric only. Grafana's login form is fine with anything, but this
  # password gets pasted into terminals and URLs during debugging, and a shell
  # metacharacter in it turns a working credential into an intermittent one.
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-32
}

report() {
  echo "=== Kubernetes ==="
  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
    && echo "  namespace ${NAMESPACE}: present" \
    || echo "  namespace ${NAMESPACE}: MISSING"
  kubectl get secret "$K8S_SECRET" -n "$NAMESPACE" >/dev/null 2>&1 \
    && echo "  secret ${K8S_SECRET}: present" \
    || echo "  secret ${K8S_SECRET}: MISSING"
  echo "=== Secrets Manager ==="
  aws secretsmanager describe-secret --region "$REGION" \
    --secret-id "$SM_ADMIN_PASSWORD" --query 'Name' --output text 2>/dev/null \
    || echo "  ${SM_ADMIN_PASSWORD}: absent"
  echo "=== Do they agree? ==="
  # A Secrets Manager value that has drifted from the mounted Secret is the
  # failure this check exists for: `show` prints one password and the login
  # rejects it, which reads like the account is broken.
  local sm k8s
  sm="$(aws secretsmanager get-secret-value --region "$REGION" \
    --secret-id "$SM_ADMIN_PASSWORD" --query SecretString --output text 2>/dev/null || true)"
  k8s="$(kubectl get secret "$K8S_SECRET" -n "$NAMESPACE" \
    -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [ -z "$sm" ] || [ -z "$k8s" ]; then
    echo "  cannot compare -- one side is missing"
  elif [ "$sm" = "$k8s" ]; then
    echo "  yes"
  else
    echo "  NO -- the cluster and Secrets Manager hold different passwords."
    echo "  Re-run this script to push the Secrets Manager value into the cluster."
  fi
}

case "$MODE" in
  verify) report; exit 0 ;;
  show)
    echo "url:      https://${GRAFANA_HOST}"
    echo "username: ${ADMIN_USER}"
    printf 'password: '
    aws secretsmanager get-secret-value --region "$REGION" \
      --secret-id "$SM_ADMIN_PASSWORD" --query SecretString --output text
    exit 0
    ;;
  rotate|deploy) ;;
  *) echo "Usage: $0 [deploy|verify|show|rotate]" >&2; exit 2 ;;
esac

echo "[1/3] Namespace..."
# Created here rather than by Helm, because the Secret has to exist before the
# chart installs -- Grafana reads it at pod start, and a missing Secret is a
# CreateContainerConfigError rather than anything that mentions a password.
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "      ${NAMESPACE}"

echo "[2/3] Password in AWS Secrets Manager..."
restore_if_deleted "$SM_ADMIN_PASSWORD"
EXISTING="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$SM_ADMIN_PASSWORD" --query SecretString --output text 2>/dev/null || true)"

if [ "$MODE" = "rotate" ] || [ -z "$EXISTING" ] || [ "$EXISTING" = "None" ]; then
  PASSWORD="$(generate)"
  if aws secretsmanager describe-secret --region "$REGION" --secret-id "$SM_ADMIN_PASSWORD" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --region "$REGION" \
      --secret-id "$SM_ADMIN_PASSWORD" --secret-string "$PASSWORD" >/dev/null
    echo "      rotated"
  else
    aws secretsmanager create-secret --region "$REGION" \
      --name "$SM_ADMIN_PASSWORD" \
      --description "Grafana admin password for ${GRAFANA_HOST}" \
      --secret-string "$PASSWORD" >/dev/null
    echo "      created"
  fi
else
  PASSWORD="$EXISTING"
  echo "      already exists, reusing"
fi

echo "[3/3] Kubernetes Secret..."
# Key names are the ones the chart's `grafana.admin` block expects. Changing
# either here means changing values.yaml too, and the symptom of a mismatch is
# Grafana starting with its default credential as though this script never ran.
kubectl create secret generic "$K8S_SECRET" -n "$NAMESPACE" \
  --from-literal=admin-user="$ADMIN_USER" \
  --from-literal=admin-password="$PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "      ${K8S_SECRET}"

echo ""
echo "Done. The password was not printed; use \`$0 show\` to read it."
if [ "$MODE" = "rotate" ]; then
  echo ""
  echo "Grafana reads this Secret at start-up only. Restart it to pick up the"
  echo "new password:"
  echo "  kubectl rollout restart deploy/kube-prometheus-stack-grafana -n ${NAMESPACE}"
fi
