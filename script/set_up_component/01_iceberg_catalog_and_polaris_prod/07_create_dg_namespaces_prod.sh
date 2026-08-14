#!/usr/bin/env bash
#
# 07_create_dg_namespaces_prod.sh
#
# Creates the namespace tree inside the (single) Polaris catalog
# 'data_platform'. Three levels, combining two independent ideas:
#
#   catalog data_platform
#   └── <medallion>                bronze | silver | gold      -- processing stage
#         └── <dg-category>        financial, transactional…   -- retention class
#               └── <domain>       invoice, delivery…          -- business area
#                     └── table
#
# and mirrored exactly onto S3:
#
#   s3://data-store-prod-warehouse/bronze/financial/invoice/<table>/
#
# WHY BOTH DIMENSIONS, AND WHY IN THIS ORDER
# -------------------------------------------
# Medallion and data-governance category answer different questions and neither
# substitutes for the other:
#
#   medallion  -- how far through processing this data is, and therefore
#                 whether it can be recomputed. Silver and gold are derivable
#                 from bronze; bronze is not derivable from anything.
#   category   -- what *kind* of data it is, and therefore how long it must be
#                 kept and whether it may be deleted automatically at all.
#                 financial data is never auto-deleted regardless of which
#                 medallion layer it sits in.
#
# Medallion goes first because it is the coarser and more stable split: a table
# moves between domains occasionally and between medallion layers essentially
# never. Lifecycle rules therefore key on the two-segment prefix
# (`bronze/financial/`), one rule per combination -- six of them, the same
# number as before this structure was introduced.
#
# THE REDUNDANCY IN silver/derived AND gold/aggregate IS DELIBERATE
# ------------------------------------------------------------------
# `silver/` contains only `derived/`, and `gold/` only `aggregate/`, so those
# second segments carry no information the first does not. They are kept anyway
# so that every table path has the same shape -- medallion/category/domain/table
# -- which means one lifecycle-rule pattern, one grant pattern, and one mental
# model rather than a special case for two of the three layers.
#
# EVERYTHING IS LOWERCASE ON PURPOSE
# -----------------------------------
# S3 accepts mixed-case prefixes, but Trino lowercases any SQL identifier that
# is not double-quoted. A namespace called `Bronze` would have to be written
# `"Bronze"."Financial"` at every use site, and forgetting the quotes produces
# "schema not found" rather than an error that explains itself.
#
# Usage:
#   ./07_create_dg_namespaces_prod.sh          # create tree (idempotent)
#   ./07_create_dg_namespaces_prod.sh verify   # list what exists, change nothing
#   ./07_create_dg_namespaces_prod.sh clean    # drop what LEAVES describes
#   ./07_create_dg_namespaces_prod.sh prune    # drop what LEAVES does NOT describe
#
# CLEAN VERSUS PRUNE
# -------------------
# `clean` deletes the namespaces this file currently lists. That is only the
# right tool while the file still describes what is in the catalog.
#
# Editing LEAVES and then running `clean` deletes the *new* names -- which do
# not exist yet -- and leaves the old ones behind as orphans that nothing in
# this repository mentions any more. That happened when the layout changed from
# `financial/invoice` to `bronze/financial/invoice`: twelve namespaces from the
# previous scheme stayed in the catalog, invisible to `clean` and visible to
# anyone running SHOW SCHEMAS.
#
# `prune` works the other way round: it walks the catalog as it actually is,
# compares against LEAVES, and removes whatever is not accounted for. Use it
# after changing the layout, and as a periodic check that the catalog and this
# file still agree.
#
# REQUIRES the catalog from 05_create_catalog_prod.sh to have allowedLocations
# set to the bucket root. Polaris validates a namespace location as
# {allowedLocation}/{namespace-name}/, so a namespace can only ever sit one
# level below an allowedLocation -- see the comment in 05_ for the HTTP 400
# this produced when the prefixes themselves were the allowed locations.
#
set -euo pipefail

REGION="ap-southeast-1"
NAMESPACE="data-platform"
RELEASE_NAME="polaris"
CATALOG_NAME="data_platform"
WAREHOUSE_BUCKET="data-store-prod-warehouse"
ROOT_SECRET="data-platform-prod-polaris-root-credentials"
LOCAL_PORT="18182"   # different port from 05_'s 18181 so both can run back to back
API_URL="http://localhost:${LOCAL_PORT}"
MODE="${1:-deploy}"

# medallion:category:domain
#
# Only the leaves are listed. The medallion and category levels above each leaf
# are created automatically, so there is no second list to keep in step with
# this one -- a mismatch between them would show up as a namespace that exists
# with no parent, which Polaris rejects in a way that is tedious to diagnose.
#
# The domains here are examples, one per category. Add rows as real domains
# appear; nothing else in this script changes.
#
# Note on "log": this refers to structured log *tables* (query audit trails,
# access records that engines read with SQL). Raw log *files* -- stdout, stack
# traces -- live in the separate data-store-*-logs bucket, are written by the
# log shipper rather than by a query engine, and have no namespace here.
LEAVES=(
  "bronze:financial:invoice"
  "bronze:transactional:delivery"
  "bronze:operational:driver_location"
  "bronze:log:query_audit"
  "silver:derived:orders_cleaned"
  "gold:aggregate:merchant_sales_summary"

  # The NYC TLC pipeline. Trip records stand in for delivery records: same
  # shape of problem (a timestamped journey with a fare, a distance and two
  # locations), and public data that a reviewer can fetch and check against.
  #
  # They sit under the SAME category names as the rest of the tree rather than
  # in a "taxi" branch of their own, because the categories describe what the
  # data IS to the business -- transactional, derived, aggregate -- not where
  # it came from. A per-source top level is what turns a catalog into a folder
  # of folders nobody can find anything in.
  "bronze:transactional:taxi_trip"
  "silver:derived:taxi_trip_cleaned"
  "gold:aggregate:taxi_daily_zone_revenue"
)

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need kubectl; need curl; need aws; need python3

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
# Namespace path helpers
#
# The Iceberg REST spec addresses a multi-level namespace as its parts joined
# by the ASCII unit separator (0x1F), URL-encoded as %1F. That is a real
# character in the URL, not a visible delimiter, which is why this goes through
# python rather than string concatenation.
# ---------------------------------------------------------------------------
ns_json()    { python3 -c 'import sys,json; print(json.dumps(sys.argv[1:]))' "$@"; }
ns_segment() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote("\x1f".join(sys.argv[1:]), safe=""))' "$@"; }
ns_display() { local IFS=.; echo "$*"; }

# Expand the leaves into every level that has to exist, parents before
# children, with duplicates removed. bronze appears in four leaves and must be
# created once.
all_namespaces() {
  local leaf med cat dom
  {
    for leaf in "${LEAVES[@]}"; do
      IFS=':' read -r med cat dom <<< "$leaf"
      echo "$med"
      echo "$med:$cat"
      echo "$med:$cat:$dom"
    done
  } | awk '!seen[$0]++'
}

# ---------------------------------------------------------------------------
# Tunnel management -- same rules as 05_create_catalog_prod.sh: never abort a
# request against the tunnel, verify with a request that completes, restart and
# retry on a transport error. See that script's header for why.
# ---------------------------------------------------------------------------
PF_PID=""
PF_LOG="$(mktemp)"
API_BODY="$(mktemp)"
cleanup() {
  if [ -n "$PF_PID" ]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
  rm -f "$PF_LOG" "$API_BODY" 2>/dev/null || true
}
trap cleanup EXIT

start_tunnel() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  kubectl port-forward -n "$NAMESPACE" "svc/${RELEASE_NAME}" "${LOCAL_PORT}:8181" \
    >"$PF_LOG" 2>&1 &
  PF_PID=$!

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
    [ -n "$code" ] && [ "$code" != "000" ] && return 0
    sleep 1
  done
  echo "ERROR: tunnel never carried a complete request." >&2
  cat "$PF_LOG" >&2
  return 1
}

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
    cat "$API_BODY" >&2; echo >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
echo "[1/3] Reading root credentials..."
ROOT_JSON="$(aws secretsmanager get-secret-value --secret-id "$ROOT_SECRET" --region "$REGION" \
  --query 'SecretString' --output text 2>/dev/null)" \
  || { echo "ERROR: secret '$ROOT_SECRET' not found. Run 03_bootstrap_polaris_realm_prod.sh first." >&2; exit 1; }
REALM="$(printf '%s' "$ROOT_JSON"         | json_get realm)"
CLIENT_ID="$(printf '%s' "$ROOT_JSON"     | json_get clientId)"
CLIENT_SECRET="$(printf '%s' "$ROOT_JSON" | json_get clientSecret)"
[ -n "$REALM" ] && [ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] \
  || { echo "ERROR: '$ROOT_SECRET' does not contain realm/clientId/clientSecret." >&2; exit 1; }

echo "[2/3] Opening tunnel on localhost:${LOCAL_PORT}..."
start_tunnel || exit 1
echo "      tunnel carrying requests"

echo "[3/3] Authenticating..."
get_token || exit 1
echo "      token acquired"

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
if [ "$MODE" = "verify" ]; then
  echo ""
  echo "=== top-level namespaces ==="
  api GET "/api/catalog/v1/${CATALOG_NAME}/namespaces"
  cat "$API_BODY" | json_pretty
  echo ""
  echo "=== every namespace this script manages ==="
  while IFS= read -r ns; do
    [ -n "$ns" ] || continue
    IFS=':' read -ra PARTS <<< "$ns"
    api GET "/api/catalog/v1/${CATALOG_NAME}/namespaces/$(ns_segment "${PARTS[@]}")"
    LOC="$(python3 -c '
import sys, json
try:    d = json.load(sys.stdin)
except Exception: sys.exit(0)
print(d.get("properties", {}).get("location", ""))
' < "$API_BODY" || true)"
    printf '  %-45s HTTP %-4s %s\n' "$(ns_display "${PARTS[@]}")" "$API_CODE" "$LOC"
  done < <(all_namespaces)
  exit 0
fi

# ---------------------------------------------------------------------------
# clean -- deepest first, since a namespace with children cannot be dropped
# ---------------------------------------------------------------------------
if [ "$MODE" = "clean" ]; then
  echo ""
  echo "This drops every namespace listed by this script from catalog"
  echo "'${CATALOG_NAME}', and any tables inside them with purgeRequested=true"
  echo "(which deletes their data files from S3 as well). It does not touch"
  echo "other namespaces or the catalog itself."
  read -r -p "Type 'clean' to confirm: " confirm
  [ "$confirm" = "clean" ] || { echo "Did not match. Aborted."; exit 0; }

  # Reverse order puts domains before categories before medallions.
  while IFS= read -r ns; do
    [ -n "$ns" ] || continue
    IFS=':' read -ra PARTS <<< "$ns"
    SEG="$(ns_segment "${PARTS[@]}")"
    DISP="$(ns_display "${PARTS[@]}")"

    api GET "/api/catalog/v1/${CATALOG_NAME}/namespaces/${SEG}/tables"
    TABLES="$(python3 -c '
import sys, json
try:    d = json.load(sys.stdin)
except Exception: sys.exit(0)
for t in d.get("identifiers", []):
    print(t.get("name",""))
' < "$API_BODY" || true)"
    while IFS= read -r tbl; do
      [ -n "$tbl" ] || continue
      api DELETE "/api/catalog/v1/${CATALOG_NAME}/namespaces/${SEG}/tables/${tbl}?purgeRequested=true"
      echo "   dropped table ${DISP}.${tbl} (HTTP $API_CODE)"
    done <<< "$TABLES"

    api DELETE "/api/catalog/v1/${CATALOG_NAME}/namespaces/${SEG}"
    case "$API_CODE" in
      2*|404) echo "   dropped namespace ${DISP} (HTTP $API_CODE)" ;;
      *)      echo "   kept ${DISP} (HTTP $API_CODE -- probably still has children)" ;;
    esac
  done < <(all_namespaces | tail -r 2>/dev/null || all_namespaces | tac)
  exit 0
fi

# ---------------------------------------------------------------------------
# prune -- delete everything in the catalog that LEAVES does not describe
# ---------------------------------------------------------------------------
if [ "$MODE" = "prune" ]; then
  # Walk the real tree. The REST API lists one level at a time via
  # ?parent=<encoded>, so this recurses breadth-first, keeping each namespace
  # as its ':'-joined parts to match the format all_namespaces() produces.
  discovered=""
  queue=""   # namespaces whose children have not been listed yet; "" = root

  list_children() {
    local parent_param=""
    if [ -n "$1" ]; then
      IFS=':' read -ra PP <<< "$1"
      parent_param="?parent=$(ns_segment "${PP[@]}")"
    fi
    api GET "/api/catalog/v1/${CATALOG_NAME}/namespaces${parent_param}"
    python3 -c '
import sys, json
try:    d = json.load(sys.stdin)
except Exception: sys.exit(0)
for ns in d.get("namespaces", []):
    print(":".join(ns))
' < "$API_BODY" || true
  }

  echo ""
  echo "-- walking the catalog --"
  current="$(list_children "")"
  while [ -n "$current" ]; do
    next=""
    while IFS= read -r ns; do
      [ -n "$ns" ] || continue
      discovered="${discovered}${ns}"$'\n'
      kids="$(list_children "$ns")"
      [ -n "$kids" ] && next="${next}${kids}"$'\n'
    done <<< "$current"
    current="$(printf '%s' "$next" | sed '/^$/d')"
  done
  discovered="$(printf '%s' "$discovered" | sed '/^$/d')"
  echo "   found $(printf '%s\n' "$discovered" | grep -c . || true) namespace(s)"

  EXPECTED="$(all_namespaces)"
  # Namespaces present in the catalog but absent from LEAVES.
  ORPHANS="$(comm -23 <(printf '%s\n' "$discovered" | sort) <(printf '%s\n' "$EXPECTED" | sort) || true)"

  if [ -z "$ORPHANS" ]; then
    echo "   nothing to prune -- the catalog matches this file"
    exit 0
  fi

  echo ""
  echo "These exist in the catalog but are not described by LEAVES:"
  while IFS= read -r ns; do
    [ -n "$ns" ] || continue
    IFS=':' read -ra PARTS <<< "$ns"
    echo "   $(ns_display "${PARTS[@]}")"
  done <<< "$ORPHANS"
  echo ""
  echo "Dropping them also drops any tables inside, with purgeRequested=true,"
  echo "which deletes those tables' data files from S3."
  read -r -p "Type 'prune' to confirm: " confirm
  [ "$confirm" = "prune" ] || { echo "Did not match. Aborted."; exit 0; }

  echo ""
  # Longest paths first: a namespace with children cannot be dropped, and
  # sorting by depth is what makes leaves come before their parents.
  while IFS= read -r ns; do
    [ -n "$ns" ] || continue
    IFS=':' read -ra PARTS <<< "$ns"
    SEG="$(ns_segment "${PARTS[@]}")"
    DISP="$(ns_display "${PARTS[@]}")"

    api GET "/api/catalog/v1/${CATALOG_NAME}/namespaces/${SEG}/tables"
    TABLES="$(python3 -c '
import sys, json
try:    d = json.load(sys.stdin)
except Exception: sys.exit(0)
for t in d.get("identifiers", []):
    print(t.get("name",""))
' < "$API_BODY" || true)"
    while IFS= read -r tbl; do
      [ -n "$tbl" ] || continue
      api DELETE "/api/catalog/v1/${CATALOG_NAME}/namespaces/${SEG}/tables/${tbl}?purgeRequested=true"
      echo "   dropped table ${DISP}.${tbl} (HTTP $API_CODE)"
    done <<< "$TABLES"

    api DELETE "/api/catalog/v1/${CATALOG_NAME}/namespaces/${SEG}"
    case "$API_CODE" in
      2*|404) echo "   dropped ${DISP} (HTTP $API_CODE)" ;;
      *)      echo "   kept ${DISP} (HTTP $API_CODE)"; cat "$API_BODY"; echo "" ;;
    esac
  done < <(printf '%s\n' "$ORPHANS" | awk -F: '{print NF"\t"$0}' | sort -rn -k1,1 | cut -f2-)

  echo ""
  echo "Re-check with:  ./07_create_dg_namespaces_prod.sh prune"
  exit 0
fi

# ---------------------------------------------------------------------------
# deploy
# ---------------------------------------------------------------------------
create_namespace() {
  local location="$1"; shift
  local parts_json seg disp
  parts_json="$(ns_json "$@")"
  seg="$(ns_segment "$@")"
  disp="$(ns_display "$@")"

  api GET "/api/catalog/v1/${CATALOG_NAME}/namespaces/${seg}"
  if [ "$API_CODE" = "200" ]; then
    printf '   %-45s exists\n' "$disp"
    return 0
  fi

  api POST "/api/catalog/v1/${CATALOG_NAME}/namespaces" \
    "{\"namespace\":${parts_json},\"properties\":{\"location\":\"${location}\"}}"
  case "$API_CODE" in
    2*) printf '   %-45s created  ->  %s\n' "$disp" "$location" ;;
    *)  echo "ERROR: creating ${disp} returned HTTP $API_CODE" >&2
        cat "$API_BODY" >&2; echo >&2
        echo "" >&2
        echo "If the message mentions a custom location not being enabled, the" >&2
        echo "catalog's allowedLocations is not the bucket root. Re-run:" >&2
        echo "  ./05_create_catalog_prod.sh clean && ./05_create_catalog_prod.sh" >&2
        exit 1 ;;
  esac
}

echo ""
echo "== creating namespaces (parents first) =="
while IFS= read -r ns; do
  [ -n "$ns" ] || continue
  IFS=':' read -ra PARTS <<< "$ns"
  # The S3 location is the namespace path with '/' instead of the separator,
  # so the object layout and the catalog tree cannot drift apart.
  LOCATION="s3://${WAREHOUSE_BUCKET}/$(IFS=/; echo "${PARTS[*]}")"
  create_namespace "$LOCATION" "${PARTS[@]}"
done < <(all_namespaces)

cat <<EOF

Namespace tree under catalog '${CATALOG_NAME}':

EOF
for leaf in "${LEAVES[@]}"; do
  IFS=':' read -r med cat dom <<< "$leaf"
  printf '  %-14s %-16s %-26s s3://%s/%s/%s/%s\n' \
    "$med" "$cat" "$dom" "$WAREHOUSE_BUCKET" "$med" "$cat" "$dom"
done

cat <<EOF

Referencing a three-level namespace from Trino
----------------------------------------------
Trino models schemas as a single level, so a nested namespace is addressed as
one quoted identifier whose parts are joined by the 0x1F separator. In practice
that means using the schema name exactly as Trino reports it:

  kubectl exec -n ${NAMESPACE} deployment/trino-coordinator -- \\
    trino --execute "SHOW SCHEMAS FROM ${CATALOG_NAME}"

This depends on iceberg.rest-catalog.nested-namespace-enabled=true, which is
set in 02_trino_prod/chart/trino/values.yaml. Without it Trino lists only
top-level namespaces -- bronze, silver, gold -- and everything below them is
invisible with no error to explain why.

Two levels are known to work here. Three is the same mechanism with one more
part, but it has not been exercised on this cluster before now, so confirm the
count before building on it: the command above should list 15 schemas
(3 medallion + 6 category + 6 domain) plus information_schema and system.

  ./07_create_dg_namespaces_prod.sh verify   # every namespace and its location
  ./07_create_dg_namespaces_prod.sh clean    # drop them, deepest first
EOF
