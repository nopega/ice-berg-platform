#!/usr/bin/env bash
#
# 06_create_team_roles_prod.sh
#
# Creates per-team identities and permissions inside Polaris, replacing the
# "everything runs as root" state that 05_ leaves behind.
#
# WHY THIS MATTERS MORE THAN ENGINE-LEVEL PERMISSIONS
# ---------------------------------------------------
# Permissions enforced only in Trino stop at Trino: anyone who can reach S3 by
# another route -- a stray AWS credential, their own Spark job -- reads the
# Parquet files directly and the rules never apply.
#
# Polaris sits earlier in the chain. It decides whether to vend S3 credentials
# at all, so a principal without TABLE_READ_DATA on a table cannot obtain keys
# for that table's files. Knowing the exact S3 path is of no use. That is the
# difference between a rule and a lock.
#
# WHAT IT BUILDS
# --------------
# Polaris authorises through a four-link chain, and each link exists for a
# reason:
#
#   principal          a login (client id + secret) -- an ETL job, a person
#     -> principal-role   a job function ("team B analyst")
#       -> catalog-role      a bundle of privileges inside one catalog
#         -> privileges         the actual grants on namespace/table
#
# The two middle links look redundant at this scale and are not: principals
# come and go (new hire, rotated ETL credential) while job functions are
# stable, and catalog-roles let the same job function mean different things in
# different catalogs.
#
#   team_a          read + write on gold.aggregate
#                   Team A owns the daily report pipeline and writes back
#                   aggregates. Scoped to gold rather than to the raw layers on
#                   purpose: a reporting team needs the rolled-up tables, and
#                   giving it write access to bronze would let a report job
#                   modify source data.
#
#   team_b          read only, on gold.aggregate only
#                   Team B runs hourly monitoring queries. No write path exists
#                   for them at all -- not "they are told not to write".
#
#   finance_viewer  read only on the whole bronze.financial category
#                   Granted one level up, on `bronze.financial` rather than
#                   `bronze.financial.invoice`, which is the payoff of the
#                   nested namespace tree: a new domain added under
#                   bronze.financial next month is covered by this grant on the
#                   day it is created, with no permission change. The same
#                   grant written against flattened names would have to be
#                   reissued per domain.
#
#   etl             full content management, catalog-wide
#                   The Spark pipeline reads bronze, writes silver and gold, so
#                   it crosses every medallion layer and its grant is at the
#                   catalog level rather than on any one branch.
#
# WHY THE REPORTING TEAMS ARE POINTED AT gold AND NOT AT bronze
# --------------------------------------------------------------
# This is also a cost and performance control, not only a permission one. The
# brief assumes ~100 queries arrive whenever someone builds a report; those are
# dashboard tiles, each a small aggregate query. Answered from gold they read
# pre-rolled-up tables measured in megabytes. Pointed at bronze they would each
# scan raw data measured in terabytes, and no amount of Trino workers makes
# that acceptable. The grant is what makes the intended path the only available
# one.
#
# GRANT SCOPE IS PER-TEAM, NOT GLOBAL
# ------------------------------------
# Each entry below carries its own namespace, so the read/write distinction
# and the *reach* of that distinction are set independently. That matters:
# giving team_b read on all of `financial` instead of one domain would be a
# quiet governance failure that a single shared DATA_NAMESPACE variable makes
# easy to introduce and hard to see.
#
# Each principal's client id/secret is stored in AWS Secrets Manager, matching
# how the root credential is handled, and is never printed.
#
# Usage:
#   ./06_create_team_roles_prod.sh          # create / update (idempotent)
#   ./06_create_team_roles_prod.sh verify   # show principals, roles and grants
#   ./06_create_team_roles_prod.sh clean    # delete the team principals/roles
#
set -euo pipefail

REGION="ap-southeast-1"
NAMESPACE="data-platform"
RELEASE_NAME="polaris"
CATALOG_NAME="data_platform"
ROOT_SECRET="data-platform-prod-polaris-root-credentials"
SECRET_PREFIX="data-platform-prod-polaris"
LOCAL_PORT="18181"
API_URL="http://localhost:${LOCAL_PORT}"
MODE="${1:-deploy}"

# team | principal-role | catalog-role | namespace | privileges (comma separated)
#
# The namespace field is dot-separated and matches the tree built by
# 07_create_dg_namespaces_prod.sh: "transactional.delivery" is the two-level
# namespace, "financial" is the category level, and "-" means the grant is
# catalog-wide and needs no namespace at all.
#
# Privilege choice, and what each one actually permits:
#   TABLE_READ_DATA        read table contents (and be vended read credentials)
#   TABLE_WRITE_DATA       write table contents (and be vended write credentials)
#   TABLE_LIST/READ_PROPS  see that the table exists, read its schema
#   NAMESPACE_LIST         see the namespace in SHOW SCHEMAS
#   CATALOG_MANAGE_CONTENT everything below it, including CREATE and DROP
TEAMS=(
  "team_a|team_a_role|team_a_readwrite|gold.aggregate|TABLE_READ_DATA,TABLE_WRITE_DATA,TABLE_LIST,TABLE_READ_PROPERTIES,NAMESPACE_LIST"
  "team_b|team_b_role|team_b_readonly|gold.aggregate|TABLE_READ_DATA,TABLE_LIST,TABLE_READ_PROPERTIES,NAMESPACE_LIST"
  "finance_viewer|finance_viewer_role|finance_readonly|bronze.financial|TABLE_READ_DATA,TABLE_LIST,TABLE_READ_PROPERTIES,NAMESPACE_LIST"
  "etl|etl_role|etl_writer|-|CATALOG_MANAGE_CONTENT"
)

# "transactional.delivery" -> ["transactional","delivery"] for a grant body.
ns_json() {
  python3 -c '
import sys, json
print(json.dumps(sys.argv[1].split(".")))
' "$1"
}

# "transactional.delivery" -> the URL-encoded 0x1F-joined path segment the
# Iceberg REST API uses to address a multi-level namespace.
ns_segment() {
  python3 -c '
import sys, urllib.parse
print(urllib.parse.quote("\x1f".join(sys.argv[1].split(".")), safe=""))
' "$1"
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need kubectl; need curl; need aws; need python3

json_get() {
  python3 -c '
import sys, json
try:    d = json.load(sys.stdin)
except Exception: sys.exit(0)
print(d.get(sys.argv[1], "") if isinstance(d, dict) else "")
' "$1"
}
json_pretty() { python3 -m json.tool 2>/dev/null || cat; }

# store_team_secret NAME TEAM JSON_VALUE
#
# Writing a Secrets Manager value is not simply "create, else update": a secret
# has a third state. `delete-secret` without --force-delete-without-recovery
# only *schedules* deletion, leaving the name reserved for a recovery window of
# up to 30 days. In that state create-secret fails because the name is taken,
# and put-secret-value fails with
#
#   InvalidRequestException: You can't perform this operation on the secret
#   because it was marked for deletion.
#
# which is what re-running this script after a `clean` produces. The name
# cannot be reused and the value cannot be written until the secret is
# restored, so handle that state explicitly rather than treating every failure
# as "it must already exist".
store_team_secret() {
  local name="$1" team="$2" value="$3" deleted

  deleted="$(aws secretsmanager describe-secret --region "$REGION" \
    --secret-id "$name" --query 'DeletedDate' --output text 2>/dev/null || echo NONE)"

  if [ "$deleted" != "NONE" ] && [ "$deleted" != "None" ] && [ -n "$deleted" ]; then
    echo "   secret ${name} was scheduled for deletion -- restoring it"
    aws secretsmanager restore-secret --region "$REGION" --secret-id "$name" >/dev/null
  fi

  if aws secretsmanager describe-secret --region "$REGION" --secret-id "$name" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --region "$REGION" \
      --secret-id "$name" --secret-string "$value" >/dev/null
  else
    aws secretsmanager create-secret --region "$REGION" \
      --name "$name" \
      --description "Polaris credentials for the ${team} principal" \
      --secret-string "$value" >/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Tunnel (same rules as 05_: never abort a request, never fail silently)
# ---------------------------------------------------------------------------
PF_PID=""; PF_LOG="$(mktemp)"; API_BODY="$(mktemp)"
cleanup() {
  if [ -n "$PF_PID" ]; then kill "$PF_PID" 2>/dev/null || true; wait "$PF_PID" 2>/dev/null || true; fi
  rm -f "$PF_LOG" "$API_BODY" 2>/dev/null || true
}
trap cleanup EXIT

start_tunnel() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  kubectl port-forward -n "$NAMESPACE" "svc/${RELEASE_NAME}" "${LOCAL_PORT}:8181" >"$PF_LOG" 2>&1 &
  PF_PID=$!
  local i code
  for i in $(seq 1 20); do
    kill -0 "$PF_PID" 2>/dev/null || { echo "ERROR: port-forward exited:" >&2; cat "$PF_LOG" >&2; return 1; }
    set +e
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${API_URL}/api/catalog/v1/config")"
    set -e
    [ -n "$code" ] && [ "$code" != "000" ] && return 0
    sleep 1
  done
  echo "ERROR: tunnel never carried a complete request." >&2; cat "$PF_LOG" >&2; return 1
}

api() {
  local method="$1" path="$2" body="${3:-}" attempt rc
  for attempt in 1 2; do
    set +e
    if [ -n "$body" ]; then
      API_CODE="$(curl -s -o "$API_BODY" -w '%{http_code}' --max-time 30 -X "$method" \
        -H "Authorization: Bearer ${TOKEN}" -H "Polaris-Realm: ${REALM}" \
        -H 'Content-Type: application/json' -d "$body" "${API_URL}${path}")"
    else
      API_CODE="$(curl -s -o "$API_BODY" -w '%{http_code}' --max-time 30 -X "$method" \
        -H "Authorization: Bearer ${TOKEN}" -H "Polaris-Realm: ${REALM}" "${API_URL}${path}")"
    fi
    rc=$?
    set -e
    [ $rc -eq 0 ] && return 0
    echo "      transport error (curl exit $rc) -- restarting tunnel" >&2
    start_tunnel || return 1
  done
  return 1
}

# ---------------------------------------------------------------------------
# 1. Authenticate as root
# ---------------------------------------------------------------------------
echo "[1/3] Reading root credentials..."
ROOT_JSON="$(aws secretsmanager get-secret-value --secret-id "$ROOT_SECRET" --region "$REGION" \
  --query 'SecretString' --output text 2>/dev/null)" \
  || { echo "ERROR: '$ROOT_SECRET' not found. Run 03_ and 05_ first." >&2; exit 1; }
REALM="$(printf '%s' "$ROOT_JSON" | json_get realm)"
ROOT_ID="$(printf '%s' "$ROOT_JSON" | json_get clientId)"
ROOT_SECRET_VAL="$(printf '%s' "$ROOT_JSON" | json_get clientSecret)"

READY="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=polaris \
  -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)"
[ "$READY" = "true" ] || { echo "ERROR: Polaris pod is not Ready." >&2; exit 1; }

echo "[2/3] Opening tunnel and authenticating..."
start_tunnel || exit 1
set +e
curl -s -o "$API_BODY" --max-time 30 -X POST "${API_URL}/api/catalog/v1/oauth/tokens" \
  -H "Polaris-Realm: ${REALM}" \
  --data-urlencode 'grant_type=client_credentials' \
  --data-urlencode "client_id=${ROOT_ID}" \
  --data-urlencode "client_secret=${ROOT_SECRET_VAL}" \
  --data-urlencode 'scope=PRINCIPAL_ROLE:ALL'
set -e
TOKEN="$(json_get access_token < "$API_BODY")"
[ -n "$TOKEN" ] || { echo "ERROR: could not authenticate as root." >&2; cat "$API_BODY" >&2; exit 1; }
echo "      authenticated"

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
if [ "$MODE" = "verify" ]; then
  echo ""
  echo "=== principals ==="
  api GET "/api/management/v1/principals" && cat "$API_BODY" | json_pretty
  echo ""
  echo "=== principal roles ==="
  api GET "/api/management/v1/principal-roles" && cat "$API_BODY" | json_pretty
  echo ""
  echo "=== catalog roles in ${CATALOG_NAME} ==="
  api GET "/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles" && cat "$API_BODY" | json_pretty
  for entry in "${TEAMS[@]}"; do
    IFS='|' read -r team prole crole ns privs <<< "$entry"
    echo ""
    echo "=== grants on ${crole}  (scope: ${ns}) ==="
    api GET "/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles/${crole}/grants" \
      && cat "$API_BODY" | json_pretty
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# clean
# ---------------------------------------------------------------------------
if [ "$MODE" = "clean" ]; then
  echo ""
  echo "This deletes the team principals, principal-roles and catalog-roles."
  echo "The catalog, its namespaces and all table data are untouched."
  read -r -p "Type 'clean' to confirm: " confirm
  [ "$confirm" = "clean" ] || { echo "Aborted."; exit 0; }
  for entry in "${TEAMS[@]}"; do
    IFS='|' read -r team prole crole ns privs <<< "$entry"
    api DELETE "/api/management/v1/principals/${team}";                                  echo "  principal ${team}: HTTP $API_CODE"
    api DELETE "/api/management/v1/principal-roles/${prole}";                              echo "  principal-role ${prole}: HTTP $API_CODE"
    api DELETE "/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles/${crole}";       echo "  catalog-role ${crole}: HTTP $API_CODE"
    aws secretsmanager delete-secret --region "$REGION" \
      --secret-id "${SECRET_PREFIX}-${team}-credentials" \
      --force-delete-without-recovery >/dev/null 2>&1 || true
  done
  echo "Done."
  exit 0
fi

# ---------------------------------------------------------------------------
# deploy
# ---------------------------------------------------------------------------
echo "[3/3] Creating team principals and roles..."

for entry in "${TEAMS[@]}"; do
  IFS='|' read -r team prole crole ns privs <<< "$entry"
  echo ""
  echo "-- ${team}  (scope: ${ns}) --"

  # A namespace-scoped grant against a namespace that does not exist fails with
  # a 500 that says nothing useful, so check first and say what is actually
  # wrong. Catalog-wide entries ("-") have nothing to check.
  if [ "$ns" != "-" ]; then
    api GET "/api/catalog/v1/${CATALOG_NAME}/namespaces/$(ns_segment "$ns")"
    if [ "$API_CODE" != "200" ]; then
      echo "ERROR: namespace '${ns}' does not exist in catalog '${CATALOG_NAME}' (HTTP $API_CODE)." >&2
      echo "       Create the namespace tree first:  ./07_create_dg_namespaces_prod.sh" >&2
      exit 1
    fi
  fi

  # 1. principal ------------------------------------------------------------
  # Polaris generates the client secret and returns it exactly once, on
  # creation. There is no way to read it back afterwards, so it has to be
  # captured here and stored immediately -- which also means a re-run cannot
  # recover it, only rotate it.
  TEAM_SECRET_NAME="${SECRET_PREFIX}-${team}-credentials"
  api GET "/api/management/v1/principals/${team}"
  if [ "$API_CODE" = "200" ]; then
    echo "   principal: exists"
    aws secretsmanager describe-secret --secret-id "$TEAM_SECRET_NAME" --region "$REGION" >/dev/null 2>&1 \
      || echo "   WARNING: the principal exists but its credentials are not in Secrets Manager." >&2
    [ "$API_CODE" = "200" ] && aws secretsmanager describe-secret --secret-id "$TEAM_SECRET_NAME" --region "$REGION" >/dev/null 2>&1 \
      || echo "            Delete the principal and re-run to issue a new secret." >&2
  else
    api POST "/api/management/v1/principals" "{\"principal\":{\"name\":\"${team}\",\"type\":\"SERVICE\"}}"
    case "$API_CODE" in
      2*) ;;
      *) echo "ERROR: creating principal ${team} failed (HTTP $API_CODE)" >&2; cat "$API_BODY" >&2; exit 1 ;;
    esac
    CLIENT_ID="$(python3 -c '
import sys, json
d = json.load(sys.stdin)
c = d.get("credentials", {})
print(c.get("clientId", ""))
' < "$API_BODY")"
    CLIENT_SECRET="$(python3 -c '
import sys, json
d = json.load(sys.stdin)
c = d.get("credentials", {})
print(c.get("clientSecret", ""))
' < "$API_BODY")"
    if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
      echo "ERROR: principal created but no credentials returned." >&2; cat "$API_BODY" >&2; exit 1
    fi
    store_team_secret "$TEAM_SECRET_NAME" "$team" \
      "{\"realm\":\"${REALM}\",\"clientId\":\"${CLIENT_ID}\",\"clientSecret\":\"${CLIENT_SECRET}\"}"
    unset CLIENT_SECRET
    echo "   principal: created, credentials stored in ${TEAM_SECRET_NAME}"
  fi

  # 2. principal role -------------------------------------------------------
  api GET "/api/management/v1/principal-roles/${prole}"
  if [ "$API_CODE" = "200" ]; then
    echo "   principal-role: exists"
  else
    api POST "/api/management/v1/principal-roles" "{\"principalRole\":{\"name\":\"${prole}\"}}"
    case "$API_CODE" in 2*) echo "   principal-role: created" ;;
      *) echo "ERROR: HTTP $API_CODE" >&2; cat "$API_BODY" >&2; exit 1 ;; esac
  fi

  # 3. assign principal role to principal -----------------------------------
  api GET "/api/management/v1/principals/${team}/principal-roles"
  if grep -q "\"${prole}\"" "$API_BODY" 2>/dev/null; then
    echo "   principal-role assigned: already"
  else
    api PUT "/api/management/v1/principals/${team}/principal-roles" \
      "{\"principalRole\":{\"name\":\"${prole}\"}}"
    case "$API_CODE" in 2*) echo "   principal-role assigned" ;;
      *) echo "ERROR: HTTP $API_CODE" >&2; cat "$API_BODY" >&2; exit 1 ;; esac
  fi

  # 4. catalog role ---------------------------------------------------------
  api GET "/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles/${crole}"
  if [ "$API_CODE" = "200" ]; then
    echo "   catalog-role: exists"
  else
    api POST "/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles" \
      "{\"catalogRole\":{\"name\":\"${crole}\"}}"
    case "$API_CODE" in 2*) echo "   catalog-role: created" ;;
      *) echo "ERROR: HTTP $API_CODE" >&2; cat "$API_BODY" >&2; exit 1 ;; esac
  fi

  # 5. grants ---------------------------------------------------------------
  # State-checked before writing, because Polaris answers a duplicate grant
  # with HTTP 500 rather than 409 -- so "apply and tolerate a conflict" cannot
  # distinguish an already-applied grant from a real server error.
  api GET "/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles/${crole}/grants"
  EXISTING="$(cat "$API_BODY")"
  IFS=',' read -ra PRIV_LIST <<< "$privs"
  for priv in "${PRIV_LIST[@]}"; do
    if printf '%s' "$EXISTING" | grep -q "\"${priv}\""; then
      echo "   grant ${priv}: already"
      continue
    fi
    case "$priv" in
      CATALOG_*)
        GRANT_BODY="{\"grant\":{\"type\":\"catalog\",\"privilege\":\"${priv}\"}}" ;;
      NAMESPACE_*|TABLE_*)
        # Granted at namespace level rather than per table, so a table added to
        # the namespace tomorrow is covered without touching permissions --
        # otherwise every new table silently starts out invisible to the teams.
        # The same reasoning one level up is why finance_viewer is scoped to
        # `financial` rather than `financial.invoice`.
        [ "$ns" = "-" ] && { echo "   ${priv} needs a namespace but scope is '-', skipping" >&2; continue; }
        GRANT_BODY="{\"grant\":{\"type\":\"namespace\",\"namespace\":$(ns_json "$ns"),\"privilege\":\"${priv}\"}}" ;;
      *)
        echo "   unknown privilege class for ${priv}, skipping" >&2; continue ;;
    esac
    api PUT "/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles/${crole}/grants" "$GRANT_BODY"
    case "$API_CODE" in
      2*) echo "   grant ${priv}: added" ;;
      *)  echo "   grant ${priv}: HTTP $API_CODE" >&2; cat "$API_BODY" >&2; echo >&2
          exit 1 ;;
    esac
  done

  # 6. bind catalog role to principal role ----------------------------------
  api GET "/api/management/v1/principal-roles/${prole}/catalog-roles/${CATALOG_NAME}"
  if grep -q "\"${crole}\"" "$API_BODY" 2>/dev/null; then
    echo "   catalog-role bound: already"
  else
    api GET "/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles/${crole}"
    CR="$(cat "$API_BODY")"
    api PUT "/api/management/v1/principal-roles/${prole}/catalog-roles/${CATALOG_NAME}" \
      "{\"catalogRole\":${CR}}"
    case "$API_CODE" in 2*) echo "   catalog-role bound" ;;
      *) echo "ERROR: HTTP $API_CODE" >&2; cat "$API_BODY" >&2; exit 1 ;; esac
  fi
done

cat <<EOF

Done. Four principals now exist, each with a different reach:

  team_a           read + write   on ${CATALOG_NAME}."transactional.delivery"
  team_b           read only      on ${CATALOG_NAME}."transactional.delivery"
  finance_viewer   read only      on all of ${CATALOG_NAME}.financial
  etl              manage content catalog-wide

Credentials are in Secrets Manager, one entry per principal:
EOF
for entry in "${TEAMS[@]}"; do
  IFS='|' read -r team _ _ _ _ <<< "$entry"
  echo "  ${SECRET_PREFIX}-${team}-credentials"
done
cat <<EOF

Retrieve one with:
  aws secretsmanager get-secret-value --region ${REGION} \\
    --secret-id ${SECRET_PREFIX}-team_b-credentials --query SecretString --output text

PROVING IT WORKS
  The point of these grants is that they are enforced at the credential layer,
  not by Trino. To demonstrate that, point a second Trino catalog at Polaris
  using team_b's credential and try to write:

    INSERT INTO team_b_catalog."transactional.delivery".orders VALUES (...);

  It fails inside Polaris, before any S3 call is attempted -- team_b is never
  handed write credentials at all. Knowing the S3 path does not help either,
  because the storage role is only ever assumed by Polaris on a caller's
  behalf, never handed out standing.

  ./06_create_team_roles_prod.sh verify    # dump every principal, role and grant
EOF
