# cloudflared — external access to the platform

Puts the Airflow UI (and later Harbor) on `nopega.net` without opening a single
inbound port on the cluster.

---

## What this actually is

`cloudflared` is not a CLI you run a command with and walk away from — it is a
long-running process that holds an **outbound** connection open to Cloudflare
and waits for traffic to be handed back down it.

```
visitor's browser
      |
      v
Cloudflare edge  ── TLS terminates here, Access checks identity here
      |
      |  (the tunnel: opened FROM the cluster, outbound)
      v
cloudflared pod  ── in this cluster
      |
      v
airflow-api-server.airflow.svc.cluster.local:8080
```

It does the same job as an Ingress controller — route requests to in-cluster
Services by hostname — but the connection is established in the opposite
direction. An Ingress needs a LoadBalancer with a public IP listening on a
port; this needs nothing listening at all.

| | Ingress + ALB/NLB | cloudflared |
|---|---|---|
| Public IP | required | none |
| Inbound security-group rule | required | none |
| Cost | ~$20/month per load balancer | included with the domain |
| TLS certificate | issue and renew (ACM) | Cloudflare handles it |
| Reachable by port scan | yes | no — nothing is listening |

The trade-off, stated plainly: Cloudflare becomes a hard dependency for
*reaching* the platform from outside. If Cloudflare is down, the web UIs are
unreachable. Nothing inside the cluster is affected — DAGs keep running, Trino
keeps serving in-cluster queries, and `kubectl port-forward` still works for an
operator.

---

## Why it runs as a Deployment and not on your laptop

The page Cloudflare shows when you create a tunnel offers a command like
`cloudflared.exe service install <token>`, which installs it on one machine.
That machine then *is* the tunnel: close the laptop and every hostname on it
goes down.

The same binary runs here as a container instead, on nodes that are up
regardless of whether anyone's laptop is. Two replicas, on different nodes, so
a node replacement or a rolling update never leaves zero connectors.

The token is not tied to a machine — it identifies the tunnel. Whoever holds
it can register as a connector, which is exactly why it lives in AWS Secrets
Manager and never in a file or a shell argument.

---

## Prerequisites

Everything below must be true before `./01_install_cloudflared_prod.sh` will
work. The script checks each one and fails with the fix rather than deploying
something broken.

| Needs | Why | Check |
|---|---|---|
| A running EKS cluster with a `workload=critical` node | the pods are pinned there — never Spot, since a reclaim would take the only way in offline | `kubectl get nodes -l workload=critical` |
| A tunnel created in Cloudflare | the token comes from it | see below |
| That tunnel's token in Secrets Manager | the script reads it at apply time | `aws secretsmanager describe-secret --secret-id data-platform-prod-cloudflare-tunnel-token --region ap-southeast-1` |
| `kubectl` and `aws` on PATH | — | `kubectl version --client && aws --version` |

The Services being exposed (Airflow, Harbor) do **not** need to exist yet. The
tunnel connects fine with nothing routed through it; hostnames can be added
afterwards without redeploying.

---

## Step 1 — create the tunnel in Cloudflare

1. Go to <https://one.dash.cloudflare.com> (Cloudflare One, not the main
   dashboard)
2. **Networks → Tunnels → Create a tunnel**
3. Connector type: **Cloudflared**
4. Name it — this project uses `aws-tunnel`
5. **Save tunnel**

The next screen shows an install command per operating system. **Do not run
it** — it installs cloudflared on your laptop, which is not where it should
run. The only thing needed from that screen is the token inside the command.

## Step 2 — store the token

The token is the long `eyJhIjoi...` string at the end of the install command.
Click the copy button on that command, then:

```bash
pbpaste | awk '{print $NF}' | tr -d '[:space:]' > /tmp/cf-token.txt

aws secretsmanager create-secret \
  --name data-platform-prod-cloudflare-tunnel-token \
  --region ap-southeast-1 \
  --description "Cloudflare Tunnel token for aws-tunnel" \
  --secret-string "file:///tmp/cf-token.txt" \
  --no-cli-pager

rm /tmp/cf-token.txt
```

`awk '{print $NF}'` takes the last field, so this works whether the clipboard
holds the whole command or just the token.

The value goes via a file and `file://` rather than being pasted into the
command, so the token never lands in shell history.

Confirm it stored correctly — a wrong `file://` path would silently store the
literal string `file:///tmp/cf-token.txt` instead:

```bash
aws secretsmanager get-secret-value \
  --secret-id data-platform-prod-cloudflare-tunnel-token \
  --region ap-southeast-1 --query SecretString --output text --no-cli-pager \
  | awk '{print substr($0,1,8) "  (" length($0) " chars)"}'
```

Expected: starts `eyJhIjoi`, several hundred characters. The install script
re-checks the length and refuses to deploy a token under 80 characters, since
a truncated one produces a CrashLoopBackOff that only says "invalid token".

## Step 3 — deploy

```bash
./01_install_cloudflared_prod.sh
```

Creates the Kubernetes Secret from Secrets Manager, applies
`cloudflared-deployment.yaml`, and waits for the rollout. The tunnel in the
Cloudflare dashboard changes from "Waiting for connection" to connected.

## Step 4 — map hostnames to Services

In the Cloudflare dashboard, on the tunnel's **Public Hostname** tab:

| Subdomain | Domain | Service type | URL |
|---|---|---|---|
| `airflow` | `nopega.net` | HTTP | `airflow-api-server.airflow.svc.cluster.local:8080` |
| `harbor` | `nopega.net` | HTTP | `harbor.harbor.svc.cluster.local:80` *(after Harbor is installed)* |

**HTTP, not HTTPS**, in the service column. The hop from Cloudflare to this
cluster is already encrypted inside the tunnel, and the in-cluster Services do
not serve TLS. Visitors still get HTTPS — Cloudflare terminates it at the edge.

DNS records are created automatically; nothing to add by hand.

## Step 5 — put Cloudflare Access in front

**Do this before sharing the URL.** Without it, the Airflow UI is on the public
internet behind nothing but its own login form.

Cloudflare dashboard → **Access → Applications → Add an application →
Self-hosted** → `airflow.nopega.net` → add a policy (email address, or your
identity provider).

Access checks identity at Cloudflare's edge, so unauthenticated requests never
reach the cluster at all — the login form stops being the only thing between
the internet and the platform.

---

## Verifying

```bash
./01_install_cloudflared_prod.sh verify
```

Reports pod status, **which node each replica landed on** (both on one node
means the anti-affinity preference could not be met and the two replicas are
not real redundancy), and the connector registration lines from the pod logs.

```bash
./01_install_cloudflared_prod.sh logs      # follow the logs
curl -sI https://airflow.nopega.net | head -1
```

`curl` only answers once step 4 is done — the tunnel being connected is not
enough on its own.

---

## Where the routing configuration lives

This is a **remotely-managed** tunnel: the token identifies it, and the
hostname-to-Service mapping is stored in Cloudflare, not in this repository.

The upside is that adding a hostname needs no redeploy. The downside is real
and worth naming: **this repository does not fully describe what is exposed.**
The table in step 4 is the written record; it has to be kept honest by hand.

If that stops being acceptable, the tunnel can be converted to a
locally-managed one — routing moves into a `config.yaml` in a ConfigMap and
becomes reviewable in git, at the cost of a redeploy for every hostname change.

## What deliberately does not go through the tunnel

Being able to expose something cheaply is not a reason to.

- **Polaris management API** — creates catalogs, principals and grants. An
  admin API with that reach stays internal; `port-forward` remains the correct
  way to reach it, even though it is less convenient.
- **Trino coordinator** — used in-cluster by Airflow and Spark. Could be
  exposed behind Access later if people need the query UI; nothing needs it
  today.

---

## Uninstalling

```bash
./01_install_cloudflared_prod.sh uninstall
```

Removes the Deployment and the Kubernetes Secret. The tunnel itself still
exists in Cloudflare with no connectors attached, so its hostnames start
returning errors rather than disappearing — delete the tunnel in the dashboard
too if the removal is meant to be permanent. The token in Secrets Manager is
left alone.
