#!/usr/bin/env bash
# Requests the one ACM certificate shared by the Airflow and Trino host rules.
# ACM public certificates are free; the manual DNS validation is what proves
# that this AWS account is allowed to serve nopega.net.
#
# THE WHOLE FLOW IS IN HERE, NOT IN A README
# --------------------------------------------
# Requesting the certificate, writing the zone file to import, waiting for the
# records to resolve, and waiting for ACM to validate were four manual steps
# done from notes. Every one of them was done wrong at least once -- a token
# hand-copied into the zone file, a record added after ACM had already checked
# and so stuck behind 30 minutes of negative caching, a "why is it still
# pending" with no way to tell which domain was holding it up.
#
# So `request` and `renew` now run the whole sequence and stop only where a
# human is genuinely required: pasting a file into Cloudflare.
#
# Usage:
#   ./01_request_acm_certificate_prod.sh          # request, then guide + wait
#   ./01_request_acm_certificate_prod.sh renew    # NEW certificate, then guide + wait
#   ./01_request_acm_certificate_prod.sh dns      # print CNAMEs, change nothing
#   ./01_request_acm_certificate_prod.sh wait     # resume waiting on an existing request
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
#
# argocd was added later still, for a concrete reason: `kubectl port-forward`
# drops the connection during a sync that applies dozens of resources, and the
# UI reports it as "Request has been terminated" -- which reads like an Argo CD
# fault and is a tunnel timing out.
#
# prometheus: Grafana already renders these metrics, so this is not for
# dashboards. It is for writing and debugging PromQL against the raw series,
# and for reading /targets when something is not being scraped -- both done by
# port-forward repeatedly while building this platform.
#
# A NOTE ON WHEN A NAME REACHES THE CERTIFICATE
# -----------------------------------------------
# Editing this list changes nothing on its own. The certificate is immutable
# once issued, so a name added here only exists after `renew` runs and the new
# certificate validates. Adding a name and assuming the live certificate
# carries it is a mistake that surfaces much later, as a TLS warning on exactly
# the hostname added last -- or, as happened here, as an import that adds
# nothing because the file was generated from the OLD certificate.
#
# `verify` prints the names the live certificate actually carries. Trust that,
# not this list.
SAN_DOMAINS="airflow.nopega.net harbor.nopega.net grafana.nopega.net argocd.nopega.net prometheus.nopega.net"
MODE="${1:-request}"

# Every name that must be on the certificate, primary included. Used to check an
# existing certificate rather than assuming one found by domain name is usable.
ALL_DOMAINS="$PRIMARY_DOMAIN $SAN_DOMAINS"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZONE="nopega.net"
RECORDS_FILE="$SCRIPT_DIR/acm-validation-records.txt"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws; need dig

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


# Write the Cloudflare import file from what ACM actually returned.
#
# Generated, never hand-edited. Every previous round of this was copied by hand
# out of a printed table, and a mistyped token produces a record that resolves
# to nothing while looking correct -- which is indistinguishable from "ACM has
# not checked yet" for the thirty minutes it takes to give up and look again.
write_records_file() {
  local arn="$1"
  {
    cat <<EOF
; ACM DNS validation records for ${ZONE}
;
; GENERATED by 01_request_acm_certificate_prod.sh -- do not edit by hand.
; Certificate: ${arn}
; Domains:     $(printf '%s' "$ALL_DOMAINS" | tr ' ' ',' | sed 's/,/, /g')
;
; HOW TO IMPORT
;   Cloudflare -> ${ZONE} -> DNS -> Records -> Import
;   Leave "Proxy imported DNS records" UNCHECKED.
;
; Proxying these makes Cloudflare answer with its own address instead of the
; acm-validations.aws target, so ACM never sees the record and the certificate
; sits in PENDING_VALIDATION forever with nothing to explain why.
;
; DO NOT DELETE THESE AFTER THE CERTIFICATE IS ISSUED.
; ACM re-checks them to renew automatically every year. Remove them and the
; renewal fails silently ~11 months later.
;
; Records for names already validated in this account are unchanged -- ACM
; reuses the same token per domain -- so Cloudflare will report them as
; duplicates and skip them. Only genuinely new names produce a new row.
;
; TTL 1 means "automatic" to Cloudflare.

EOF
    aws acm describe-certificate --region "$REGION" --certificate-arn "$arn" \
      --query 'Certificate.DomainValidationOptions[].[ResourceRecord.Name,ResourceRecord.Type,ResourceRecord.Value]' \
      --output text | while IFS=$'\t' read -r name type value; do
        [ -n "$name" ] && [ "$name" != "None" ] && printf '%s\t1\tIN\t%s\t%s\n' "$name" "$type" "$value"
      done
  } > "$RECORDS_FILE"
}

# Ask the zone's own nameserver, not a public resolver.
#
# A resolver that already answered NXDOMAIN for a name caches that answer for
# the SOA minimum -- 1800s here -- so it keeps saying "missing" for half an
# hour after the record exists. The authoritative server has no such cache and
# answers the truth immediately.
authoritative_ns() {
  dig +short NS "$ZONE" 2>/dev/null | head -1
}

# Wait until every validation CNAME resolves. This is the step that decides how
# long the whole thing takes: ACM checks on its own cycle, and a record that is
# already live when it looks is validated in minutes rather than after a
# negative-cache expiry.
wait_for_dns() {
  local arn="$1" ns names missing waited=0
  ns="$(authoritative_ns)"
  [ -n "$ns" ] || { echo "      cannot find a nameserver for ${ZONE}; skipping the DNS check"; return 0; }
  echo "      asking ${ns}"

  names="$(aws acm describe-certificate --region "$REGION" --certificate-arn "$arn" \
    --query 'Certificate.DomainValidationOptions[].ResourceRecord.Name' --output text 2>/dev/null | tr '\t' '\n')"

  while [ "$waited" -lt 900 ]; do
    missing=""
    for n in $names; do
      [ -n "$n" ] && [ "$n" != "None" ] || continue
      [ -n "$(dig +short CNAME "$n" @"$ns" 2>/dev/null)" ] || missing="$missing $n"
    done
    if [ -z "$missing" ]; then
      if [ "$waited" -eq 0 ]; then
        echo "      all validation records already resolve -- nothing new was"
        echo "      needed. ACM reuses the same token per domain per account,"
        echo "      so a renew that adds no new names asks for CNAMEs the zone"
        echo "      already has."
      else
        echo "      all validation records resolve"
      fi
      return 0
    fi
    if [ "$waited" -eq 0 ]; then
      echo "      still missing:"
      for n in $missing; do echo "        $n"; done
      echo "      (import the file above; this will notice on its own)"
    fi
    sleep 15
    waited=$((waited + 15))
    printf '.'
  done
  echo ""
  echo "      still missing after 15 minutes:"
  for n in $missing; do echo "        $n"; done
  echo "      Check the Name field in Cloudflare -- pasting the FULL name into a"
  echo "      zone that appends its own suffix produces name.${ZONE}.${ZONE}."
  return 1
}

# Then wait on ACM itself. Separate from the DNS wait on purpose: knowing which
# of the two is outstanding is the difference between "I typed the record wrong"
# and "AWS has not looked yet".
wait_for_issued() {
  local arn="$1" status waited=0
  while [ "$waited" -lt 2400 ]; do
    status="$(aws acm describe-certificate --region "$REGION" --certificate-arn "$arn" \
      --query 'Certificate.Status' --output text 2>/dev/null || echo UNKNOWN)"
    if [ "$status" = "ISSUED" ]; then
      echo ""
      echo "      ISSUED"
      return 0
    fi
    if [ "$status" = "FAILED" ] || [ "$status" = "VALIDATION_TIMED_OUT" ]; then
      echo ""
      echo "ERROR: certificate ended in ${status}." >&2
      return 1
    fi
    sleep 20
    waited=$((waited + 20))
    printf '.'
  done
  echo ""
  echo "      still ${status} after 40 minutes."
  echo "      Per-domain detail: $0 dns"
  return 1
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
  wait)
    ARN="$(certificate_arn)"
    [ -n "$ARN" ] || { echo "No certificate request found. Run $0 first." >&2; exit 1; }
    echo "Certificate: $ARN"
    write_records_file "$ARN"
    echo ""
    echo "[1/2] Waiting for the validation records to resolve..."
    wait_for_dns "$ARN" || exit 1
    echo "[2/2] Waiting for ACM to validate..."
    wait_for_issued "$ARN" || exit 1
    exit 0
    ;;
  request|renew) ;;
  *) echo "Usage: $0 [request|renew|wait|dns|verify]" >&2; exit 2 ;;
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
echo "[1/4] Validation records"
print_dns_records "$ARN"

echo ""
echo "[2/4] Writing the Cloudflare import file..."
write_records_file "$ARN"
echo "      $RECORDS_FILE"
cat <<EOF

      IMPORT IT NOW, before ACM's first check.

        Cloudflare -> ${ZONE} -> DNS -> Records -> Import
        Select:  ${RECORDS_FILE}
        Leave "Proxy imported DNS records" UNCHECKED.

      Names already validated in this account keep the same token, so
      Cloudflare skips them as duplicates. Only new names create a row.

      Importing promptly is what keeps this to minutes. A record added after
      ACM has already looked sits behind the resolver's negative cache -- the
      SOA minimum for ${ZONE}, which is 1800 seconds.

EOF

# Stop and let a human confirm the import actually happened, rather than
# discovering the outcome from which branch of the DNS wait we fall into.
#
# The check below can pass WITHOUT an import: ACM issues the same validation
# token per domain per account, so a renew that adds no new names asks for
# CNAMEs that already exist in the zone. That is correct and safe -- but it
# looked alarming the first time, so the pause is explicit and says which it
# was.
echo "[3/4] Waiting for the records to resolve..."
printf '      Press Enter once the import is done (or if the rows already exist): '
read -r _
wait_for_dns "$ARN" || exit 1

echo "[4/4] Waiting for ACM to validate..."
wait_for_issued "$ARN" || exit 1

cat <<EOF

Next:

  ./02_apply_public_ingress_prod.sh

The previous certificate keeps serving traffic until that runs, so nothing has
been interrupted. Delete it afterwards, not before.

Keep the validation CNAMEs in place: ACM re-reads them to renew automatically
about eleven months from now, and their absence fails silently.
EOF
