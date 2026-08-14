#!/usr/bin/env bash
#
# 00_create_harbor_bucket_and_iam_prod.sh
#
# Creates the S3 bucket Harbor stores image layers in, plus the IAM user its
# registry authenticates to S3 with.
#
# WHY AN IAM USER AND NOT IRSA -- READ THIS BEFORE "FIXING" IT
# -------------------------------------------------------------
# This was IRSA first. It does not work, and the reason is in Harbor's own
# code rather than in any configuration here.
#
# Harbor 2.15.1 bundles distribution 2.8.x, whose S3 driver does not use the
# AWS SDK's default credential chain. It builds an explicit one
# (registry/storage/driver/s3-aws/s3.go):
#
#     creds := credentials.NewChainCredentials([]credentials.Provider{
#         &credentials.StaticProvider{...},          // accesskey/secretkey
#         &credentials.EnvProvider{},                // AWS_ACCESS_KEY_ID/...
#         &credentials.SharedCredentialsProvider{},  // ~/.aws/credentials
#         &ec2rolecreds.EC2RoleProvider{...},        // IMDS, i.e. the node role
#     })
#
# There is no WebIdentityProvider in that list. An IRSA-annotated
# ServiceAccount projects a token into the pod and the driver never looks at
# it, so a push fails with:
#
#     s3aws: NoCredentialProviders: no valid providers in chain. Deprecated.
#
# ("Deprecated." is the aws-sdk-go v1 wording, which is itself the proof that
# this is distribution 2.8 and not 3.0 -- 3.0 moved to SDK v2 and does support
# web identity. Harbor has not shipped it yet.)
#
# The three ways out, and why this one:
#
#   1. IAM user with an access key   <- chosen
#      One long-lived credential, scoped to one bucket, stored in Secrets
#      Manager, never written to git or to values.yaml.
#   2. Raise the node group's IMDS hop limit to 2 so EC2RoleProvider reaches
#      the node role. Rejected: every pod on those nodes that can reach IMDS
#      then inherits the node role. That is strictly worse than one scoped
#      key -- it is an unscoped credential handed to workloads that never
#      asked for it.
#   3. Go back to a PVC. Rejected for the reasons in the next section.
#
# Revisit when Harbor ships distribution 3.x; at that point this whole file
# goes back to being an IRSA role and the access key gets deleted.
#
# WHY IMAGE LAYERS GO TO S3 AND NOT A PVC
# ----------------------------------------
# The Harbor chart's default is a PersistentVolumeClaim for the registry. That
# works, and it is the wrong choice here for three reasons:
#
#   1. An EBS volume is ReadWriteOnce -- one node at a time. Scaling the
#      registry to two replicas is then impossible, so a rolling update means
#      a window where no node can pull an image. Spark executors starting in
#      that window fail with ImagePullBackOff.
#   2. It has a fixed size chosen in advance. Image layers accumulate quietly;
#      the volume fills, pushes start failing with a disk-full error from
#      inside the registry container, and nothing in the Harbor UI says so.
#   3. Losing the node loses the volume unless it is detached cleanly.
#
# S3 has none of those properties. It also costs roughly a tenth of EBS per GB
# for data that is written once and read occasionally, which is exactly the
# access pattern of a container layer.
#
# WHY A SEPARATE BUCKET RATHER THAN A PREFIX ON AN EXISTING ONE
# --------------------------------------------------------------
# data-store-prod-warehouse has lifecycle rules that transition objects to
# Glacier after 90 days. A Glacier-tiered image layer is not slow to pull --
# it is unpullable, and the failure surfaces as a timeout during pod startup
# rather than anything mentioning storage class. Registry blobs must never be
# tiered, so they need a bucket whose lifecycle policy is written for them.
#
# Usage:
#   ./00_create_harbor_bucket_and_iam_prod.sh          # create (idempotent)
#   ./00_create_harbor_bucket_and_iam_prod.sh verify   # report state
#   ./00_create_harbor_bucket_and_iam_prod.sh delete   # remove user + policy
#                                                      # (bucket is NOT deleted)
#
set -euo pipefail

REGION="ap-southeast-1"
K8S_NAMESPACE="harbor"
USER_NAME="data-platform-prod-harbor-registry"
POLICY_NAME="data-platform-prod-harbor-s3-registry"
REGISTRY_BUCKET="data-store-prod-registry"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

if [ "$MODE" = "verify" ]; then
  echo "=== bucket ==="
  if aws s3api head-bucket --bucket "$REGISTRY_BUCKET" 2>/dev/null; then
    echo "  ${REGISTRY_BUCKET}: exists"
    echo "  public access block:"
    aws s3api get-public-access-block --bucket "$REGISTRY_BUCKET" \
      --query 'PublicAccessBlockConfiguration' --output text 2>/dev/null || echo "    NOT SET"
    echo "  lifecycle rules:"
    aws s3api get-bucket-lifecycle-configuration --bucket "$REGISTRY_BUCKET" \
      --query 'Rules[].ID' --output text 2>/dev/null || echo "    none"
    echo "  objects (first 5):"
    aws s3 ls "s3://${REGISTRY_BUCKET}/" --recursive 2>/dev/null | head -5 || echo "    empty"
  else
    echo "  ${REGISTRY_BUCKET}: not created"
  fi
  echo ""
  echo "=== iam user ==="
  aws iam get-user --user-name "$USER_NAME" \
    --query 'User.[UserName,Arn]' --output table 2>/dev/null || echo "  not created"
  echo ""
  echo "=== attached policies ==="
  aws iam list-attached-user-policies --user-name "$USER_NAME" \
    --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null || echo "  none"
  echo ""
  echo "=== access keys (age matters -- these are long-lived) ==="
  # Only the ID and the age are printable; the secret is returned once, at
  # creation, and never again. If it was not captured then, the only remedy is
  # to delete the key and make a new one.
  aws iam list-access-keys --user-name "$USER_NAME" \
    --query 'AccessKeyMetadata[].[AccessKeyId,Status,CreateDate]' --output table 2>/dev/null \
    || echo "  none"
  echo ""
  echo "=== more than one key means a rotation was left half-finished ==="
  KEY_COUNT="$(aws iam list-access-keys --user-name "$USER_NAME" \
    --query 'length(AccessKeyMetadata)' --output text 2>/dev/null || echo 0)"
  echo "  ${KEY_COUNT} key(s). Expected 1."
  exit 0
fi

if [ "$MODE" = "delete" ]; then
  # Access keys must go before the user -- IAM refuses to delete a user that
  # still owns one, with an error naming the user rather than the key.
  for k in $(aws iam list-access-keys --user-name "$USER_NAME" \
               --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || true); do
    aws iam delete-access-key --user-name "$USER_NAME" --access-key-id "$k" 2>/dev/null || true
  done
  aws iam detach-user-policy --user-name "$USER_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true
  aws iam delete-user --user-name "$USER_NAME" 2>/dev/null || true
  aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true
  cat <<EOF
Removed ${USER_NAME} and ${POLICY_NAME} (if they existed).

The bucket ${REGISTRY_BUCKET} was deliberately left alone -- it holds every
image the platform runs, and a script that deletes it as a side effect of
tearing down an IAM user is a script waiting to cause an outage. Remove it by
hand if that is really the intent:

  aws s3 rb s3://${REGISTRY_BUCKET} --force
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
echo "[1/5] Creating the registry bucket..."
if aws s3api head-bucket --bucket "$REGISTRY_BUCKET" 2>/dev/null; then
  echo "      ${REGISTRY_BUCKET} already exists"
else
  # ap-southeast-1 is not us-east-1, so LocationConstraint is required. Omitting
  # it silently creates the bucket in us-east-1 instead, which then costs
  # cross-region transfer on every single image pull.
  aws s3api create-bucket --bucket "$REGISTRY_BUCKET" --region "$REGION" \
    --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
  echo "      ${REGISTRY_BUCKET} created in ${REGION}"
fi

aws s3api put-public-access-block --bucket "$REGISTRY_BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >/dev/null
echo "      public access blocked"

aws s3api put-bucket-encryption --bucket "$REGISTRY_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
echo "      default encryption enabled"

# ---------------------------------------------------------------------------
echo "[2/5] Applying the lifecycle policy..."
# Deliberately NO transitions and NO expiration on the blob prefix. Harbor
# manages its own retention: tag retention rules mark manifests for deletion,
# and garbage collection then removes the unreferenced blobs. An S3 rule that
# also deleted objects would race with that, and losing a blob a manifest still
# points at corrupts the image with no warning until someone tries to pull it.
#
# The only rule here cleans up failed multipart uploads. Pushing a large layer
# uses multipart; an interrupted push leaves parts that are invisible to
# `aws s3 ls` but are billed as storage indefinitely.
aws s3api put-bucket-lifecycle-configuration --bucket "$REGISTRY_BUCKET" \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "abort-incomplete-multipart-uploads",
        "Status": "Enabled",
        "Filter": {},
        "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
      }
    ]
  }' >/dev/null
echo "      abort-incomplete-multipart-uploads only (Harbor owns blob retention)"

# ---------------------------------------------------------------------------
echo "[3/4] Writing the policy..."
POLICY_FILE="$(mktemp)"
trap 'rm -f "$POLICY_FILE"' EXIT

# The whole bucket, not a prefix. The registry chooses its own object layout
# (docker/registry/v2/blobs/... and .../repositories/...) and garbage collection
# walks all of it; constraining it to a prefix would break GC in a way that only
# shows up as storage that never shrinks.
#
# ListBucket is unconditioned for the same reason. It is acceptable here
# because the bucket contains nothing but registry blobs -- that is exactly why
# it is a separate bucket.
#
# AbortMultipartUpload and ListBucketMultipartUploads matter more than they
# look: layers are large, every push is multipart, and without them an
# interrupted push leaves parts the registry cannot clean up.
cat > "$POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "HarborRegistryObjects",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::${REGISTRY_BUCKET}/*"
    },
    {
      "Sid": "HarborRegistryBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::${REGISTRY_BUCKET}"
    }
  ]
}
EOF
echo "      scoped to s3://${REGISTRY_BUCKET} only"

# ---------------------------------------------------------------------------
echo "[4/4] Applying IAM..."
if aws iam get-user --user-name "$USER_NAME" >/dev/null 2>&1; then
  echo "      user exists"
else
  # No console password and no tags beyond this one: this identity exists to
  # hold one access key and nothing else. A human should never log in as it.
  aws iam create-user --user-name "$USER_NAME" \
    --tags "Key=purpose,Value=harbor-registry-s3" >/dev/null
  echo "      user created"
fi

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  OLD_VERSIONS="$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
    --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)"
  COUNT="$(printf '%s' "$OLD_VERSIONS" | wc -w | tr -d ' ')"
  if [ "$COUNT" -ge 4 ]; then
    OLDEST="$(printf '%s' "$OLD_VERSIONS" | awk '{print $NF}')"
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST" >/dev/null
  fi
  aws iam create-policy-version --policy-arn "$POLICY_ARN" \
    --policy-document "file://${POLICY_FILE}" --set-as-default >/dev/null
  echo "      policy exists, new version set as default"
else
  aws iam create-policy --policy-name "$POLICY_NAME" \
    --policy-document "file://${POLICY_FILE}" >/dev/null
  echo "      policy created"
fi

aws iam attach-user-policy --user-name "$USER_NAME" --policy-arn "$POLICY_ARN" >/dev/null
echo "      policy attached"

cat <<EOF

Bucket and user ready:

  s3://${REGISTRY_BUCKET}
  ${USER_NAME}

No access key exists yet -- deliberately. The secret half of a key is shown
exactly once, at creation, so it has to be created by the script that can put
it straight into Secrets Manager without it passing through a terminal:

  ./01_create_harbor_secrets_prod.sh
EOF
