#!/usr/bin/env bash
#
# 05_create_catalog_prod.sh
#
# Registers the Iceberg catalog inside Polaris and grants the root principal
# the rights to use it. This is the step that connects the three pieces set up
# separately up to now:
#
#   Polaris (running)  +  the S3 bucket  +  the storage IAM role from 00_
#
# Until this runs, Polaris is a working server with no catalogs in it, so
# Trino and Spark have nothing to point at.
#
# WHY THE ROLE ARN IS REGISTERED PER-CATALOG, NOT IN values.yaml
# --------------------------------------------------------------
# Polaris vends credentials per catalog: each catalog carries its own storage
# role and allowed S3 prefixes, and when an engine asks to read a table
# Polaris assumes that role and hands back credentials scoped to just those
# prefixes. The role ARN is therefore a property of the catalog object,
# created through the management API -- not server-wide configuration.
#
# CONNECTIVITY: kubectl port-forward
# ----------------------------------
# The Polaris Service is ClusterIP by design, so this script tunnels to it.
# An earlier attempt at this failed in a way worth recording, because the
# fix is not obvious: `kubectl port-forward` keeps its local listener open
# even after the forwarding session behind it has broken, so a probe gets a
# reply while every real request afterwards vanishes with no error. What
# breaks the session is an aborted connection -- and the probe itself was
# aborting one, via a two-second --max-time.
#
# So the rules this script follows:
#   1. never abort a request against the tunnel (generous timeouts only)
#   2. never let a curl transport error die silently under `set -e`
#   3. verify the tunnel with a request that completes, not just connects
#   4. restart the tunnel and retry rather than failing on the first error
#
# Usage:
#   ./05_create_catalog_prod.sh          # create catalog + grants (idempotent)
#   ./05_create_catalog_prod.sh verify   # show current state, change nothing
#   ./05_create_catalog_prod.sh clean    # delete the catalog, for a fresh start
#   ./05_create_catalog_prod.sh tunnel   # just hold a tunnel open for manual curl
#
set -euo pipefail

REGION="ap-southeast-1"
NAMESPACE="data-platform"
RELEASE_NAME="polaris"
CATALOG_NAME="data_platform"
WAREHOUSE_BUCKET="data-store-prod-warehouse"

# allowedLocations / default-base-location are set to the BUCKET ROOT, not the
# five classification prefixes directly, and that is deliberate rather than
# looser than before -- Polaris computes a namespace's default (and validates
# any custom) location as {allowedLocation}/{namespace-name}/, i.e. a
# namespace always has to sit one level *below* an allowedLocation, never
# equal to one. Pointing allowedLocations at the five prefixes themselves
# (financial, transactional, ...) made it impossible to ever create a
# namespace named "financial", because Polaris would only accept it nested
# a level deeper than the "financial" prefix -- a namespace cannot be nested
# under itself. Root-caused when 07_create_dg_namespaces_prod.sh's first
# create_namespace call came back:
#   "Namespace financial has a custom location, which is not enabled.
#    Expected a location in: [.../financial/financial/, .../operational/financial/, ...]"
#
# Moving the boundary up to the bucket root lets financial/transactional/
# operational/derived/aggregate exist as ordinary first-level namespaces
# directly under it, each supplying its own location explicitly at creation
# time (see 07_) -- which then becomes the effective allowedLocation for
# everything nested under it.
#
# This does not, on its own, loosen who can write outside the five
# classified prefixes: the storage role's IAM policy
# (s3-storage-access-policy.json, applied in 00_) is scoped to exactly the
# five prefixes and is a hard boundary Polaris cannot vend around. Widening
# this catalog-level setting only widens Polaris's own namespace-location
# bookkeeping check, which was already redundant with the five-prefix IAM
# policy for this purpose -- classification enforcement still lives at the
# IAM layer, not here.
ALLOWED_LOCATIONS_JSON="[\"s3://${WAREHOUSE_BUCKET}\"]"

# Where a table lands if CREATE SCHEMA / CREATE TABLE omits an explicit
# LOCATION *and* isn't created under one of the five category namespaces --
# i.e. it fell outside the classification scheme entirely. The bucket root
# itself is not covered by the IAM policy's five prefixes, so vending
# credentials for anything landing here will fail loudly rather than
# silently writing into an unclassified, un-lifecycled location. That is the
# intended behaviour: force the mistake to surface immediately instead of
# quietly reproducing the old "warehouse/" bug in a new shape.
BASE_LOCATION="s3://${WAREHOUSE_BUCKET}"
ROOT_SECRET="data-platform-prod-polaris-root-credentials"
ENV_FILE="$HOME/.data-platform.env"
LOCAL_PORT="18181"
API_URL="http://localhost:${LOCAL_PORT}"
IN_CLUSTER_URI="http://${RELEASE_NAME}.${NAMESPACE}.svc.cluster.local:8181/api/catalog"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need kubectl
need curl
need aws
need python3   # stands in for jq, which macOS does not ship

# ---------------------------------------------------------------------------
# JSON helpers (python3 rather than jq, and tolerant of non-JSON input: an
# error response from Polaris is sometimes plain text, and a traceback there
# would hide the HTTP status, which is the useful part)
# ---------------------------------------------------------------------------
json_get() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(d.get(sys.argv[1], "") if isinstance(d, dict) else "")
' "$1"
}
json_pretty() { python3 -m json.tool 2>/dev/null || cat; }

# ---------------------------------------------------------------------------
# Tunnel management
# ---------------------------------------------------------------------------
PF_PID=""
PF_LOG="$(mktemp)"
cleanup() {
  if [ -n "$PF_PID" ]; then
    kill "$PF_PID" 2>/dev/null || true
    # Reap it. Without this, bash prints its own "Terminated: 15" notice about
    # the killed background job after the script has already finished, which
    # reads like an error in an otherwise successful run.
    wait "$PF_PID" 2>/dev/null || true
  fi
  rm -f "$PF_LOG" 2>/dev/null || true
}
trap cleanup EXIT

start_tunnel() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  kubectl port-forward -n "$NAMESPACE" "svc/${RELEASE_NAME}" "${LOCAL_PORT}:8181" \
    >"$PF_LOG" 2>&1 &
  PF_PID=$!

  # Wait for a request that *completes*. Note the 10s timeout, not 2s: cutting
  # a request short is what poisons the forwarding session in the first place.
  local i code
  for i in $(seq 1 20); do
    if ! kill -0 "$PF_PID" 2>/dev/null; then
      echo "ERROR: port-forward exited immediately. Output was:" >&2
      cat "$PF_LOG" >&2
      return 1
    fi
    set +e
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
      "${API_URL}/api/catalog/v1/config")"
    set -e
    # Any status code means the request reached Polaris; 401 is expected here
    # because /v1/config needs auth. Only an empty code means "not yet".
    [ -n "$code" ] && [ "$code" != "000" ] && return 0
    sleep 1
  done
  echo "ERROR: tunnel never carried a complete request." >&2
  cat "$PF_LOG" >&2
  return 1
}

# api METHOD PATH [JSON_BODY]
# Sets API_CODE and writes the response body to $API_BODY.
# Retries once through a fresh tunnel on a transport error, since that is the
# signature of a broken forwarding session rather than a server problem.
API_BODY="$(mktemp)"
api() {
  local method="$1" path="$2" body="${3:-}" attempt rc
  for attempt in 1 2; do
    set +e
    if [ -n "$body" ]; then
      API_CODE="$(curl -s -o "$API_BODY" -w '%{http_code}' --max-time 30 -X "$method" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Polaris-Realm: ${REALM}" \
        -H 'Content-Type: application/json' \
        -d "$body" "${API_URL}${path}")"
    else
      API_CODE="$(curl -s -o "$API_BODY" -w '%{http_code}' --max-time 30 -X "$method" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Polaris-Realm: ${REALM}" \
        "${API_URL}${path}")"
    fi
    rc=$?
    set -e
    [ $rc -eq 0 ] && return 0
    echo "      transport error (curl exit $rc) -- restarting the tunnel and retrying" >&2
    start_tunnel || return 1
  done
  echo "ERROR: ${method} ${path} failed at the transport level." >&2
  return 1
}

get_token() {
  local rc
  # client_id / client_secret go in the form body, not curl --user: Polaris's
  # HTTP Basic path has a decoding bug (apache/polaris#3354) that answers with
  # a 400 whose body is not even JSON.
  set +e
  API_CODE="$(curl -s -o "$API_BODY" -w '%{http_code}' --max-time 30 -X POST \
    "${API_URL}/api/catalog/v1/oauth/tokens" \
    -H "Polaris-Realm: ${REALM}" \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "client_secret=${CLIENT_SECRET}" \
    --data-urlencode 'scope=PRINCIPAL_ROLE:ALL')"
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    echo "ERROR: token request failed at the transport level (curl exit $rc)." >&2
    return 1
  fi
  TOKEN="$(json_get access_token < "$API_BODY")"
  if [ -z "$TOKEN" ]; then
    echo "ERROR: no access_token returned (HTTP $API_CODE)." >&2
    echo "--- response body ---" >&2; cat "$API_BODY" >&2; echo >&2
    echo "  401 -> credentials in '$ROOT_SECRET' do not match the bootstrapped realm" >&2
    echo "  404 -> internal token service disabled in values.yaml" >&2
    echo "  400/500 -> realm '$REALM' has no schema; re-run 03_" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 1. Credentials and IAM details
# ---------------------------------------------------------------------------
echo "[1/4] Reading root credentials and storage role..."
ROOT_JSON="$(aws secretsmanager get-secret-value --secret-id "$ROOT_SECRET" --region "$REGION" \
  --query 'SecretString' --output text 2>/dev/null)" \
  || { echo "ERROR: secret '$ROOT_SECRET' not found. Run 03_bootstrap_polaris_realm_prod.sh first." >&2; exit 1; }

REALM="$(printf '%s' "$ROOT_JSON"         | json_get realm)"
CLIENT_ID="$(printf '%s' "$ROOT_JSON"     | json_get clientId)"
CLIENT_SECRET="$(printf '%s' "$ROOT_JSON" | json_get clientSecret)"
[ -n "$REALM" ] && [ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] \
  || { echo "ERROR: '$ROOT_SECRET' does not contain realm/clientId/clientSecret." >&2; exit 1; }

# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
STORAGE_ROLE_ARN="${POLARIS_STORAGE_ROLE_ARN:-}"
EXTERNAL_ID="${POLARIS_STORAGE_EXTERNAL_ID:-}"
if [ -z "$STORAGE_ROLE_ARN" ] || [ -z "$EXTERNAL_ID" ]; then
  echo "ERROR: POLARIS_STORAGE_ROLE_ARN / POLARIS_STORAGE_EXTERNAL_ID not in $ENV_FILE." >&2
  echo "       Run 00_create_polaris_storage_role_prod.sh (it writes both)." >&2
  exit 1
fi
echo "      realm=$REALM  storage role=${STORAGE_ROLE_ARN##*/}"

# ---------------------------------------------------------------------------
# 2. Pod readiness, then tunnel
# ---------------------------------------------------------------------------
echo "[2/4] Checking Polaris is Ready..."
READY="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=polaris \
  -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)"
[ "$READY" = "true" ] || {
  echo "ERROR: the Polaris pod is not Ready (got '${READY:-none}')." >&2
  kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=polaris >&2 || true
  # A Pending pod on a cluster with no nodes is the normal morning-after state
  # of scale_down.sh, not a Polaris problem -- say so rather than sending
  # someone to read logs that do not exist yet.
  if [ -z "$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"')" ]; then
    echo "" >&2
    echo "       No Ready node exists -- the node groups are scaled to zero." >&2
    echo "       This is what scale_down.sh leaves behind. Bring it back with:" >&2
    echo "         ../../../scale/scale_up.sh" >&2
  else
    echo "       Logs will say why:  ./04_install_polaris_prod.sh logs" >&2
  fi
  exit 1
}
echo "      ready"

echo "[3/4] Opening tunnel on localhost:${LOCAL_PORT}..."
start_tunnel || exit 1
echo "      tunnel carrying requests"

# `tunnel` mode: hold it open for interactive poking and stop here.
if [ "$MODE" = "tunnel" ]; then
  cat <<EOF

Tunnel is open at ${API_URL} and will stay up until you press Ctrl-C.

Get a token:
  TOKEN=\$(curl -s -X POST ${API_URL}/api/catalog/v1/oauth/tokens \\
    -H 'Polaris-Realm: ${REALM}' \\
    -d grant_type=client_credentials -d client_id=${CLIENT_ID} \\
    -d client_secret=<from Secrets Manager> -d scope=PRINCIPAL_ROLE:ALL \\
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

Then, for example:
  curl -s -H "Authorization: Bearer \$TOKEN" -H 'Polaris-Realm: ${REALM}' \\
    ${API_URL}/api/management/v1/catalogs | python3 -m json.tool

EOF
  wait "$PF_PID"
  exit 0
fi

echo "[4/4] Authenticating..."
get_token || exit 1
echo "      token acquired"

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
if [ "$MODE" = "verify" ]; then
  echo ""
  echo "=== catalogs ==="
  api GET "/api/management/v1/catalogs" && cat "$API_BODY" | json_pretty
  echo ""
  echo "=== grants on catalog_admin ==="
  api GET "/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles/catalog_admin/grants" \
    && cat "$API_BODY" | json_pretty
  echo ""
  echo "=== catalog_admin assigned to service_admin? ==="
  api GET "/api/management/v1/principal-roles/service_admin/catalog-roles/${CATALOG_NAME}" \
    && cat "$API_BODY" | json_pretty
  echo ""
  echo "=== catalog roles (a non-default one blocks catalog deletion) ==="
  api GET "/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles" \
    && cat "$API_BODY" | json_pretty
  echo ""
  echo "=== namespaces (the call Trino/Spark make) ==="
  api GET "/api/catalog/v1/${CATALOG_NAME}/namespaces"
  echo "HTTP $API_CODE"; cat "$API_BODY" | json_pretty
  exit 0
fi

# ---------------------------------------------------------------------------
# clean
# ---------------------------------------------------------------------------
if [ "$MODE" = "clean" ]; then
  echo ""
  echo "This deletes catalog '${CATALOG_NAME}' from Polaris, including every"
  echo "namespace and table registered under it."
  echo ""
  echo "Table DATA in S3 is not deleted -- the Parquet files stay where they"
  echo "are and simply become unreferenced, which also means they keep costing"
  echo "money until something removes them."
  read -r -p "Type the catalog name to confirm: " confirm
  [ "$confirm" = "$CATALOG_NAME" ] || { echo "Did not match. Aborted."; exit 0; }

  # Polaris refuses to drop a non-empty catalog, the same way Postgres refuses
  # to drop a database with objects in it. Rather than making the operator go
  # and hunt for what is inside, walk the tree and empty it first.
  echo ""
  echo "-- emptying the catalog --"
  api GET "/api/catalog/v1/${CATALOG_NAME}/namespaces"
  NAMESPACES="$(python3 -c '
import sys, json
try:    d = json.load(sys.stdin)
except Exception: sys.exit(0)
# Namespaces come back as lists of parts, e.g. [["delivery"]] -- join nested
# ones with the unit separator Iceberg uses in URLs.
for ns in d.get("namespaces", []):
    print("".join(ns))
' < "$API_BODY" || true)"

  if [ -z "$NAMESPACES" ]; then
    echo "   (already empty)"
  else
    while IFS= read -r ns; do
      [ -n "$ns" ] || continue
      # %1F is the URL-encoded separator for a multi-level namespace.
      NS_ENC="$(printf '%s' "$ns" | python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read(), safe=""))')"

      api GET "/api/catalog/v1/${CATALOG_NAME}/namespaces/${NS_ENC}/tables"
      TABLES="$(python3 -c '
import sys, json
try:    d = json.load(sys.stdin)
except Exception: sys.exit(0)
for t in d.get("identifiers", []):
    print(t.get("name",""))
' < "$API_BODY" || true)"

      while IFS= read -r tbl; do
        [ -n "$tbl" ] || continue
        # purgeRequested=true asks Polaris to delete the data files too. Without
        # it the table disappears from the catalog while its Parquet files stay
        # in S3 forever, unreferenced and unbilled to anyone's attention.
        api DELETE "/api/catalog/v1/${CATALOG_NAME}/namespaces/${NS_ENC}/tables/${tbl}?purgeRequested=true"
        echo "   dropped table ${ns}.${tbl} (HTTP $API_CODE)"
      done <<< "$TABLES"

      api DELETE "/api/catalog/v1/${CATALOG_NAME}/namespaces/${NS_ENC}"
      echo "   dropped namespace ${ns} (HTTP $API_CODE)"
    done <<< "$NAMESPACES"
  fi

  # "Not empty" is not only about namespaces. A catalog also owns its catalog
  # roles, and any role beyond the built-in catalog_admin blocks deletion the
  # same way a namespace does -- with the identical, unhelpfully generic
  # "cannot be dropped, it is not empty" message. 06_create_team_roles_prod.sh
  # creates three (team_a_readwrite, team_b_readonly, etl_writer), so a catalog
  # that looks completely empty by namespace listing can still refuse to drop.
  echo ""
  echo "-- removing non-default catalog roles --"
  api GET "/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles"
  CATALOG_ROLES="$(python3 -c '
import sys, json
try:    d = json.load(sys.stdin)
except Exception: sys.exit(0)
for r in d.get("roles", []):
    n = r.get("name", "")
    # catalog_admin is created by Polaris with the catalog and is removed with
    # it; trying to delete it explicitly is an error, not a no-op.
    if n and n != "catalog_admin":
        print(n)
' < "$API_BODY" || true)"

  if [ -z "$CATALOG_ROLES" ]; then
    echo "   (none beyond catalog_admin)"
  else
    while IFS= read -r role; do
      [ -n "$role" ] || continue
      api DELETE "/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles/${role}"
      echo "   dropped catalog role ${role} (HTTP $API_CODE)"
    done <<< "$CATALOG_ROLES"
  fi

  echo ""
  echo "-- deleting the catalog --"
  api DELETE "/api/management/v1/catalogs/${CATALOG_NAME}"
  echo "HTTP $API_CODE"
  case "$API_CODE" in
    2*|404) echo "catalog is gone" ;;
    *) echo "response:"; cat "$API_BODY"; echo ""
       echo "NOTE: something is still inside the catalog -- either a namespace or" >&2
       echo "      a catalog role. Both are listed by:" >&2
       echo "        ./05_create_catalog_prod.sh verify" >&2
       exit 1 ;;
  esac
  echo ""
  echo "Recreate it with:  ./05_create_catalog_prod.sh"
  exit 0
fi

# ---------------------------------------------------------------------------
# deploy
# ---------------------------------------------------------------------------
echo ""
echo "== catalog =="
api GET "/api/management/v1/catalogs/${CATALOG_NAME}"
if [ "$API_CODE" = "200" ]; then
  echo "   already exists, leaving it alone"
else
  # allowedLocations is the hard boundary of what vended credentials can ever
  # reach: even a compromised engine cannot be handed credentials outside it.
  api POST "/api/management/v1/catalogs" "$(cat <<JSON
{"catalog":{"name":"${CATALOG_NAME}","type":"INTERNAL",
 "properties":{"default-base-location":"${BASE_LOCATION}"},
 "storageConfigInfo":{"storageType":"S3","roleArn":"${STORAGE_ROLE_ARN}",
   "externalId":"${EXTERNAL_ID}","region":"${REGION}",
   "allowedLocations":${ALLOWED_LOCATIONS_JSON}}}}
JSON
)"
  case "$API_CODE" in
    2*) echo "   created" ;;
    *)  echo "ERROR: creation returned HTTP $API_CODE" >&2; cat "$API_BODY" >&2; echo >&2; exit 1 ;;
  esac
fi

# Polaris authorises through a chain: principal -> principal-role ->
# catalog-role -> privileges on a catalog. Creating the catalog alone grants
# nobody the right to use it.
#
# Both writes below are state-checked first rather than applied blindly,
# because Polaris answers a duplicate with HTTP 500 rather than 409 -- so a
# real server error and an already-applied grant are indistinguishable from
# the status code alone.

echo "== grant CATALOG_MANAGE_CONTENT to catalog_admin =="
api GET "/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles/catalog_admin/grants"
if grep -q "CATALOG_MANAGE_CONTENT" "$API_BODY" 2>/dev/null; then
  echo "   already granted"
else
  api PUT "/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles/catalog_admin/grants" \
    '{"grant":{"type":"catalog","privilege":"CATALOG_MANAGE_CONTENT"}}'
  case "$API_CODE" in
    2*) echo "   granted" ;;
    *)  echo "ERROR: HTTP $API_CODE" >&2; cat "$API_BODY" >&2; echo >&2; exit 1 ;;
  esac
fi

echo "== assign catalog_admin to service_admin =="
api GET "/api/management/v1/principal-roles/service_admin/catalog-roles/${CATALOG_NAME}"
if grep -q "catalog_admin" "$API_BODY" 2>/dev/null; then
  echo "   already assigned"
else
  # Send the catalog-role object exactly as Polaris returns it rather than a
  # hand-built {"name":"catalog_admin"}: entities carry an entityVersion for
  # optimistic concurrency, and a partial object fails server-side.
  api GET "/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles/catalog_admin"
  CR="$(cat "$API_BODY")"
  case "$CR" in
    *'"name"'*) ;;
    *) echo "ERROR: could not read the catalog_admin role" >&2; echo "$CR" >&2; exit 1 ;;
  esac
  api PUT "/api/management/v1/principal-roles/service_admin/catalog-roles/${CATALOG_NAME}" \
    "{\"catalogRole\":${CR}}"
  case "$API_CODE" in
    2*) echo "   assigned" ;;
    *)  echo "ERROR: HTTP $API_CODE" >&2; cat "$API_BODY" >&2; echo >&2
        echo "principal roles that exist:" >&2
        api GET "/api/management/v1/principal-roles" && cat "$API_BODY" >&2; echo >&2
        exit 1 ;;
  esac
fi

# Final proof the chain resolves: the same call Trino and Spark make. A 200
# here means the catalog is genuinely usable, not merely present.
echo "== end-to-end check: list namespaces =="
api GET "/api/catalog/v1/${CATALOG_NAME}/namespaces"
echo "   HTTP $API_CODE  $(cat "$API_BODY")"
case "$API_CODE" in
  2*) echo "   catalog is usable" ;;
  *)  echo "ERROR: catalog exists but cannot be used -- the grant chain is incomplete" >&2; exit 1 ;;
esac

# Persist for the Trino and Spark setup steps that come next.
grep -v -E '^(POLARIS_CATALOG_NAME|POLARIS_BASE_LOCATION|POLARIS_URI)=' "$ENV_FILE" 2>/dev/null > "${ENV_FILE}.tmp" || true
{
  cat "${ENV_FILE}.tmp" 2>/dev/null
  echo "POLARIS_CATALOG_NAME=${CATALOG_NAME}"
  echo "POLARIS_BASE_LOCATION=${BASE_LOCATION}"
  echo "POLARIS_URI=${IN_CLUSTER_URI}"
} > "$ENV_FILE"
rm -f "${ENV_FILE}.tmp"

cat <<EOF

Catalog '${CATALOG_NAME}' registered.

  base location : ${BASE_LOCATION}
  storage role  : ${STORAGE_ROLE_ARN}
  catalog URI   : ${IN_CLUSTER_URI}

  ./05_create_catalog_prod.sh verify   # full state dump
  ./05_create_catalog_prod.sh tunnel   # hold a tunnel open for manual curl

Next: Trino, pointed at that URI with the iceberg connector.
EOF
