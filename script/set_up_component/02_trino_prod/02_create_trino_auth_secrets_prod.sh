#!/usr/bin/env bash
#
# Creates the credentials required before exposing Trino through the public
# ALB. Plaintext passwords stay in AWS Secrets Manager; the cluster receives
# only bcrypt password-file hashes and Trino's internal shared secret.
#
# Usage:
#   ./02_create_trino_auth_secrets_prod.sh              # create / reconcile
#   ./02_create_trino_auth_secrets_prod.sh verify       # status only
#   ./02_create_trino_auth_secrets_prod.sh show-powerbi # print Power BI login
#   ./02_create_trino_auth_secrets_prod.sh show-etl     # print ETL login
set -euo pipefail

REGION="ap-southeast-1"
NAMESPACE="data-platform"
BI_USER="team_b_powerbi"
ETL_USER="etl_setup"
SM_BI_PASSWORD="data-platform-prod-trino-powerbi-password"
SM_ETL_PASSWORD="data-platform-prod-trino-etl-password"
SM_SHARED_SECRET="data-platform-prod-trino-internal-shared-secret"
K8S_PASSWORD_SECRET="trino-password-authentication"
K8S_INTERNAL_SECRET="trino-internal-communication"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws; need kubectl; need openssl; need htpasswd

restore_if_deleted() {
  local name="$1" deleted
  deleted="$(aws secretsmanager describe-secret --region "$REGION" --secret-id "$name" --query 'DeletedDate' --output text 2>/dev/null || true)"
  if [ -n "$deleted" ] && [ "$deleted" != "None" ]; then
    echo "      restoring ${name}, which was scheduled for deletion"
    aws secretsmanager restore-secret --region "$REGION" --secret-id "$name" >/dev/null
  fi
}

get_or_create() {
  local name="$1" description="$2" generated existing
  restore_if_deleted "$name"
  existing="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$name" --query SecretString --output text 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "None" ]; then
    printf '%s' "$existing"
    return
  fi
  # Alphanumeric avoids URL/driver escaping surprises in clients while 32
  # random characters still carries more than enough entropy.
  generated="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-32)"
  aws secretsmanager create-secret --region "$REGION" --name "$name" --description "$description" --secret-string "$generated" >/dev/null
  printf '%s' "$generated"
}

report() {
  echo "=== Kubernetes secrets ==="
  for secret in "$K8S_PASSWORD_SECRET" "$K8S_INTERNAL_SECRET"; do
    kubectl get secret "$secret" -n "$NAMESPACE" >/dev/null 2>&1 && echo "  ${secret}: present" || echo "  ${secret}: MISSING"
  done
  echo "=== Secrets Manager ==="
  for secret in "$SM_BI_PASSWORD" "$SM_ETL_PASSWORD" "$SM_SHARED_SECRET"; do
    aws secretsmanager describe-secret --region "$REGION" --secret-id "$secret" --query 'Name' --output text 2>/dev/null || echo "  ${secret}: absent"
  done
}

case "$MODE" in
  verify) report; exit 0 ;;
  show-powerbi)
    echo "host:     trino.nopega.net"
    echo "port:     443"
    echo "username: ${BI_USER}"
    printf 'password: '
    aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SM_BI_PASSWORD" --query SecretString --output text
    exit 0
    ;;
  show-etl)
    echo "username: ${ETL_USER}"
    printf 'password: '
    aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SM_ETL_PASSWORD" --query SecretString --output text
    exit 0
    ;;
  deploy) ;;
  *) echo "Usage: $0 [deploy|verify|show-powerbi|show-etl]" >&2; exit 2 ;;
esac

echo "[1/3] Passwords in AWS Secrets Manager..."
BI_PASSWORD="$(get_or_create "$SM_BI_PASSWORD" "Password for ${BI_USER}, the Power BI read-only Trino user")"
ETL_PASSWORD="$(get_or_create "$SM_ETL_PASSWORD" "Password for ${ETL_USER}, the Trino ETL user")"
SHARED_SECRET="$(get_or_create "$SM_SHARED_SECRET" "Trino internal-communication shared secret; do not rotate while the cluster is running")"

echo "[2/3] Bcrypt password file in Kubernetes..."
BI_HASH="$(printf '%s' "$BI_PASSWORD"  | htpasswd -i -n -B -C 10 "$BI_USER")"
ETL_HASH="$(printf '%s' "$ETL_PASSWORD" | htpasswd -i -n -B -C 10 "$ETL_USER")"
printf '%s\n%s\n' "$BI_HASH" "$ETL_HASH" \
  | kubectl create secret generic "$K8S_PASSWORD_SECRET" -n "$NAMESPACE" \
      --from-file=password.db=/dev/stdin --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null

echo "[3/3] Trino internal shared secret in Kubernetes..."
printf '%s' "$SHARED_SECRET" \
  | kubectl create secret generic "$K8S_INTERNAL_SECRET" -n "$NAMESPACE" \
      --from-file=TRINO_INTERNAL_SHARED_SECRET=/dev/stdin --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null

unset BI_PASSWORD ETL_PASSWORD SHARED_SECRET BI_HASH ETL_HASH
cat <<EOF

Authentication secrets are ready. Reapply the Trino chart so the coordinator
mounts password.db and every Trino node receives the shared secret:

  ./03_install_trino_prod.sh

Then use './02_create_trino_auth_secrets_prod.sh show-powerbi' only on the
computer that needs the password. Do not paste that output into a ticket, git
commit or dashboard configuration file.
EOF
