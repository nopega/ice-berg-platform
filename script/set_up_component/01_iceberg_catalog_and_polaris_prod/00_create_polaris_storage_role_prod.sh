#!/usr/bin/env bash
#
# 00_create_polaris_storage_role_prod.sh
#
# Apache Polaris does NOT hold S3 permissions directly on its own pod
# identity. Instead it uses "credential vending": Polaris's own execution
# identity (the existing IRSA role, data-platform-prod-irsa-role) calls
# sts:AssumeRole on a separate "storage role" to get short-lived S3
# credentials, then hands scoped-down versions of those to whichever engine
# (Trino/Spark) asked for them. This is the two-hop trust chain this script
# sets up:
#
#   pod (SA: data-platform-workload)
#     -> data-platform-prod-irsa-role       (existing, via OIDC federation)
#     -> sts:AssumeRole (new inline policy added by this script)
#     -> data-platform-prod-polaris-storage-role   (created by this script)
#     -> s3:GetObject/PutObject/... on data-store-prod-warehouse/warehouse/*
#
# An ExternalId is used on the AssumeRole call as a defense against the
# "confused deputy" problem (standard AWS cross-role practice) — without it,
# nothing here changes technically, but it's what Polaris's own docs/CLI
# examples expect as a parameter when the catalog is registered later.
#
# Usage:
#   ./00_create_polaris_storage_role_prod.sh          # create / update
#   ./00_create_polaris_storage_role_prod.sh verify   # check status only
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IRSA_ROLE_NAME="data-platform-prod-irsa-role"
STORAGE_ROLE_NAME="data-platform-prod-polaris-storage-role"
STORAGE_POLICY_NAME="data-platform-prod-polaris-storage-access"
ASSUME_POLICY_NAME="data-platform-prod-polaris-assume-storage-role"
ENV_FILE="$HOME/.data-platform.env"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws

echo "== Polaris storage role setup ($MODE) ==========================="

echo "[1/2] Checking IRSA role '$IRSA_ROLE_NAME' exists..."
IRSA_ROLE_ARN="$(aws iam get-role --role-name "$IRSA_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null || true)"
[ -n "$IRSA_ROLE_ARN" ] && [ "$IRSA_ROLE_ARN" != "None" ] \
  || { echo "ERROR: '$IRSA_ROLE_NAME' not found. Run set_up_cluster/03_irsa_role_prod first." >&2; exit 1; }
echo "      IRSA role ARN: $IRSA_ROLE_ARN"

if [ "$MODE" = "verify" ]; then
  echo ""
  echo "[verify] Storage role:"
  aws iam get-role --role-name "$STORAGE_ROLE_NAME" --query 'Role.{Arn:Arn,Created:CreateDate}' --output table 2>/dev/null \
    || echo "  (not created yet)"
  echo "[verify] Assume-role policy on IRSA role:"
  aws iam list-role-policies --role-name "$IRSA_ROLE_NAME" --query 'PolicyNames' --output text 2>/dev/null || true
  exit 0
fi

# --- External ID: generate once, reuse on re-run (needed again when the
#     catalog is registered against Polaris later) ---------------------
EXTERNAL_ID="$(grep -E '^POLARIS_STORAGE_EXTERNAL_ID=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)"
if [ -z "$EXTERNAL_ID" ]; then
  EXTERNAL_ID="$(openssl rand -hex 16)"
  echo "      Generated new ExternalId: $EXTERNAL_ID"
else
  echo "      Reusing existing ExternalId from $ENV_FILE"
fi

# --- Trust policy: only the IRSA role (with the ExternalId) may assume this ---
TRUST_POLICY_FILE="$(mktemp)"
trap 'rm -f "$TRUST_POLICY_FILE"' EXIT
cat > "$TRUST_POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": "${IRSA_ROLE_ARN}" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "sts:ExternalId": "${EXTERNAL_ID}" }
      }
    }
  ]
}
EOF

echo "[2/2] Creating/updating storage role '$STORAGE_ROLE_NAME'..."
if aws iam get-role --role-name "$STORAGE_ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$STORAGE_ROLE_NAME" --policy-document "file://$TRUST_POLICY_FILE"
  echo "      Role existed, trust policy refreshed."
else
  aws iam create-role \
    --role-name "$STORAGE_ROLE_NAME" \
    --assume-role-policy-document "file://$TRUST_POLICY_FILE" \
    --description "Storage role Polaris assumes to read/write the prod Iceberg warehouse in S3 - see comment header in this script for the trust chain" \
    >/dev/null
  echo "      Role created."
fi

STORAGE_POLICY_ARN="$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${STORAGE_POLICY_NAME}'].Arn" --output text)"
if [ -z "$STORAGE_POLICY_ARN" ]; then
  STORAGE_POLICY_ARN="$(aws iam create-policy \
    --policy-name "$STORAGE_POLICY_NAME" \
    --policy-document "file://$SCRIPT_DIR/s3-storage-access-policy.json" \
    --query 'Policy.Arn' --output text)"
  echo "      S3 storage policy created."
else
  # This branch used to print "already exists, reusing" and stop, which meant
  # s3-storage-access-policy.json was applied ONCE, on the very first run, and
  # every edit to it afterwards did nothing at all. The file and the live
  # policy drifted silently, and the difference only surfaced as a 403 during a
  # Spark write:
  #
  #   User: .../data-platform-prod-polaris-storage-role/PolarisAws...
  #   is not authorized to perform: s3:PutObject on resource "...metadata.json"
  #   because no identity-based policy allows the s3:PutObject action
  #
  # -- while the JSON in this directory plainly granted PutObject. A file that
  # is read once and never again is documentation, not configuration.
  #
  # IAM keeps at most five versions of a policy, so the oldest non-default one
  # is removed when the limit is reached. Versions are not deleted eagerly:
  # keeping the recent ones is what makes `aws iam set-default-policy-version`
  # a one-command rollback.
  OLD_VERSIONS="$(aws iam list-policy-versions --policy-arn "$STORAGE_POLICY_ARN" \
    --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)"
  COUNT="$(printf '%s' "$OLD_VERSIONS" | wc -w | tr -d ' ')"
  if [ "$COUNT" -ge 4 ]; then
    OLDEST="$(printf '%s' "$OLD_VERSIONS" | tr '\t' '\n' | tail -1)"
    aws iam delete-policy-version --policy-arn "$STORAGE_POLICY_ARN" --version-id "$OLDEST" >/dev/null
  fi
  aws iam create-policy-version --policy-arn "$STORAGE_POLICY_ARN" \
    --policy-document "file://$SCRIPT_DIR/s3-storage-access-policy.json" \
    --set-as-default >/dev/null
  echo "      S3 storage policy updated from s3-storage-access-policy.json."
fi
aws iam attach-role-policy --role-name "$STORAGE_ROLE_NAME" --policy-arn "$STORAGE_POLICY_ARN"

STORAGE_ROLE_ARN="$(aws iam get-role --role-name "$STORAGE_ROLE_NAME" --query 'Role.Arn' --output text)"

echo "      Granting IRSA role permission to assume the storage role..."
ASSUME_POLICY_DOC="$(mktemp)"
cat > "$ASSUME_POLICY_DOC" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "${STORAGE_ROLE_ARN}"
    }
  ]
}
EOF
aws iam put-role-policy \
  --role-name "$IRSA_ROLE_NAME" \
  --policy-name "$ASSUME_POLICY_NAME" \
  --policy-document "file://$ASSUME_POLICY_DOC"
rm -f "$ASSUME_POLICY_DOC"

# --- Persist for later scripts (bootstrap Job, catalog-creation step) ----
grep -v -E '^(POLARIS_STORAGE_ROLE_ARN|POLARIS_STORAGE_EXTERNAL_ID)=' "$ENV_FILE" 2>/dev/null > "${ENV_FILE}.tmp" || true
{
  cat "${ENV_FILE}.tmp" 2>/dev/null
  echo "POLARIS_STORAGE_ROLE_ARN=${STORAGE_ROLE_ARN}"
  echo "POLARIS_STORAGE_EXTERNAL_ID=${EXTERNAL_ID}"
} > "$ENV_FILE"
rm -f "${ENV_FILE}.tmp"

echo ""
echo "Done."
echo "  Storage role ARN : $STORAGE_ROLE_ARN"
echo "  External ID      : $EXTERNAL_ID"
echo "  (both saved to $ENV_FILE for the next steps)"
echo ""
echo "Verify any time without changing anything:"
echo "  ./00_create_polaris_storage_role_prod.sh verify"
