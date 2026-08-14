#!/usr/bin/env bash
#
# 06_create_vpc_endpoints_prod.sh
#
# Adds an S3 Gateway VPC Endpoint to the cluster's VPC.
#
# WHY THIS IS THE SINGLE LARGEST COST ITEM ON THE PLATFORM
# ----------------------------------------------------------
# Nodes run in private subnets and reach the internet through one NAT gateway
# (see eks-cluster.yaml). Without a VPC endpoint, every byte read from or
# written to S3 is internet traffic as far as the VPC is concerned, so it is
# billed as NAT data processing at roughly $0.045/GB in ap-southeast-1 --
# on top of the NAT gateway's own ~$32/month.
#
# For an ordinary web application that is a rounding error. For this platform
# it is not, because S3 *is* the storage layer:
#
#   Trino scanning 1 TB for a report        ~ $45   per run
#   Spark reading 1 TB and writing 200 GB   ~ $54   per run
#   The same ETL once a day for a month     ~ $1,600
#
# None of that appears on the S3 bill. It appears under "NAT Gateway data
# processing", where nobody looks when they are trying to work out why
# querying a lakehouse is expensive.
#
# A Gateway Endpoint removes it entirely. It costs nothing -- no hourly charge,
# no per-GB charge -- and it works by adding an S3 prefix-list route to the
# subnets' route tables, so traffic to S3 never reaches the NAT gateway at all.
# There is no application change and nothing to configure in any pod.
#
# WHY GATEWAY AND NOT INTERFACE
# ------------------------------
# S3 offers both. An Interface Endpoint (PrivateLink) costs ~$7/month per AZ
# plus $0.01/GB and is only needed when traffic must come from on-premises or
# a peered VPC. Everything here is inside this VPC, so the free Gateway
# Endpoint is strictly better.
#
# Usage:
#   ./06_create_vpc_endpoints_prod.sh          # create (idempotent)
#   ./06_create_vpc_endpoints_prod.sh verify   # report state and route tables
#   ./06_create_vpc_endpoints_prod.sh delete   # remove the endpoint
#
set -euo pipefail

REGION="ap-southeast-1"
CLUSTER_NAME="data-platform-prod"
MODE="${1:-deploy}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws

# ---------------------------------------------------------------------------
# The VPC is the one eksctl created for the cluster, so it is looked up rather
# than hardcoded -- a rebuilt cluster gets a new VPC ID.
# ---------------------------------------------------------------------------
VPC_ID="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || true)"
[ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ] || {
  echo "ERROR: could not find the VPC for cluster '${CLUSTER_NAME}'." >&2
  exit 1
}

SERVICE_NAME="com.amazonaws.${REGION}.s3"

existing_endpoint() {
  aws ec2 describe-vpc-endpoints --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
              "Name=service-name,Values=${SERVICE_NAME}" \
              "Name=vpc-endpoint-type,Values=Gateway" \
    --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>/dev/null | grep -v '^None$' || true
}

if [ "$MODE" = "verify" ]; then
  echo "VPC: ${VPC_ID}"
  echo ""
  echo "=== S3 gateway endpoint ==="
  EP="$(existing_endpoint)"
  if [ -n "$EP" ]; then
    aws ec2 describe-vpc-endpoints --region "$REGION" --vpc-endpoint-ids "$EP" \
      --query 'VpcEndpoints[0].[VpcEndpointId,State,RouteTableIds]' --output json
  else
    echo "  NOT PRESENT -- all S3 traffic is being billed through the NAT gateway"
  fi
  echo ""
  echo "=== route tables carrying an S3 prefix-list route ==="
  # This is the check that actually matters. An endpoint can exist and still be
  # associated with zero route tables, in which case it does nothing at all
  # while looking perfectly healthy in the console.
  aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'RouteTables[].{RouteTable:RouteTableId,S3Routes:Routes[?DestinationPrefixListId!=null].[DestinationPrefixListId,GatewayId]}' \
    --output json
  echo ""
  echo "=== NAT gateways in this VPC (what the endpoint is diverting traffic away from) ==="
  aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=vpc-id,Values=${VPC_ID}" \
    --query 'NatGateways[].[NatGatewayId,State]' --output text 2>/dev/null || echo "  none"
  exit 0
fi

if [ "$MODE" = "delete" ]; then
  EP="$(existing_endpoint)"
  if [ -n "$EP" ]; then
    aws ec2 delete-vpc-endpoints --region "$REGION" --vpc-endpoint-ids "$EP" >/dev/null
    echo "Deleted ${EP}. S3 traffic now goes back through the NAT gateway and is"
    echo "billed per GB again. Nothing breaks -- it just gets expensive."
  else
    echo "No S3 gateway endpoint to delete."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
echo "[1/3] Finding the private subnets' route tables..."
# Only the private subnets need this. Public subnets route to the internet
# gateway directly and never touch the NAT gateway, so adding the endpoint
# there changes nothing and clutters the route table.
#
# A private subnet is identified by having a route to a NAT gateway -- more
# reliable than matching on a name tag, which eksctl's naming could change.
ROUTE_TABLES="$(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'RouteTables[?Routes[?NatGatewayId!=null]].RouteTableId' \
  --output text)"

if [ -z "$ROUTE_TABLES" ]; then
  echo "ERROR: no route table in ${VPC_ID} routes through a NAT gateway." >&2
  echo "       Either the nodes are in public subnets (in which case this" >&2
  echo "       endpoint is unnecessary) or the VPC is not what we think." >&2
  exit 1
fi
RT_COUNT="$(printf '%s' "$ROUTE_TABLES" | wc -w | tr -d ' ')"
echo "      ${RT_COUNT} private route table(s): ${ROUTE_TABLES}"

echo "[2/3] Creating or updating the endpoint..."
EP="$(existing_endpoint)"
if [ -n "$EP" ]; then
  # Associating an already-associated route table is an error, so only the
  # missing ones are added. This is what makes the script safe to re-run after
  # a node group is added in a new AZ with its own route table.
  CURRENT="$(aws ec2 describe-vpc-endpoints --region "$REGION" --vpc-endpoint-ids "$EP" \
    --query 'VpcEndpoints[0].RouteTableIds' --output text)"
  TO_ADD=""
  for rt in $ROUTE_TABLES; do
    case " $CURRENT " in
      *" $rt "*) ;;
      *) TO_ADD="$TO_ADD $rt" ;;
    esac
  done
  if [ -n "$(printf '%s' "$TO_ADD" | tr -d ' ')" ]; then
    # shellcheck disable=SC2086
    aws ec2 modify-vpc-endpoint --region "$REGION" --vpc-endpoint-id "$EP" \
      --add-route-table-ids $TO_ADD >/dev/null
    echo "      ${EP} exists, added route tables:${TO_ADD}"
  else
    echo "      ${EP} exists and already covers every private route table"
  fi
else
  # shellcheck disable=SC2086
  EP="$(aws ec2 create-vpc-endpoint --region "$REGION" \
    --vpc-id "$VPC_ID" \
    --service-name "$SERVICE_NAME" \
    --vpc-endpoint-type Gateway \
    --route-table-ids $ROUTE_TABLES \
    --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=${CLUSTER_NAME}-s3-gateway}]" \
    --query 'VpcEndpoint.VpcEndpointId' --output text)"
  echo "      created ${EP}"
fi

echo "[3/3] Confirming the routes landed..."
aws ec2 describe-route-tables --region "$REGION" \
  --route-table-ids $ROUTE_TABLES \
  --query 'RouteTables[].{RouteTable:RouteTableId,S3:Routes[?DestinationPrefixListId!=null].DestinationPrefixListId}' \
  --output json

cat <<EOF

Done. S3 traffic from the private subnets now leaves via the gateway endpoint
instead of the NAT gateway, at no charge.

No pod needs restarting and no configuration changes -- routing is transparent
to the application. Existing connections continue on their old path and new
ones take the endpoint.

Worth knowing:

  The endpoint only covers S3 in ${REGION}. A bucket in another region still
  goes through the NAT gateway, which is one more reason every bucket here is
  created with an explicit LocationConstraint.

  ECR is NOT covered by this. Pulling public images still traverses the NAT
  gateway -- part of why the platform's own images move to Harbor, whose
  blobs live in S3 and therefore now travel free.

Check the effect on the bill under Cost Explorer -> NAT Gateway ->
"NatGateway-Bytes", not under S3.
EOF
