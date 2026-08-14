#!/usr/bin/env bash
#
# 01_create_s3_buckets_prod.sh  (PROD environment)
#
# Creates the two S3 buckets used by the PROD environment, locks them down,
# and applies the classification-prefix lifecycle rules in
# prod-warehouse-lifecycle.json / prod-logs-lifecycle.json (same directory —
# single source of truth, this script never embeds a copy of the JSON).
#
# Safe to re-run: every step checks current state before changing anything.
# Creating these buckets does not require the EKS cluster or anything else
# in PROD to exist yet — they can be provisioned ahead of time at no cost
# (an empty bucket is free).
#
# Usage:
#   ./01_create_s3_buckets_prod.sh          # create + configure
#   ./01_create_s3_buckets_prod.sh verify   # report current state only, change nothing
#
# Requires: AWS CLI v2 configured with credentials that can create buckets.
#           prod-warehouse-lifecycle.json and prod-logs-lifecycle.json
#           present next to this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_WH_LIFECYCLE="${SCRIPT_DIR}/prod-warehouse-lifecycle.json"
PROD_LOGS_LIFECYCLE="${SCRIPT_DIR}/prod-logs-lifecycle.json"

for f in "$PROD_WH_LIFECYCLE" "$PROD_LOGS_LIFECYCLE"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: missing lifecycle file: ${f}" >&2
    echo "Put the JSON file next to this script and re-run." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 1. Environment
# ---------------------------------------------------------------------------

export AWS_REGION=ap-southeast-1

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export ACCOUNT_ID

# Fixed bucket names — no account-ID suffix. S3 bucket names are globally
# unique across ALL AWS accounts, so if someone else already owns one of
# these exact names, create-bucket below will fail with BucketAlreadyExists.
# If that happens, rename here (e.g. add a project/team suffix) and re-run.
export PROD_WH="data-store-prod-warehouse"
export PROD_LOGS="data-store-prod-logs"

ALL_BUCKETS=("$PROD_WH" "$PROD_LOGS")

# Persist these variables in the shared env file without disturbing whatever
# the TEST script has already written there (or will write later).
ENV_FILE="${HOME}/.data-platform.env"
touch "$ENV_FILE"
grep -v -E '^export (AWS_REGION|ACCOUNT_ID|PROD_WH|PROD_LOGS)=' "$ENV_FILE" > "${ENV_FILE}.tmp" 2>/dev/null || true
mv "${ENV_FILE}.tmp" "$ENV_FILE"
cat >> "$ENV_FILE" <<EOF
export AWS_REGION=${AWS_REGION}
export ACCOUNT_ID=${ACCOUNT_ID}
export PROD_WH=${PROD_WH}
export PROD_LOGS=${PROD_LOGS}
EOF

echo "Account:  ${ACCOUNT_ID}"
echo "Region:   ${AWS_REGION}"
echo "Buckets:  ${ALL_BUCKETS[*]}"
echo "Env file: ${ENV_FILE}"
echo "Lifecycle files:"
echo "  ${PROD_WH_LIFECYCLE}"
echo "  ${PROD_LOGS_LIFECYCLE}"
echo

# ---------------------------------------------------------------------------
# 2. Verify-only mode
# ---------------------------------------------------------------------------

report() {
  for B in "${ALL_BUCKETS[@]}"; do
    printf '%s\n' "=== ${B}"
    if aws s3api head-bucket --bucket "$B" >/dev/null 2>&1; then
      printf '  exists:     yes\n'
      printf '  public-access-block: %s\n' \
        "$(aws s3api get-public-access-block --bucket "$B" \
            --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
            --output text 2>/dev/null || echo 'NOT SET')"
      printf '  lifecycle rules:     %s\n' \
        "$(aws s3api get-bucket-lifecycle-configuration --bucket "$B" \
            --query 'Rules[].ID' --output text 2>/dev/null || echo 'NONE')"
    else
      printf '  exists:     no\n'
    fi
  done
}

if [[ "${1:-}" == "verify" ]]; then
  report
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Create buckets
# ---------------------------------------------------------------------------

for B in "${ALL_BUCKETS[@]}"; do
  if aws s3api head-bucket --bucket "$B" >/dev/null 2>&1; then
    echo "bucket ${B}: already exists (owned by us), skipping create"
  else
    if ! aws s3api create-bucket \
      --bucket "$B" \
      --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" \
      >/dev/null 2>/tmp/create-bucket-error.$$; then
      if grep -q "BucketAlreadyExists" /tmp/create-bucket-error.$$ 2>/dev/null; then
        echo "ERROR: bucket name '${B}' is already taken by a DIFFERENT AWS account." >&2
        echo "S3 bucket names are global — pick a different name (e.g. add a suffix)" >&2
        echo "for PROD_WH/PROD_LOGS above and re-run." >&2
      else
        cat /tmp/create-bucket-error.$$ >&2
      fi
      rm -f /tmp/create-bucket-error.$$
      exit 1
    fi
    rm -f /tmp/create-bucket-error.$$
    echo "bucket ${B}: created"
  fi

  aws s3api put-public-access-block --bucket "$B" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  echo "bucket ${B}: public access blocked"
done

echo

# ---------------------------------------------------------------------------
# 4. Apply lifecycle configuration
# ---------------------------------------------------------------------------
# Versioning is deliberately left disabled — Iceberg never overwrites a data
# file, it writes new files and atomically moves the table pointer, so S3
# versioning would just duplicate that protection while adding storage cost.
#
# Warehouse and logs buckets get different rule sets (classification-prefix
# tiering for warehouse, flat expiry for logs) — see docs/S3_DATA_TIER.md.

aws s3api put-bucket-lifecycle-configuration \
  --bucket "$PROD_WH" --lifecycle-configuration "file://${PROD_WH_LIFECYCLE}"
echo "bucket ${PROD_WH}: lifecycle applied from $(basename "$PROD_WH_LIFECYCLE")"

aws s3api put-bucket-lifecycle-configuration \
  --bucket "$PROD_LOGS" --lifecycle-configuration "file://${PROD_LOGS_LIFECYCLE}"
echo "bucket ${PROD_LOGS}: lifecycle applied from $(basename "$PROD_LOGS_LIFECYCLE")"

echo
echo "--- Final state ---"
report

echo
echo "Done. In a new shell, restore the variables with:"
echo "  source ${ENV_FILE}"
