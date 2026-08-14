# 06_monitoring_prod — Prometheus, Grafana, Alertmanager

Bonus 2 of the take-home: how the platform is monitored.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm pull prometheus-community/kube-prometheus-stack --untar --untardir ./chart

./00_create_grafana_secret_prod.sh
./01_install_monitoring_prod.sh
./01_install_monitoring_prod.sh targets
```

## Why this is step 06

It was written as step 10 first — the next free number after the cluster
autoscaler — and that was wrong for a reason worth recording rather than
quietly renumbering.

The Prometheus Operator installs the `ServiceMonitor` and `PrometheusRule`
CRDs. A Helm chart cannot create an object whose kind the API server does not
know about; it fails with `no matches for kind "ServiceMonitor"`. Three charts
already vendored in this repo ship those templates:

| Chart | Step | Template |
|---|---|---|
| aws-load-balancer-controller | cluster 08 | ServiceMonitor |
| cluster-autoscaler | cluster 10 | ServiceMonitor, PrometheusRule |
| trino | component 02 | ServiceMonitor |

Installed last, monitoring would force each of those to be revisited with a
`helm upgrade` after the fact — one step reaching back into releases that
earlier steps own. Installed here, each simply sets `serviceMonitor.enabled:
true` in its own values file, which is where anyone would look for it.

### What it actually depends on

| Needs first | Why |
|---|---|
| 02 EKS cluster | — |
| 05 StorageClass | Prometheus and Grafana need PVCs that can bind. Without a **default** StorageClass they stay Pending, and so do the pods behind them, with no event mentioning storage until you describe the PVC |

And, specifically, what it does **not** need first:

- **08 load balancer controller / 09 public ALB.** The Grafana Ingress is
  created here and sits unreconciled until the controller exists, then gets
  picked up. That is ordinary declarative behaviour, not a broken install. Only
  the ALB *address* is late, not the object.
- **03 IRSA.** Used only by the AWS cost datasource, which is a later step.
- **04 RDS.** Grafana keeps its own state on its PVC.

So the numbering moved: what were 06–09 became 07–10, and monitoring took 06.

## Where it runs, and what that costs

On `workload=critical`, never on Spot.

Prometheus holds its recent samples in memory and writes to an EBS volume
bound to a single availability zone. A Spot reclamation loses the in-memory
window and forces the volume to reattach — losing observability exactly when
nodes are churning, which is exactly when it is worth having.

That decision is what took `ng-ondemand` from 4 nodes to 5: the stack asks for
roughly 1 vCPU and 2.5Gi, and the group went to four nodes in the first place
because a Spark driver could not find 1000m free. About \$85/month in
ap-southeast-1, recorded in `eks-cluster.yaml` next to the other three times
that group grew.

## The credential

`00_create_grafana_secret_prod.sh` generates the admin password, stores it in
AWS Secrets Manager, and mounts it as a Kubernetes Secret. `values.yaml` names
the Secret and never contains the password.

```bash
./00_create_grafana_secret_prod.sh show     # print the login
./00_create_grafana_secret_prod.sh verify   # do the cluster and AWS agree
./00_create_grafana_secret_prod.sh rotate   # new password (then restart Grafana)
```

`grafana.nopega.net` is a public hostname and the ALB does not authenticate —
it terminates TLS and forwards. The chart's default `admin/prom-operator` would
put a map of the platform's internals on the open internet. A generated
32-character password is the floor here; Cloudflare Access in front, as Harbor
and Airflow use, is the better answer and is not done yet.

## The CRD trap

Helm applies CRDs on first install and then never touches them again. It does
not upgrade them and does not report that it skipped them.

Bump the chart without doing anything about it and you get new controller code
reading old CRD schemas. The failure is not an error: fields the new chart sets
are dropped by the API server, so a ServiceMonitor looks applied and scrapes
nothing.

```bash
./01_install_monitoring_prod.sh upgrade-crds   # before any chart bump
```

`deploy` calls this automatically when the release already exists.

## Checking it works

`helm status` reports a successful release for a Prometheus that is scraping
nothing at all — a ServiceMonitor matching no Service is not an error anywhere.
So the check that matters is the target list:

```bash
./01_install_monitoring_prod.sh targets
```

It prints every ServiceMonitor the operator can see, then the live targets
grouped by job and health. `DOWN` means Prometheus found the target and could
not scrape it — usually a port name that does not match, or a NetworkPolicy.
A job that is absent entirely means the ServiceMonitor's label selector matches
no Service, which is the more common and quieter mistake.

```bash
./01_install_monitoring_prod.sh verify   # pods, PVCs, CRDs, ingress
./01_install_monitoring_prod.sh ui       # Grafana on localhost:3000
```

`ui` works before the ALB and DNS exist, so it is the way to see a dashboard
without waiting on a certificate.

## Uninstalling

`uninstall` removes the release and deliberately leaves the CRDs and PVCs.
Deleting the CRDs deletes every ServiceMonitor in the cluster, including ones
other charts own; deleting the PVCs discards the metric history. The script
prints the commands for doing either on purpose.
