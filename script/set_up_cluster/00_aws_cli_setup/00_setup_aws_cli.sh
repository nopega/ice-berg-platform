#!/usr/bin/env bash
#
# 00_setup_aws_cli.sh
#
# Installs AWS CLI v2 (macOS) if missing, configures the "default" profile,
# and verifies the credentials actually work.
#
# Safe to re-run: the install step is skipped if the CLI is already present,
# and you can re-enter credentials at any time to rotate a key.
#
# Usage:
#   ./00_setup_aws_cli.sh
#
# Note on secrets: the secret key is read with `read -s` so it is never
# echoed to the terminal or written to shell history. It is then handed to
# `aws configure set`, the same official mechanism `aws configure` itself
# uses to write ~/.aws/credentials — this only touches the keys being set
# and leaves any other profiles in that file untouched.

set -euo pipefail

DEFAULT_REGION="ap-southeast-1"
PROFILE="default"

# ---------------------------------------------------------------------------
# 1. Install AWS CLI v2 if not already present
# ---------------------------------------------------------------------------

if command -v aws >/dev/null 2>&1; then
  echo "AWS CLI already installed: $(aws --version)"
else
  echo "AWS CLI not found — installing (macOS universal pkg)..."
  TMP_PKG="$(mktemp -t AWSCLIV2).pkg"
  curl -fsSL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "$TMP_PKG"
  sudo installer -pkg "$TMP_PKG" -target /
  rm -f "$TMP_PKG"
  echo "Installed: $(aws --version)"
fi
echo

# ---------------------------------------------------------------------------
# 2. Collect credentials
# ---------------------------------------------------------------------------
# Use the Access Key of an IAM user (e.g. pongkun-admin), never the AWS
# account root user's key.

read -r -p "AWS Access Key ID: " ACCESS_KEY_ID
read -r -s -p "AWS Secret Access Key: " SECRET_ACCESS_KEY
echo
read -r -p "Default region [${DEFAULT_REGION}]: " REGION_INPUT
REGION="${REGION_INPUT:-$DEFAULT_REGION}"

if [[ -z "$ACCESS_KEY_ID" || -z "$SECRET_ACCESS_KEY" ]]; then
  echo "ERROR: Access Key ID and Secret Access Key are both required." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Write the profile
# ---------------------------------------------------------------------------

aws configure set aws_access_key_id "$ACCESS_KEY_ID" --profile "$PROFILE"
aws configure set aws_secret_access_key "$SECRET_ACCESS_KEY" --profile "$PROFILE"
aws configure set region "$REGION" --profile "$PROFILE"
aws configure set output "json" --profile "$PROFILE"

# Clear the secret out of this shell's memory as soon as it's written.
unset SECRET_ACCESS_KEY

echo "Profile '${PROFILE}' written to ~/.aws/credentials and ~/.aws/config"
echo

# ---------------------------------------------------------------------------
# 4. Verify
# ---------------------------------------------------------------------------

echo "Verifying with aws sts get-caller-identity ..."
IDENTITY_JSON="$(aws sts get-caller-identity --profile "$PROFILE" --output json)"
echo "$IDENTITY_JSON"

ARN="$(echo "$IDENTITY_JSON" | grep -o '"Arn": *"[^"]*"' | cut -d'"' -f4)"
if [[ "$ARN" == *":root" ]]; then
  echo
  echo "WARNING: this Access Key belongs to the ROOT account, not an IAM user." >&2
  echo "Create/use an IAM user (e.g. pongkun-admin) instead and re-run this script." >&2
  exit 1
fi

echo
echo "OK — authenticated as: ${ARN}"
echo "Region: ${REGION}"
