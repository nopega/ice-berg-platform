#!/usr/bin/env bash
#
# 02_apply_public_ingress_prod.sh
#
# Creates the public ALB by applying the two Ingress objects in
# ingress-public.yaml, after substituting the certificate ARN and the source
# IP ranges allowed to reach it.
#
# The ALB is not created by this script directly -- the AWS Load Balancer
# Controller (installed in 07_) watches for these Ingress objects and builds
# the load balancer, listener, target groups and security group from them.
# Deleting the Ingress deletes the ALB.
#
# Usage:
#   ./02_apply_public_ingress_prod.sh 203.0.113.5/32      # apply, allow one IP
#   ./02_apply_public_ingress_prod.sh                     # apply, reuse saved CIDRs
#   ./02_apply_public_ingress_prod.sh dns                 # print the DNS records to add
#   ./02_apply_public_ingress_prod.sh verify              # state of ALB, targets, DNS
#   ./02_apply_public_ingress_prod.sh delete              # remove Ingress (and the ALB)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="ap-southeast-1"
CLUSTER_NAME="data-platform-prod"   # used to find the VPC's NAT gateway, below
MANIFEST="$SCRIPT_DIR/ingress-public.yaml"
PRIMARY_DOMAIN="trino.nopega.net"
GROUP_NAME="data-platform-public"
CIDR_FILE="$SCRIPT_DIR/.inbound-cidrs"   # gitignored; environment-specific
MODE="${1:-}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need kubectl; need aws

alb_hostname() {
  # Either Ingress reports the same address -- they share one ALB.
  kubectl get ingress trino-public -n data-platform \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true
}

case "$MODE" in
  dns)
    HOST="$(alb_hostname)"
    [ -n "$HOST" ] || { echo "The ALB has no hostname yet. Wait a minute and retry." >&2; exit 1; }
    cat <<EOF
ALB hostname: ${HOST}

Add these in Cloudflare -> nopega.net -> DNS -> Add record.

  Type: CNAME   Name: airflow   Target: ${HOST}   Proxy: DNS only
  Type: CNAME   Name: trino     Target: ${HOST}   Proxy: DNS only
  Type: CNAME   Name: harbor    Target: ${HOST}   Proxy: DNS only

DNS only, not proxied, for two separate reasons:

  1. The ALB's certificate is issued for these exact hostnames. Proxying puts
     Cloudflare's certificate in front instead, and the connection Cloudflare
     makes to the ALB is a second TLS session that has to be configured
     correctly or it fails as a 5xx that looks like the origin is down.

  2. Cloudflare's free plan caps request bodies at 100 MB. That is invisible
     for Airflow, and fatal for pushing a container image layer -- which is
     why Harbor will use this ALB rather than a tunnel.

Do NOT delete the ACM validation CNAMEs already in the zone. ACM re-reads them
to renew the certificate automatically.
EOF
    exit 0
    ;;

  verify)
    echo "=== ingress objects ==="
    kubectl get ingress -A -o wide 2>/dev/null | grep -E 'NAME|public' || echo "  none"
    echo ""
    echo "=== ALB ==="
    HOST="$(alb_hostname)"
    if [ -n "$HOST" ]; then
      echo "  ${HOST}"
      LB_ARN="$(aws elbv2 describe-load-balancers --region "$REGION" \
        --query "LoadBalancers[?DNSName=='${HOST}'].LoadBalancerArn | [0]" --output text 2>/dev/null)"
      echo ""
      echo "=== target group health (this is what decides 503 vs 200) ==="
      # An ALB with healthy pods but unhealthy targets returns 503 and looks
      # like an application outage. Check here before debugging the app.
      for TG in $(aws elbv2 describe-target-groups --region "$REGION" \
            --load-balancer-arn "$LB_ARN" --query 'TargetGroups[].TargetGroupArn' \
            --output text 2>/dev/null); do
        echo "  $(basename "$TG")"
        aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$TG" \
          --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' \
          --output text 2>/dev/null | sed 's/^/    /'
      done
      echo ""
      echo "=== security group ingress rules (who can reach it) ==="
      for SG in $(aws elbv2 describe-load-balancers --region "$REGION" \
            --load-balancer-arns "$LB_ARN" --query 'LoadBalancers[0].SecurityGroups' \
            --output text 2>/dev/null); do
        aws ec2 describe-security-groups --region "$REGION" --group-ids "$SG" \
          --query 'SecurityGroups[0].IpPermissions[].{port:FromPort,cidrs:IpRanges[].CidrIp}' \
          --output json 2>/dev/null | sed 's/^/  /'
      done
    else
      echo "  not created yet"
      echo ""
      echo "  If this stays empty, the controller is refusing to reconcile."
      echo "  Its log says why -- most often a missing subnet tag:"
      echo "    kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=40"
    fi
    echo ""
    echo "=== does DNS point at it yet? ==="
    for h in airflow.nopega.net trino.nopega.net harbor.nopega.net grafana.nopega.net; do
      printf '  %-22s -> %s\n' "$h" "$(dig +short CNAME "$h" 2>/dev/null | head -1)"
    done
    exit 0
    ;;

  delete)
    kubectl delete -f <(sed -e "s|__CERT_ARN__|placeholder|" -e "s|__INBOUND_CIDRS__|0.0.0.0/32|" "$MANIFEST") --ignore-not-found
    cat <<EOF

Ingress removed, and with it the ALB -- the controller deletes the load
balancer when the last Ingress in the group goes away.

The ACM certificate and its validation CNAMEs are untouched, so recreating
this later does not mean redoing DNS validation.
EOF
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# 1. Certificate must be ISSUED. Applying with a PENDING_VALIDATION ARN
#    creates an ALB whose listener has a certificate that cannot serve traffic.
# ---------------------------------------------------------------------------
echo "[1/5] Certificate..."
REQUIRED_HOSTS="trino.nopega.net airflow.nopega.net harbor.nopega.net grafana.nopega.net"

# Every ISSUED certificate for this domain, not just the first one.
#
# `| [0]` was wrong here and only became visibly wrong when grafana was added.
# Adding a hostname means requesting a SECOND certificate -- ACM cannot extend
# an issued one -- so for the period between the new certificate being issued
# and the old one being deleted, there are two, and [0] picks whichever the API
# happens to return first. Half the time that is the old certificate, which is
# ISSUED, valid, and missing a name. The ALB would then serve grafana with a
# certificate that does not cover it: a browser TLS warning on one hostname,
# from a script that reported success.
CERT_ARN=""
CERT_FALLBACK=""
for arn in $(aws acm list-certificates --region "$REGION" \
  --certificate-statuses ISSUED \
  --query "CertificateSummaryList[?DomainName=='${PRIMARY_DOMAIN}'].CertificateArn" \
  --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' || true); do
  [ -n "$CERT_FALLBACK" ] || CERT_FALLBACK="$arn"
  names="$(aws acm describe-certificate --region "$REGION" --certificate-arn "$arn" \
    --query 'Certificate.SubjectAlternativeNames' --output text 2>/dev/null | tr '\t\n' '  ')"
  ok=1
  for h in $REQUIRED_HOSTS; do
    case " $names " in *" $h "*) ;; *) ok=0 ;; esac
  done
  [ "$ok" -eq 1 ] && { CERT_ARN="$arn"; break; }
done

# Nothing covers everything: fall through to the coverage check below with the
# best candidate, so the error names the missing host rather than saying no
# certificate exists.
[ -n "$CERT_ARN" ] || CERT_ARN="$CERT_FALLBACK"

if [ -z "$CERT_ARN" ]; then
  echo "ERROR: no ISSUED certificate for ${PRIMARY_DOMAIN}." >&2
  echo "       Current state:" >&2
  "$SCRIPT_DIR/01_request_acm_certificate_prod.sh" verify >&2 || true
  echo "" >&2
  echo "       Wait for status ISSUED before applying the Ingress." >&2
  exit 1
fi

# Confirm the certificate actually covers all three names. A certificate can be
# ISSUED for a subset, and the mismatch only appears as a browser TLS warning
# on the one hostname that was left out.
# `--output text` separates list items with TABS, not spaces. The membership
# test below matches on space-delimited words, so without this the check fails
# for every name after the first -- reporting that a certificate does not cover
# a domain it visibly does, which is worse than not checking at all.
COVERED="$(aws acm describe-certificate --region "$REGION" --certificate-arn "$CERT_ARN" \
  --query 'Certificate.SubjectAlternativeNames' --output text | tr '\t\n' '  ')"
echo "      ISSUED, covers: ${COVERED}"
# grafana was added after the first certificate was issued, and ACM cannot add
# a name to one. If this check fails, the fix is
# ./01_request_acm_certificate_prod.sh renew -- not editing this list.
for h in $REQUIRED_HOSTS; do
  case " $COVERED " in
    *" $h "*) ;;
    *) echo "ERROR: certificate does not cover ${h}." >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# 2. Source CIDRs.
# ---------------------------------------------------------------------------
echo "[2/5] Allowed source ranges..."
if [ -n "$MODE" ]; then
  INBOUND_CIDRS="$MODE"
  printf '%s' "$INBOUND_CIDRS" > "$CIDR_FILE"
elif [ -f "$CIDR_FILE" ]; then
  INBOUND_CIDRS="$(cat "$CIDR_FILE")"
else
  cat >&2 <<EOF
ERROR: no source CIDR given and none saved.

  This deliberately has no default. A default of 0.0.0.0/0 would put Airflow
  and Trino on the open internet the moment this script is run, protected by
  nothing but their login forms -- and it would do so silently.

  Find your current public address:

    curl -s https://checkip.amazonaws.com

  Then pass it as a /32:

    $0 203.0.113.5/32

  Several ranges are allowed, comma-separated:

    $0 203.0.113.5/32,198.51.100.0/24

  Note that a home connection's address usually changes. When it does, the
  symptom is a connection that times out rather than one that is refused --
  re-run this script with the new address.
EOF
  exit 1
fi

if [ "$INBOUND_CIDRS" = "0.0.0.0/0" ]; then
  echo "      WARNING: 0.0.0.0/0 -- the entire internet can reach the ALB."
  echo "      Trino has password auth and Airflow has its login form, but this"
  echo "      removes the network layer entirely. Continuing in 5s; Ctrl-C to stop."
  sleep 5
fi

# The cluster's own NAT gateway address, added automatically and NOT saved to
# .inbound-cidrs.
#
# WHY THIS IS NEEDED
# -------------------
# The nodes are in private subnets. When a node pulls an image from
# harbor.nopega.net it resolves the PUBLIC ALB address, leaves the VPC through
# the NAT gateway, and arrives at the ALB from the NAT's elastic IP -- not from
# whatever address a human put in .inbound-cidrs. With only the human's address
# allowed, the pull fails as:
#
#   failed to do request: Head "https://harbor.nopega.net/v2/.../manifests/...":
#   dial tcp <alb-ip>:443: i/o timeout
#
# A timeout, not a 403, because a security group drops the packet rather than
# rejecting it. Nothing in that message mentions security groups, and the
# obvious reading -- that the pull credential is wrong -- is wrong.
#
# WHY IT IS DERIVED AND NOT SAVED
# ---------------------------------
# The NAT gateway's address changes if the gateway is ever replaced (a VPC
# rebuild, an AZ migration). A value written into .inbound-cidrs once would
# then be stale, and the failure would look exactly like the one above with no
# hint that the saved file is the cause. Re-deriving it on every run means the
# file only ever holds addresses a human chose.
CLUSTER_VPC="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || true)"
NAT_IPS=""
if [ -n "$CLUSTER_VPC" ] && [ "$CLUSTER_VPC" != "None" ]; then
  # Scoped to this VPC: an account with other VPCs would otherwise punch holes
  # for NAT gateways that have nothing to do with this cluster.
  NAT_IPS="$(aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=vpc-id,Values=${CLUSTER_VPC}" "Name=state,Values=available" \
    --query 'NatGateways[].NatGatewayAddresses[].PublicIp' --output text 2>/dev/null || true)"
fi

if [ -n "$NAT_IPS" ]; then
  for ip in $NAT_IPS; do
    case ",$INBOUND_CIDRS," in
      *",${ip}/32,"*) ;;                                   # already present
      *) INBOUND_CIDRS="${INBOUND_CIDRS},${ip}/32" ;;
    esac
  done
  echo "      + NAT gateway $(printf '%s' "$NAT_IPS" | tr '\t' ' ') (so nodes can pull from Harbor)"
else
  echo "      WARNING: no NAT gateway found in ${CLUSTER_VPC:-unknown VPC}."
  echo "               If the nodes are in private subnets, image pulls from"
  echo "               harbor.nopega.net will time out."
fi

echo "      ${INBOUND_CIDRS}"

# ---------------------------------------------------------------------------
# 3. Backends must exist. The controller creates an ALB with an empty target
#    group for a missing Service and reports nothing obvious.
# ---------------------------------------------------------------------------
echo "[3/5] Backend services..."
kubectl get svc airflow-api-server -n airflow >/dev/null 2>&1 \
  || { echo "ERROR: Service airflow-api-server not found in namespace airflow." >&2; exit 1; }
kubectl get svc trino -n data-platform >/dev/null 2>&1 \
  || { echo "ERROR: Service trino not found in namespace data-platform." >&2; exit 1; }
kubectl get svc harbor -n harbor >/dev/null 2>&1 \
  || { echo "ERROR: Service harbor not found in namespace harbor." >&2; exit 1; }
echo "      airflow-api-server, trino, harbor"

# Trino must already require a password. Applying this while authenticationType
# is empty publishes an unauthenticated query engine.
AUTH="$(kubectl get cm -n data-platform -o yaml 2>/dev/null \
  | grep -c 'http-server.authentication.type=PASSWORD' || true)"
if [ "$AUTH" -eq 0 ]; then
  cat >&2 <<EOF
ERROR: Trino does not appear to have PASSWORD authentication enabled.

  Exposing it now would put an unauthenticated query engine on the internet,
  with read and write access to every Iceberg table.

    cd ../../../set_up_component/02_trino_prod
    ./02_create_trino_auth_secrets_prod.sh
    ./03_install_trino_prod.sh
EOF
  exit 1
fi
echo "      Trino requires a password"

# ---------------------------------------------------------------------------
echo "[4/5] Applying..."
sed -e "s|__CERT_ARN__|${CERT_ARN}|g" \
    -e "s|__INBOUND_CIDRS__|${INBOUND_CIDRS}|g" \
    "$MANIFEST" | kubectl apply -f -

echo "[5/5] Waiting for the controller to provision the ALB (up to 4 min)..."
for i in $(seq 1 48); do
  HOST="$(alb_hostname)"
  [ -n "$HOST" ] && break
  sleep 5
done

if [ -z "${HOST:-}" ]; then
  cat >&2 <<EOF

The Ingress was accepted but no ALB hostname appeared.

Almost always a subnet tagging problem: the controller needs public subnets
tagged kubernetes.io/role/elb=1 to place an internet-facing load balancer.
Its log names the exact cause:

  kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=40
EOF
  exit 1
fi

cat <<EOF

ALB provisioned: ${HOST}

Nothing resolves to it yet. Add the DNS records:

  ./02_apply_public_ingress_prod.sh dns

Then, once DNS propagates:

  curl -sI https://trino.nopega.net/v1/info
  curl -sI https://airflow.nopega.net

Give the target groups a minute before judging a 503 -- targets start
unhealthy and need two consecutive passing checks 30s apart.

  ./02_apply_public_ingress_prod.sh verify
EOF
