# Network

How a request reaches this platform, how the platform reaches AWS, and which
of those paths costs money.

## The shape of it

```
                        internet
                            │
                            │  HTTPS 443 only, from allowlisted source IPs
                            ▼
              ┌─────────────────────────────┐
              │  AWS ALB (one, shared)      │   TLS terminates here
              │  6 host rules, 1 ACM cert   │   ~$22/month
              └──────────────┬──────────────┘
                             │  HTTP + X-Forwarded-*
   ══════════════════════════╪════════════════════════ VPC boundary
        PUBLIC SUBNETS       │        (2 availability zones)
              ┌──────────────┴──────────────┐
              │      NAT gateway (one)      │   ~$32/mo + $0.045/GB
              └──────────────┬──────────────┘
   ───────────────────────────────────────────────────
        PRIVATE SUBNETS      │
              ┌──────────────▼──────────────┐
              │   EKS nodes                  │
              │   ng-ondemand 5 · ng-spot 0  │
              └───┬──────────────────────┬───┘
                  │                      │
      S3 gateway  │                      │  everything else
      endpoint    │                      │  (Harbor pulls, TLC downloads,
      $0, no NAT  ▼                      ▼   AWS APIs)
              ┌────────┐            ┌─────────────┐
              │   S3   │            │ NAT gateway │
              └────────┘            └─────────────┘
                                            │
                  ┌─────────────────────────┴──┐
                  │  RDS (private, no public   │
                  │  endpoint, ever)           │
                  └────────────────────────────┘
```

## Inbound: one load balancer, six hostnames

Every Ingress carries
`alb.ingress.kubernetes.io/group.name: data-platform-public`, so the AWS Load
Balancer Controller merges them into a **single ALB** rather than creating one
per service.

| Hostname | → Service | Namespace | Health check |
|---|---|---|---|
| `trino.nopega.net` | `trino:8080` | data-platform | `/v1/info` |
| `airflow.nopega.net` | `airflow-api-server:8080` | airflow | `/` |
| `harbor.nopega.net` | `harbor:80` | harbor | `/api/v2.0/ping` |
| `grafana.nopega.net` | `kube-prometheus-stack-grafana:80` | monitoring | `/api/health` |
| `argocd.nopega.net` | `argocd-server:80` | argocd | `/healthz` |
| `prometheus.nopega.net` | `kube-prometheus-stack-prometheus:9090` | monitoring | `/-/healthy` |

**`spark.nopega.net` is on neither the certificate nor the ALB.** The Spark
History Server is written and not deployed, so there is nothing for a host rule
to point at, and a DNS record aimed at an ALB with no matching rule returns 404
from the default action — which reads like a broken deployment rather than an
absent one.

`01_request_acm_certificate_prod.sh` requests six names: `trino` (primary) plus
five SANs. Adding `spark` later is **not** an edit — ACM certificates are
immutable, so it means a new certificate and a full re-validation. That is why
the script's `verify` mode prints the names the *live* certificate carries:
trust that output, not the list in any document including this one.

### Details that each cost an afternoon

**Health check paths are not `/`.** Every one of them answers 200 without a
session. Pointing a check at `/` follows a redirect to a login page and marks
targets unhealthy whenever nobody is logged in.

**`load-balancer-attributes` must be identical on every Ingress in the group,
character for character.** The controller merges them into one model and
refuses to build it at all if two disagree — reported as *conflicting load
balancer attributes*, with the **newest** Ingress left without an ADDRESS while
the others keep working. That reads like the new one failed on its own.

The shared value is `idle_timeout.timeout_seconds=600`, not the 60s default,
for three separate reasons: Trino's first request blocks while the coordinator
plans a wide scan; pushing a container layer to Harbor over a slow uplink
exceeds a minute; and an Argo CD sync applying dozens of resources does too.

**`backend-protocol: HTTP` on Argo CD.** The chart runs `argocd-server` with
`server.insecure: true` precisely so the ALB can terminate TLS. Without the
annotation the ALB speaks HTTPS to a plain HTTP port, every target is unhealthy,
and nothing in Argo CD's log explains it.

**Trino needs `http-server.process-forwarded=true`.** The ALB forwards over
plain HTTP; without this Trino sees an insecure channel, decides password
authentication is forbidden on it, and rejects every login with a message about
HTTPS — while the browser shows a padlock.

## TLS and DNS

One ACM certificate covers all names. **ACM certificates are immutable**: there
is no API to add a subject alternative name, only a full re-request and
re-validation. That list was extended three times on this project (grafana,
argocd, prometheus), each costing a new certificate.

Cloudflare hosts `nopega.net` and every record is **DNS only, never proxied**,
for two reasons:

1. The ALB serves a certificate issued for these exact names. Proxying puts
   Cloudflare's certificate in front and adds a second TLS hop that fails as a
   5xx looking like the origin is down.
2. Cloudflare's free plan caps request bodies at 100 MB — invisible for
   Airflow, fatal for `docker push` to Harbor.

DNS records are created **through the Cloudflare API**, not by zone-file
import. The import path failed silently three times: a file containing rows
Cloudflare considered duplicates reported errors for those and quietly dropped
the rows that were new. See `set_up_public_access/README.md`.

## The source IP allowlist

`alb.ingress.kubernetes.io/inbound-cidrs` on every Ingress. This is the only
network-level control in front of the public hostnames, and there is
deliberately **no default** — a default of `0.0.0.0/0` would publish Airflow
and Trino the moment the script ran, protected by nothing but their login
forms, and would do it silently.

Two kinds of address are in the list:

| Address | Why |
|---|---|
| the operator's `/32` | saved in `.inbound-cidrs`, gitignored |
| **the cluster's own NAT gateway** | added automatically, and not saved |

The second is not obvious. Nodes are in private subnets. When a node pulls an
image from `harbor.nopega.net` it resolves the *public* ALB address, leaves the
VPC through the NAT gateway, and arrives at the ALB from the NAT's elastic IP —
not from any human's address. With only the human's IP allowed, every image
pull times out.

A home connection's address changes. The symptom is a connection that **times
out** rather than one refused; re-run `02_apply_public_ingress_prod.sh` with the
new address.

## Outbound: where the money is

The VPC has **one NAT gateway**, not one per AZ. HA would want one per zone at
~\$32/month each; a single gateway is the deliberate availability trade.

The larger cost is **data processing at ~\$0.045/GB**, and S3 is this
platform's storage layer. A single 1 TB Trino scan would cost about \$45 in NAT
charges — billed under *NAT Gateway*, not under *S3*, which is where nobody
thinks to look.

The **S3 gateway VPC endpoint** removes that entirely: no hourly rate, no
per-GB rate, and S3 traffic routes straight out of the subnet.
`07_vpc_endpoints_prod/` adds it to the live VPC — adding
`serviceEndpoints: [s3]` to `eks-cluster.yaml` changes nothing on a cluster
that already exists.

What still crosses the NAT: container image pulls from public registries, the
NYC TLC Parquet downloads (~60 MB per pipeline run, about \$0.003), and AWS API
calls other than S3.

## Internal network

Nine namespaces:

| Namespace | Holds |
|---|---|
| `data-platform` | Polaris, Trino coordinator and workers |
| `airflow` | scheduler, API server, triggerer, DAG processor, task pods |
| `spark` | Spark drivers and the History Server |
| `spark-operator` | the operator watching for SparkApplications |
| `harbor` | registry, Trivy, its Postgres and Redis |
| `monitoring` | Prometheus, Grafana, Alertmanager, exporters |
| `argocd` | Argo CD |
| `kube-system` | LB controller, cluster autoscaler, metrics-server, CNI |
| `cloudflared` | superseded by the ALB — see below |

Pod-to-pod traffic is flat. **There is no NetworkPolicy anywhere in this
platform**, which means any pod can open a socket to any Service. A compromised
Airflow task pod can reach Trino or Polaris directly, bypassing the ALB and its
allowlist entirely.

This is the largest network gap and it is listed as such in
`SECURITY_GOVERNANCE.md`. Closing it is a default-deny policy per namespace plus
explicit allows — cheap to write, and needing care because the real paths are
not all obvious: the Spark driver talks to Polaris, Airflow talks to the Spark
operator's CRD through the API server, Prometheus scrapes everything.

The internal paths that matter:

```
Airflow task pod ──creates SparkApplication──▶ Kubernetes API
                                                    │
Spark operator ◀────────watches─────────────────────┘
      │ creates
      ▼
Spark driver ──OAuth2──▶ Polaris ──vends creds──▶ S3 (via gateway endpoint)
      │
      └──requests executors──▶ ng-spot

Trino coordinator ──REST──▶ Polaris ──▶ S3
Prometheus ──scrapes──▶ every namespace
```

Airflow's ServiceAccount can create `SparkApplication` objects and read pods,
and deliberately **cannot create pods**. A compromised DAG can ask for a Spark
job — a known image running known code — but cannot start a container of its
own choosing.

## cloudflared

A Cloudflare Tunnel was the original way in, before the ALB existed. It is
superseded: the ALB gives real hostnames, a real certificate and no 100 MB body
cap.

The manifests are still in `03_cloudflared_prod/` and `PROGRESS.md` has listed
it as "redundant, uninstall" for a while. It is kept for now because the tunnel
also fronts `ssh.nopega.net`, which is not part of this platform.
