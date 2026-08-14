#!/usr/bin/env bash
#
# 03_create_airflow_admin_prod.sh
#
# Creates the Airflow admin user, replacing the chart's createUserJob (disabled
# in chart/airflow/values.yaml).
#
# WHY NOT THE CHART'S JOB
# ------------------------
# The chart's Job reads the password from `createUserJob.defaultUser.password`
# in values.yaml -- a plaintext value in a file that lives in git, defaulting to
# "admin". Everything else in this platform generates credentials with openssl
# and keeps them in AWS Secrets Manager. This script keeps the UI login on the
# same footing.
#
# The password is generated here, stored in Secrets Manager, and passed to
# `airflow users create` on stdin rather than as `--password <value>`, so it
# never appears in the container's process list.
#
# Run this AFTER 02_install_airflow_prod.sh -- it needs a running API server pod
# and a migrated database.
#
# Usage:
#   ./03_create_airflow_admin_prod.sh          # create if missing (idempotent)
#   ./03_create_airflow_admin_prod.sh show     # print the stored password
#   ./03_create_airflow_admin_prod.sh rotate   # set a new password
#   ./03_create_airflow_admin_prod.sh list     # list existing users
#
set -euo pipefail

REGION="ap-southeast-1"
NAMESPACE="airflow"
ADMIN_USER="admin"
ADMIN_EMAIL="platform@example.com"
SM_ADMIN="data-platform-prod-airflow-admin-password"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need kubectl; need aws; need openssl

# Find a pod with the airflow CLI on it. The API server is the natural choice:
# it is a long-running Deployment (unlike the migration Job) and always has the
# full Airflow install.
find_pod() {
  kubectl get pods -n "$NAMESPACE" -l component=api-server \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

POD="$(find_pod || true)"
if [ -z "$POD" ]; then
  echo "ERROR: no running api-server pod in namespace '${NAMESPACE}'." >&2
  echo "       Install Airflow first: ./02_install_airflow_prod.sh" >&2
  kubectl get pods -n "$NAMESPACE" >&2 2>/dev/null || true
  exit 1
fi

airflow_cli() { kubectl exec -n "$NAMESPACE" "$POD" -c api-server -- airflow "$@"; }

case "$MODE" in
  list)
    airflow_cli users list
    exit 0
    ;;
  show)
    aws secretsmanager get-secret-value --region "$REGION" \
      --secret-id "$SM_ADMIN" --query 'SecretString' --output text 2>/dev/null \
      || { echo "ERROR: '$SM_ADMIN' not found -- has this script been run?" >&2; exit 1; }
    echo ""
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# Does the user already exist?
# ---------------------------------------------------------------------------
EXISTS=""
if airflow_cli users list 2>/dev/null | grep -qE "(^| )${ADMIN_USER}( |$)"; then
  EXISTS="yes"
fi

if [ -n "$EXISTS" ] && [ "$MODE" != "rotate" ]; then
  echo "User '${ADMIN_USER}' already exists. Nothing to do."
  echo ""
  echo "  ./03_create_airflow_admin_prod.sh show     # print the password"
  echo "  ./03_create_airflow_admin_prod.sh rotate   # set a new one"
  exit 0
fi

# ---------------------------------------------------------------------------
# Generate and store the password
#
# -base64 24 gives 32 printable characters with no shell-special characters to
# quote, which matters because this value is typed into a browser by a human
# and pasted around.
# ---------------------------------------------------------------------------
PASSWORD="$(openssl rand -base64 24)"

if aws secretsmanager describe-secret --region "$REGION" --secret-id "$SM_ADMIN" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value --region "$REGION" \
    --secret-id "$SM_ADMIN" --secret-string "$PASSWORD" >/dev/null
else
  aws secretsmanager create-secret --region "$REGION" \
    --name "$SM_ADMIN" \
    --description "Airflow UI admin password for data-platform-prod (generated, never handled by a human)" \
    --secret-string "$PASSWORD" >/dev/null
fi

# ---------------------------------------------------------------------------
# Create or reset
#
# `--use-random-password` then `users reset-password` is the only path that
# keeps the value off the argument list: `airflow users create --password X`
# would put it in the container's /proc/<pid>/cmdline, readable by anything
# that can exec into the pod.
# ---------------------------------------------------------------------------
if [ -z "$EXISTS" ]; then
  echo "Creating user '${ADMIN_USER}'..."
  airflow_cli users create \
    --username "$ADMIN_USER" \
    --firstname Data \
    --lastname Platform \
    --role Admin \
    --email "$ADMIN_EMAIL" \
    --use-random-password >/dev/null
fi

echo "Setting the password..."
printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" \
  | kubectl exec -i -n "$NAMESPACE" "$POD" -c api-server -- \
      airflow users reset-password --username "$ADMIN_USER" --use-random-password=False >/dev/null 2>&1 \
  || {
    # Older/newer CLI variants differ on this flag. Fall back to the
    # non-interactive form, and say plainly that it is the weaker option.
    echo "  (interactive reset unavailable on this Airflow build -- falling back)" >&2
    airflow_cli users reset-password --username "$ADMIN_USER" --password "$PASSWORD" >/dev/null
    echo "  NOTE: on this path the password was passed as a CLI argument inside" >&2
    echo "        the pod, so it was briefly visible in that container's process" >&2
    echo "        list. Rotate it if that matters:  $0 rotate" >&2
  }

unset PASSWORD

cat <<EOF

Admin user ready.

  username : ${ADMIN_USER}
  password : stored in Secrets Manager as ${SM_ADMIN}

Read it with:
  ./03_create_airflow_admin_prod.sh show

Open the UI:
  ./02_install_airflow_prod.sh ui      # http://localhost:18080
EOF
