#!/usr/bin/env bash
#
# 03_build_and_push_image_prod.sh
#
# Builds the Spark image and pushes it to Harbor.
#
# WHY --platform linux/amd64 IS NOT OPTIONAL
# --------------------------------------------
# The nodes are x86_64. Docker on Apple Silicon defaults to building arm64,
# and an arm64 image runs perfectly on the laptop, pushes without complaint,
# and then crashes on the cluster with
#
#     exec /opt/entrypoint.sh: exec format error
#
# which says nothing about architecture. The flag is passed unconditionally
# below rather than left to the builder's default.
#
# Usage:
#   ./03_build_and_push_image_prod.sh              # build + push, tag from git
#   ./03_build_and_push_image_prod.sh build        # build only, do not push
#   ./03_build_and_push_image_prod.sh v1.2.3       # build + push an explicit tag
#   ./03_build_and_push_image_prod.sh verify       # what is in Harbor already
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="harbor.nopega.net"
PROJECT="ice-berg-platform"
IMAGE_NAME="datapipeline"
PLATFORM="linux/amd64"
MODE="${1:-}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need docker

IMAGE="${REGISTRY}/${PROJECT}/${IMAGE_NAME}"

# ---------------------------------------------------------------------------
# The tag. Derived from git rather than hand-typed, so an image can always be
# traced back to the exact source that produced it.
#
# `-dirty` is appended when the working tree has uncommitted changes. That is
# not cosmetic: an image tagged with a clean commit hash implies the source is
# recoverable from that commit, and a dirty build breaks that promise silently.
# ---------------------------------------------------------------------------
derive_tag() {
  local sha dirty=""
  sha="$(git -C "$SCRIPT_DIR" rev-parse --short=12 HEAD 2>/dev/null || echo nogit)"
  if ! git -C "$SCRIPT_DIR" diff --quiet HEAD -- "$SCRIPT_DIR" 2>/dev/null; then
    dirty="-dirty"
  fi
  printf '%s%s' "$sha" "$dirty"
}

if [ "$MODE" = "verify" ]; then
  echo "=== tags currently in Harbor ==="
  # Reads the registry API rather than the local docker images list, because
  # what matters is what the cluster can pull, not what this laptop built.
  curl -sf -u "admin:$( \
      ../05_harbor_prod/01_create_harbor_secrets_prod.sh show-admin 2>/dev/null \
      | awk '/^password:/{print $2}')" \
    "https://${REGISTRY}/api/v2.0/projects/${PROJECT}/repositories/${IMAGE_NAME}/artifacts?page_size=10" \
    2>/dev/null \
    | python3 -c "
import json,sys
try:
    arts=json.load(sys.stdin)
except Exception:
    print('  could not read the registry API'); sys.exit(0)
if not arts:
    print('  no artifacts pushed yet'); sys.exit(0)
for a in arts:
    tags=','.join(t['name'] for t in (a.get('tags') or [])) or '<untagged>'
    scan=a.get('scan_overview') or {}
    summary='not scanned'
    for v in scan.values():
        s=v.get('summary',{}).get('summary',{})
        summary=' '.join(f'{k}={n}' for k,n in s.items()) or v.get('scan_status','?')
    print(f\"  {tags:30} pushed={a.get('push_time','?')[:19]}  trivy: {summary}\")
" 2>/dev/null || echo "  registry unreachable, or not logged in"
  echo ""
  echo "=== local images ==="
  docker images "$IMAGE" --format '  {{.Tag}}  {{.Size}}  {{.CreatedSince}}' 2>/dev/null || true
  exit 0
fi

if [ "$MODE" = "build" ]; then
  PUSH=false
  TAG="$(derive_tag)"
elif [ -n "$MODE" ]; then
  PUSH=true
  TAG="$MODE"
else
  PUSH=true
  TAG="$(derive_tag)"
fi

# ---------------------------------------------------------------------------
echo "[1/4] Preflight..."

[ -f "$SCRIPT_DIR/Dockerfile" ] || { echo "ERROR: Dockerfile not found." >&2; exit 1; }
[ -d "$SCRIPT_DIR/jobs" ] || {
  echo "ERROR: ./jobs/ does not exist, and the Dockerfile COPYs it." >&2
  echo "       An empty directory is not enough -- git does not track those." >&2
  exit 1
}

case "$TAG" in
  *-dirty)
    echo "      WARNING: tag is ${TAG} -- the working tree has uncommitted changes."
    echo "               This image cannot be rebuilt from any commit."
    ;;
  nogit*)
    echo "      WARNING: not a git repository, so the tag carries no provenance."
    ;;
  *)
    echo "      tag: ${TAG}"
    ;;
esac

docker info >/dev/null 2>&1 || {
  echo "ERROR: cannot talk to the Docker daemon. Is Docker Desktop running?" >&2
  exit 1
}

HOST_ARCH="$(uname -m)"
if [ "$HOST_ARCH" != "x86_64" ]; then
  echo "      building ${PLATFORM} on ${HOST_ARCH} -- emulated, so this is slow"
fi

# ---------------------------------------------------------------------------
echo "[2/4] Building..."
# --provenance=false: buildx otherwise pushes an OCI image index with an
# attestation manifest, which Harbor lists as a separate untagged artifact and
# which some older container runtimes refuse to pull.
docker build \
  --platform "$PLATFORM" \
  --provenance=false \
  -t "${IMAGE}:${TAG}" \
  -t "${IMAGE}:latest" \
  -f "$SCRIPT_DIR/Dockerfile" \
  "$SCRIPT_DIR"

echo "[3/4] Checking what was actually built..."
# The Dockerfile already asserts the jars exist at build time. This confirms
# the ARCHITECTURE, which the Dockerfile cannot check from inside itself.
BUILT_ARCH="$(docker image inspect "${IMAGE}:${TAG}" --format '{{.Os}}/{{.Architecture}}')"
echo "      ${BUILT_ARCH}"
[ "$BUILT_ARCH" = "$PLATFORM" ] || {
  echo "ERROR: built ${BUILT_ARCH}, needed ${PLATFORM}. Pods would crash with" >&2
  echo "       'exec format error'." >&2
  exit 1
}
docker image inspect "${IMAGE}:${TAG}" --format '      size: {{.Size}} bytes'

if [ "$PUSH" != true ]; then
  cat <<EOF

Built ${IMAGE}:${TAG} locally. Not pushed.

  ./03_build_and_push_image_prod.sh          # to build and push
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
echo "[4/4] Pushing to Harbor..."
docker push "${IMAGE}:${TAG}"
docker push "${IMAGE}:latest"

cat <<EOF

Pushed:

  ${IMAGE}:${TAG}
  ${IMAGE}:latest

USE THE DIGEST OR THE COMMIT TAG IN SparkApplication, NOT :latest.

  \`latest\` is a moving pointer. A job that references it can silently change
  behaviour between two runs of the same DAG, and the Airflow log gives no
  indication that the code was different. It is pushed only so that a human
  poking at the registry sees something recognisable.

Trivy scans on push. Check the result before running anything real:

  ./03_build_and_push_image_prod.sh verify

If the project has "Prevent vulnerable images from running" enabled at High,
a failing scan makes the image unpullable -- pods report ImagePullBackOff
with a message about the policy, not about CVEs.
EOF
