#!/usr/bin/env bash
#
# 04_create_smtp_secret_prod.sh
#
# Gives Airflow a way to send email, so a failed DAG is something that arrives
# rather than something you have to go and look for.
#
# WHY A CONNECTION AND NOT THE [smtp] SECTION OF airflow.cfg
# ------------------------------------------------------------
# The `[smtp]` block configures `airflow.utils.email`, which Airflow has
# scheduled for deprecation. Airflow 3 routes email through the SMTP provider,
# which reads a CONNECTION -- `smtp_default` unless a task names another one.
# Setting `[smtp]` and expecting mail to work is a well-trodden way to spend an
# afternoon: nothing errors, and nothing sends.
#
# The connection is supplied as AIRFLOW_CONN_SMTP_DEFAULT rather than seeded
# into the metadata database. An env-var connection needs no `airflow
# connections add` step to be re-run after every database restore, it cannot
# drift from what this script wrote, and it never appears in the Connections UI
# where the password would be one click from visible.
#
# WHY GMAIL NEEDS AN APP PASSWORD
# ---------------------------------
# Google removed "less secure app access". A normal account password is
# rejected by smtp.gmail.com. An App Password is a 16-character credential
# scoped to one application, revocable on its own, and it only exists once
# 2-Step Verification is enabled on the account.
#
# It is prompted for here, never passed as an argument. An argument would be in
# the shell history and in the process list; this way the plaintext reaches AWS
# Secrets Manager and the Kubernetes Secret and nowhere else.
#
# Usage:
#   ./04_create_smtp_secret_prod.sh          # create (idempotent)
#   ./04_create_smtp_secret_prod.sh verify   # what exists, without secrets
#   ./04_create_smtp_secret_prod.sh test     # send one real email
#   ./04_create_smtp_secret_prod.sh rotate   # replace the app password
#
set -euo pipefail

REGION="ap-southeast-1"
NAMESPACE="airflow"
SMTP_HOST="smtp.gmail.com"
SMTP_PORT="587"
SMTP_FROM="pongkunworker@gmail.com"
SMTP_TO="pongkunworker@gmail.com"
SM_APP_PASSWORD="data-platform-prod-airflow-smtp-app-password"
K8S_SECRET="airflow-smtp-connection"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws; need kubectl; need python3

urlencode() { python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"; }

build_uri() {
  # Port 587 is STARTTLS, not implicit SSL. Without disable_ssl=true the hook
  # opens the socket with SSL and Gmail answers with a TLS record the client
  # cannot parse -- surfacing as `SSL WRONG_VERSION_NUMBER`, which reads like a
  # certificate problem and is a protocol one.
  #
  # from_email must equal the authenticated account. Gmail rejects a mismatched
  # sender with `550 From address not verified`.
  local user="$1" password="$2"
  printf 'smtp://%s:%s@%s:%s?disable_ssl=true&from_email=%s&timeout=30&retry_limit=3' \
    "$(urlencode "$user")" "$(urlencode "$password")" \
    "$SMTP_HOST" "$SMTP_PORT" "$(urlencode "$SMTP_FROM")"
}

restore_if_deleted() {
  local name="$1" deleted
  deleted="$(aws secretsmanager describe-secret --region "$REGION" \
    --secret-id "$name" --query 'DeletedDate' --output text 2>/dev/null || true)"
  if [ -n "$deleted" ] && [ "$deleted" != "None" ]; then
    echo "      restoring ${name}, which was scheduled for deletion"
    aws secretsmanager restore-secret --region "$REGION" --secret-id "$name" >/dev/null
  fi
}

report() {
  echo "=== Settings ==="
  echo "  host:      ${SMTP_HOST}:${SMTP_PORT} (STARTTLS)"
  echo "  from / to: ${SMTP_FROM} -> ${SMTP_TO}"
  echo ""
  echo "=== Secrets Manager ==="
  aws secretsmanager describe-secret --region "$REGION" \
    --secret-id "$SM_APP_PASSWORD" --query 'Name' --output text 2>/dev/null \
    || echo "  ${SM_APP_PASSWORD}: absent"
  echo ""
  echo "=== Kubernetes ==="
  kubectl get secret "$K8S_SECRET" -n "$NAMESPACE" >/dev/null 2>&1 \
    && echo "  secret ${K8S_SECRET}: present" \
    || echo "  secret ${K8S_SECRET}: MISSING"
  echo ""
  echo "=== Is it wired into the pods ==="
  # The Secret existing proves nothing on its own: values.yaml has to reference
  # it under `secret:` and the release has to have been upgraded since.
  if kubectl get deploy -n "$NAMESPACE" airflow-scheduler \
       -o jsonpath='{.spec.template.spec.containers[*].env[*].name}' 2>/dev/null \
       | tr ' ' '\n' | grep -q '^AIRFLOW_CONN_SMTP_DEFAULT$'; then
    echo "  AIRFLOW_CONN_SMTP_DEFAULT: present on the scheduler"
  else
    echo "  AIRFLOW_CONN_SMTP_DEFAULT: NOT on the scheduler."
    echo "  Add it to chart/airflow/values.yaml under \`secret:\` and re-run"
    echo "  ./02_install_airflow_prod.sh"
  fi
}

case "$MODE" in
  verify) report; exit 0 ;;
  test)
    # Runs inside a pod that already has the env var, so this tests exactly
    # what a DAG would use -- not a separate code path that happens to work.
    echo "Sending one email to ${SMTP_TO} from inside the scheduler..."
    kubectl exec -n "$NAMESPACE" deploy/airflow-scheduler -c scheduler -- python3 -c "
from airflow.providers.smtp.hooks.smtp import SmtpHook
with SmtpHook(smtp_conn_id='smtp_default') as hook:
    hook.send_email_smtp(
        to='${SMTP_TO}',
        subject='[Airflow] SMTP test from data-platform-prod',
        html_content='<p>If this arrived, alerting works.</p>',
    )
print('sent')
"
    exit 0
    ;;
  rotate|deploy) ;;
  *) echo "Usage: $0 [deploy|verify|test|rotate]" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
echo "[1/3] App password..."
restore_if_deleted "$SM_APP_PASSWORD"
EXISTING="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$SM_APP_PASSWORD" --query SecretString --output text 2>/dev/null || true)"

if [ "$MODE" = "rotate" ] || [ -z "$EXISTING" ] || [ "$EXISTING" = "None" ]; then
  echo ""
  echo "      Google shows the App Password as four groups of four, like"
  echo "      'abcd efgh ijkl mnop'. The spaces are display only -- they are"
  echo "      stripped below, so paste it either way."
  echo ""
  printf '      App Password for %s: ' "$SMTP_FROM"
  read -rs APP_PASSWORD
  echo ""
  APP_PASSWORD="$(printf '%s' "$APP_PASSWORD" | tr -d '[:space:]')"

  [ -n "$APP_PASSWORD" ] || { echo "ERROR: nothing entered." >&2; exit 1; }
  # 16 characters is what Google issues. A 20-character value is almost always
  # the account password pasted by mistake, which Gmail will reject with a 535
  # several minutes later inside a task log.
  if [ "${#APP_PASSWORD}" -ne 16 ]; then
    echo "ERROR: expected 16 characters after removing spaces, got ${#APP_PASSWORD}." >&2
    echo "       An App Password is 16 characters. A normal account password" >&2
    echo "       will not work with smtp.gmail.com at all." >&2
    exit 1
  fi

  if aws secretsmanager describe-secret --region "$REGION" --secret-id "$SM_APP_PASSWORD" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --region "$REGION" \
      --secret-id "$SM_APP_PASSWORD" --secret-string "$APP_PASSWORD" >/dev/null
    echo "      rotated in Secrets Manager"
  else
    aws secretsmanager create-secret --region "$REGION" \
      --name "$SM_APP_PASSWORD" \
      --description "Gmail App Password used by Airflow to send alert email as ${SMTP_FROM}" \
      --secret-string "$APP_PASSWORD" >/dev/null
    echo "      stored in Secrets Manager"
  fi
else
  APP_PASSWORD="$EXISTING"
  echo "      already in Secrets Manager, reusing"
fi

echo "[2/3] Connection URI..."
URI="$(build_uri "$SMTP_FROM" "$APP_PASSWORD")"
# Print the shape without the credential, so a typo in the host or port is
# visible without the password being.
echo "      smtp://${SMTP_FROM}:***@${SMTP_HOST}:${SMTP_PORT}?disable_ssl=true&from_email=${SMTP_FROM}"

echo "[3/3] Kubernetes Secret..."
printf '%s' "$URI" \
  | kubectl create secret generic "$K8S_SECRET" -n "$NAMESPACE" \
      --from-file=connection=/dev/stdin --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null
echo "      ${K8S_SECRET}"

echo ""
echo "Done. Next:"
echo "  1. chart/airflow/values.yaml already maps this under \`secret:\`;"
echo "     apply it with ./02_install_airflow_prod.sh"
echo "  2. $0 verify   # is the env var actually on the pods"
echo "  3. $0 test     # send one real email"
if [ "$MODE" = "rotate" ]; then
  echo ""
  echo "Pods read the Secret as an env var at start-up, so a rotation needs a"
  echo "restart before it takes effect:"
  echo "  kubectl rollout restart deploy -n ${NAMESPACE}"
fi
