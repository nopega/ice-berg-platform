#!/usr/bin/env bash
#
# 01_install_cloudflared_prod.sh
#
# Deploys cloudflared, the outbound connector that puts the Airflow UI and
# Harbor on nopega.net without opening a single inbound port.
#
# The tunnel token is read from AWS Secrets Manager at apply time and piped
# into a Kubernetes Secret. It is never an argument, never written to disk and
# never printed -- the token alone is enough to register a connector on this
# tunnel, so it is treated like the root credential it effectively is.
#
# Usage:
#   ./01_install_cloudflared_prod.sh            # create secret + deploy
#   ./01_install_cloudflared_prod.sh verify     # status and connector health
#   ./01_install_cloudflared_prod.sh logs       # tail cloudflared logs
#   ./01_install_cloudflared_prod.sh uninstall  # remove everything
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="ap-southeast-1"
NAMESPACE="cloudflared"
SM_TOKEN="data-platform-prod-cloudflare-tunnel-token"
MANIFEST="$SCRIPT_DIR/cloudflared-deployment.yaml"
DOMAIN="nopega.net"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need kubectl; need aws

case "$MODE" in
  logs)
    kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/name=cloudflared --tail=80 -f
    exit 0
    ;;

  uninstall)
    kubectl delete -f "$MANIFEST" --ignore-not-found
    kubectl delete secret cloudflare-tunnel-token -n "$NAMESPACE" --ignore-not-found
    cat <<EOF

Removed. The tunnel itself still exists in Cloudflare with no connectors
attached, so every hostname on it now returns an error to visitors rather
than simply vanishing. Delete the tunnel in the Cloudflare dashboard too if
this is meant to be permanent.

The token in Secrets Manager (${SM_TOKEN}) is left in place.
EOF
    exit 0
    ;;

  verify)
    echo "=== pods ==="
    kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || echo "  none"
    echo ""
    echo "=== are the replicas on different nodes? ==="
    # Both on one node means the anti-affinity preference could not be met,
    # usually because only one node has workload=critical free. Two replicas on
    # one node is not redundancy.
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=cloudflared \
      -o jsonpath='{range .items[*]}{.metadata.name}{"  ->  "}{.spec.nodeName}{"\n"}{end}' 2>/dev/null \
      || echo "  none"
    echo ""
    echo "=== connector registration (from the pod's own view) ==="
    POD="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=cloudflared \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -n "$POD" ]; then
      kubectl logs -n "$NAMESPACE" "$POD" --tail=200 2>/dev/null \
        | grep -iE 'registered tunnel connection|connection .* registered|unregistered|error' \
        | tail -10 || echo "  (no matching log lines yet)"
    else
      echo "  no pod"
    fi
    echo ""
    echo "=== reachability from outside ==="
    echo "  These only answer once the Public Hostname mapping exists in the"
    echo "  Cloudflare dashboard -- the tunnel being up is not sufficient:"
    echo "    curl -sI https://airflow.${DOMAIN} | head -1"
    echo "    curl -sI https://harbor.${DOMAIN}  | head -1"
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
echo "[1/3] Reading the tunnel token from Secrets Manager..."
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE" >/dev/null

aws secretsmanager describe-secret --secret-id "$SM_TOKEN" --region "$REGION" >/dev/null 2>&1 || {
  cat >&2 <<EOF
ERROR: secret '${SM_TOKEN}' not found in Secrets Manager.

  Create the tunnel at https://one.dash.cloudflare.com (Networks -> Tunnels),
  copy the install command it shows, and store just the token:

    pbpaste | awk '{print \$NF}' | tr -d '[:space:]' > /tmp/cf-token.txt
    aws secretsmanager create-secret \\
      --name ${SM_TOKEN} --region ${REGION} \\
      --secret-string "file:///tmp/cf-token.txt"
    rm /tmp/cf-token.txt
EOF
  exit 1
}

# Piped, not captured into a variable: a shell variable would appear in the
# process environment and could be echoed by any later command in this script.
aws secretsmanager get-secret-value --secret-id "$SM_TOKEN" --region "$REGION" \
  --query SecretString --output text \
  | tr -d '[:space:]' \
  | kubectl create secret generic cloudflare-tunnel-token \
      -n "$NAMESPACE" --from-file=token=/dev/stdin \
      --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null
echo "      Secret cloudflare-tunnel-token created"

# A truncated or wrongly-copied token produces a pod that starts, fails to
# authenticate and CrashLoopBackOffs with a message about an invalid token --
# recognisable, but only after a deploy. A real token is a JWT-ish string of
# several hundred characters starting `eyJ`; anything much shorter was copied
# wrong. Length only, so nothing sensitive is printed.
TOKEN_LEN="$(kubectl get secret cloudflare-tunnel-token -n "$NAMESPACE" \
  -o jsonpath='{.data.token}' | base64 --decode | wc -c | tr -d ' ')"
if [ "$TOKEN_LEN" -lt 80 ]; then
  echo "ERROR: the stored token is only ${TOKEN_LEN} characters." >&2
  echo "       That is far too short -- likely the command was copied without" >&2
  echo "       the token, or only part of it was pasted. Re-store it and retry." >&2
  exit 1
fi
echo "      token length looks sane (${TOKEN_LEN} chars)"

echo "[2/3] Applying manifests..."
kubectl apply -f "$MANIFEST"

echo "[3/3] Waiting for rollout..."
kubectl rollout status deployment/cloudflared -n "$NAMESPACE" --timeout=180s

kubectl get pods -n "$NAMESPACE" -o wide

cat <<EOF

cloudflared is connected. Nothing is reachable yet -- the tunnel is up, but
Cloudflare does not know which hostname maps to which in-cluster service.

Add these in the Cloudflare dashboard, on the tunnel's Public Hostname tab:

  airflow.${DOMAIN}   HTTP   airflow-api-server.airflow.svc.cluster.local:8080
  harbor.${DOMAIN}    HTTP   harbor.harbor.svc.cluster.local:80        (after Harbor)

HTTP, not HTTPS, is correct for the second column: the connection from
Cloudflare to this cluster is already encrypted inside the tunnel, and the
in-cluster Services do not serve TLS. Visitors still reach the site over
HTTPS -- Cloudflare terminates it at the edge.

Then, before telling anyone the URL:

  Cloudflare dashboard -> Access -> Applications -> Add an application
  -> Self-hosted -> airflow.${DOMAIN}

  Without this, the Airflow UI is on the public internet behind nothing but
  its own login form. Access puts an identity check in front of the tunnel,
  so unauthenticated requests never reach the cluster at all.

  ./01_install_cloudflared_prod.sh verify
EOF
