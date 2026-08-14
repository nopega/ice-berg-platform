#!/usr/bin/env bash
# Requests the one ACM certificate shared by the Airflow and Trino host rules.
# ACM public certificates are free; the manual DNS validation is what proves
# that this AWS account is allowed to serve nopega.net.
#
# Usage:
#   ./01_request_acm_certificate_prod.sh          # request or report existing
#   ./01_request_acm_certificate_prod.sh dns      # print CNAMEs for Cloudflare
#   ./01_request_acm_certificate_prod.sh verify   # print status only
set -euo pipefail

REGION="ap-southeast-1"
PRIMARY_DOMAIN="trino.nopega.net"
# Every hostname the ALB will serve must be on this ONE certificate. ACM cannot
# add a domain to a certificate after it is requested -- doing so means
# requesting a new certificate and redoing DNS validation from scratch. So the
# full list has to be right before the first CNAME is created.
#
# harbor is here even though Harbor is not installed yet, precisely because
# adding it later is the expensive path.
#
# grafana was added later anyway, which is exactly the case the comment above
# warned about. Adding it meant requesting a SECOND certificate and validating
# it from scratch -- see the `renew` mode below. The lesson is recorded rather
# than tidied away: list every hostname the platform might plausibly serve
# before the first request, because a name costs nothing on the certificate and
# a great deal once it is issued.
SAN_DOMAINS="airflow.nopega.net harbor.nopega.net grafana.nopega.net"
MODE="${1:-request}"

# Every name that must be on the certificate, primary included. Used to check an
# existing certificate rather than assuming one found by domain name is usable.
ALL_DOMAINS="$PRIMARY_DOMAIN $SAN_DOMAINS"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws

all_certificate_arns() {
  aws acm list-certificates --region "$REGION" \
    --certificate-statuses PENDING_VALIDATION ISSUED INACTIVE \
    --query "CertificateSummaryList[?DomainName=='${PRIMARY_DOMAIN}'].CertificateArn" \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' || true
}

# Which names a certificate actually carries, space-delimited for the
# membership test below. --output text separates list items with TABS, so the
# translate is not optional: without it every name after the first fails to
# match and the script reports a certificate does not cover a domain it
# visibly does.
covers() {
  local arn="$1" covered missing=""
  covered="$(aws acm describe-certificate --region "$REGION" --certificate-arn "$arn" \
    --query 'Certificate.SubjectAlternativeNames' --output text 2>/dev/null | tr '\t\n' '  ')"
  for d in $ALL_DOMAINS; do
    case " $covered " in
      *" $d "*) ;;
      *) missing="$missing $d" ;;
    esac
  done
  printf '%s' "${missing# }"
}

# Prefer a certificate that covers everything. There can legitimately be two
# during a migration: the old one still serving traffic and the new one waiting
# on DNS validation.
certificate_arn() {
  local first="" arn
  for arn in $(all_certificate_arns); do
    [ -n "$first" ] || first="$arn"
    [ -z "$(covers "$arn")" ] && { printf '%s' "$arn"; return; }
  done
  printf '%s' "$first"
}

print_dns_records() {
  local arn="$1" i=0 name
  # ACM returns the certificate immediately but populates ResourceRecord a few
  # seconds later. Querying too early prints a table of "None", which reads like
  # a broken script rather than "not ready yet" -- so wait for the values to
  # actually exist instead of printing placeholders the user cannot act on.
  while [ "$i" -lt 20 ]; do
    name="$(aws acm describe-certificate --region "$REGION" --certificate-arn "$arn" \
      --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' \
      --output text 2>/dev/null || true)"
    [ -n "$name" ] && [ "$name" != "None" ] && break
    i=$((i + 1))
    sleep 3
  done
  aws acm describe-certificate --region "$REGION" --certificate-arn "$arn" \
    --query 'Certificate.DomainValidationOptions[].{domain:DomainName,status:ValidationStatus,record_name:ResourceRecord.Name,record_type:ResourceRecord.Type,record_value:ResourceRecord.Value}' \
    --output table
}

case "$MODE" in
  dns)
    ARN="$(certificate_arn)"
    [ -n "$ARN" ] || { echo "No certificate request found. Run $0 first." >&2; exit 1; }
    echo "Certificate: $ARN"
    echo ""
    print_dns_records "$ARN"
    cat <<'EOF'

For each row, Cloudflare Dashboard -> nopega.net -> DNS -> Add record:
  Type: CNAME
  Name: record_name (Cloudflare accepts the full name)
  Target: record_value
  Proxy status: DNS only (grey cloud)

Do not create an A/CNAME record for airflow or trino yet. Those must point at
the ALB hostname after the Ingress creates it.
EOF
    exit 0
    ;;
  verify)
    ARN="$(certificate_arn)"
    [ -n "$ARN" ] || { echo "Certificate: not requested"; exit 1; }
    aws acm describe-certificate --region "$REGION" --certificate-arn "$ARN" \
      --query 'Certificate.{arn:CertificateArn,status:Status,domains:SubjectAlternativeNames,notAfter:NotAfter}' --output json
    exit 0
    ;;
  request|renew) ;;
  *) echo "Usage: $0 [request|renew|dns|verify]" >&2; exit 2 ;;
esac

ARN="$(certificate_arn)"
if [ -n "$ARN" ] && [ "$MODE" != "renew" ]; then
  MISSING="$(covers "$ARN")"
  if [ -n "$MISSING" ]; then
    # This is the whole reason `renew` exists. ACM certificates are immutable:
    # there is no API to add a subject alternative name. The only path is a new
    # certificate with the full list, validated from scratch.
    #
    # Refusing here rather than silently reusing matters, because the failure
    # otherwise appears much later and somewhere else -- as a browser TLS
    # warning on exactly the one hostname that was added last.
    echo "ERROR: the existing certificate does not cover:${MISSING// /, }" >&2
    echo "       $ARN" >&2
    echo "" >&2
    echo "       ACM cannot add a name to an issued certificate. Request a new" >&2
    echo "       one covering everything, validate it, then re-run the Ingress:" >&2
    echo "" >&2
    echo "         $0 renew" >&2
    echo "" >&2
    echo "       The old certificate keeps serving traffic until the Ingress is" >&2
    echo "       re-applied, so this is not an outage. Delete it afterwards." >&2
    exit 1
  fi
  echo "Existing certificate request: $ARN"
else
  [ "$MODE" = "renew" ] && echo "Requesting a NEW certificate covering: ${ALL_DOMAINS}"
  # shellcheck disable=SC2086
  ARN="$(aws acm request-certificate --region "$REGION" \
    --domain-name "$PRIMARY_DOMAIN" --subject-alternative-names $SAN_DOMAINS \
    --validation-method DNS --key-algorithm RSA_2048 \
    --options CertificateTransparencyLoggingPreference=ENABLED \
    --tags Key=Project,Value=data-platform Key=Environment,Value=prod \
    --query CertificateArn --output text)"
  echo "Requested certificate: $ARN"
fi

echo ""
echo "Validation records:"
print_dns_records "$ARN"
cat <<EOF

Next, add the shown CNAME record(s) in Cloudflare as DNS-only records, then:

  ./01_request_acm_certificate_prod.sh verify

Wait for status ISSUED before applying the public Ingress. ACM renews this
certificate automatically as long as the DNS validation CNAMEs remain present.
EOF
