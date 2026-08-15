# How to monitor the data platform

> *"How to monitor your data platform."* — Bonus 2

What the platform reports about itself, where to look, and the three failures
this setup exists because of.

Installation is `set_up_cluster/06_monitoring_prod/README.md`. This is the
operating guide.

## Where to look

| | URL | Login |
|---|---|---|
| Grafana | https://grafana.nopega.net | `admin` — `00_create_grafana_secret_prod.sh show` |
| Prometheus | https://prometheus.nopega.net | none — allowlist only |
| Alertmanager | port-forward | none |

Prometheus is exposed for the two things Grafana cannot do: writing PromQL
against raw series, and reading `/targets` when something is not being scraped.
Both were done by port-forward repeatedly while building this platform.

## What is scraped

Nine ServiceMonitors and one PodMonitor, about 31 targets.

| Source | Gives | Wired in |
|---|---|---|
| kubelet / cAdvisor / node-exporter | CPU, memory, disk, network per node and pod | bundled |
| kube-state-metrics | Kubernetes object state — Pending pods, restarts, replica counts | bundled |
| **Trino** (JMX exporter sidecar) | queries running / queued / failed, memory pool, resource-group state | `02_trino_prod` values → `jmx` + `serviceMonitor` |
| **Spark operator** (PodMonitor) | SparkApplication lifecycle: submitted, running, succeeded, failed, and how long a driver waited for a node | `06_spark_prod` values → `prometheus.metrics` + `podMonitor` |
| **Airflow** (StatsD exporter) | DAG and task duration, tasks queued vs running, scheduler loop time | `04_airflow_prod` values → `statsd` + `statsd-servicemonitor.yaml` |
| **Cluster Autoscaler** | unschedulable pods, node group sizes, failed scale-ups | `09_cluster_autoscaler_prod` values |
| **AWS LB controller** | reconciliation errors | `08_load_balancer_controller_prod` values |

Deliberately **not** scraped: `kubeEtcd`, `kubeScheduler`,
`kubeControllerManager`, `kubeProxy`. EKS runs the control plane as a managed
service and does not expose them. Left enabled they produce targets that are
permanently DOWN and alerts that never clear — and "some things are always red"
teaches everyone to stop reading the red things.

## Checking it is actually working

`helm status` reports a healthy release for a Prometheus scraping nothing at
all. The check that matters is the target list:

```bash
cd script/set_up_cluster/06_monitoring_prod
./01_install_monitoring_prod.sh targets
```

Every job should be `ok`. A job **missing entirely** is the quieter failure: it
means a ServiceMonitor's label selector matches no Service, and nothing reports
that anywhere.

```bash
kubectl get servicemonitor,podmonitor -A     # do the objects exist
```

## The three failures this setup exists because of

Each was silent. Each was found by something other than looking at a dashboard.

**1. Prometheus ignoring every ServiceMonitor it did not create.**
`serviceMonitorSelectorNilUsesHelmValues` defaults to `true`, which means
Prometheus only discovers ServiceMonitors carrying its own Helm release labels.
Trino's, the autoscaler's, the LB controller's — all ignored. No error;
`kubectl get servicemonitors` lists them; the graphs are simply empty. Set to
`false` in values, along with the pod / probe / rule / scrapeConfig equivalents.

**2. An HPA that had never once scaled.** Trino's worker HPA was created on day
one and reported `<unknown>/50%` for three days, logging
`FailedGetResourceMetric` every 15 seconds — 5,918 times in 24 hours — because
EKS does not install metrics-server and nothing said so. A Deployment parked at
its minimum replicas looks exactly like a Deployment with no reason to scale.

It surfaced when Argo CD marked the Trino Application `Degraded`, which is a
fair argument for having installed Argo CD.

**3. Enabling a metrics sidecar switching autoscaling off.** With
metrics-server installed, the HPA failed differently:
`missing request for memory in container jmx-exporter`. HPA utilisation is a
percentage of the *request*, so one container in the pod without one makes the
figure undefined for the whole pod. Adding the Trino JMX exporter had quietly
disabled the thing meant to absorb Team A's 10am burst.

The general lesson, written into several values files since: **turning a
feature on has consequences the feature does not mention, and none of these
produced an error at apply time.**

## Alerts

The kube-prometheus-stack default rules, minus the ones for components EKS does
not expose, plus three written for the autoscaler in
`09_cluster_autoscaler_prod/chart/cluster-autoscaler/values.yaml`:

| Alert | Fires when | Why it matters here |
|---|---|---|
| `ClusterAutoscalerPodsStuckPending` | pods unschedulable 15 min | the state this cluster has actually been in, twice, with a Spark driver |
| `ClusterAutoscalerUnableToScale` | `cluster_safe_to_autoscale == 0` for 10 min | scale-ups quietly never happening |
| `ClusterAutoscalerFailedScaleUp` | a failed attempt in 30 min | usually Spot capacity unavailable |

`for: 15m` on the first is the point — pods are briefly unschedulable on every
normal scale-up, and alerting on that would fire on every Spark run.

**Alertmanager has no receiver configured.** Alerts fire, deduplicate, and are
visible in its UI. They go nowhere else. That is a decision about who is on
call, not a technical step — and the DAG's own failure email
(`04_create_smtp_secret_prod.sh`) covers the one thing that genuinely needs
waking someone.

Two things the chart's rules cannot express, both worth knowing about the
platform rather than the cluster:

- **A gold table that stops being written** is a data problem the DAG catches
  itself: each task fails loudly if row counts do not reconcile.
- **Freshness** — `days_behind` in `docs/powerbi/queries.sql` is expected to be
  about 90, because TLC publishes with a two-month lag and the DAG processes
  three months back. A value near zero would mean someone backfilled by hand.

## Retention, and where the data lives

Prometheus keeps **7 days or 18GiB, whichever comes first**, on a 20Gi gp3
volume attached to one on-demand node.

Both limits are set on purpose. Time alone is a promise the disk cannot keep:
if the ingest rate rises — a new exporter, more pods, a busier day — seven days
of samples can outgrow the volume before the clock runs out, and Prometheus
fills the disk and crash-loops. The size limit makes the disk the binding
constraint instead, and sits below the volume size because the WAL and head
block share it and are not counted.

Seven days answers what this platform is actually asked: did last night's DAG
run slower than usual, did the autoscaler thrash this week, was the cluster full
when that driver went Pending.

Grafana keeps its own dashboards and API keys on a separate 5Gi volume, with
`deploymentStrategy: Recreate` — a ReadWriteOnce volume cannot be attached to
two nodes, so a rolling update leaves the new pod waiting forever on a volume
the old one holds. That failure is invisible from outside: the old pod keeps
serving while the Deployment has been stuck for hours.

**Nothing is shipped off-cluster.** Past seven days the data is gone for good.
The growth path is **Grafana Mimir 3.1.2** (`mimir-distributed` 6.1.0):
Prometheus `remote_write`s into it, Mimir ships compacted blocks to S3, and
Grafana keeps every dashboard because Mimir serves the same query API. Not
built — pinned as a planned upgrade, with the trigger conditions and the Thanos
comparison, in `STACK_SUMMARY.md`. And
EKS control-plane logs are deliberately **off**: they reached 645 GB unread in
CloudWatch. What that costs in governance terms, and what turning it back on
would require, is in `SECURITY_GOVERNANCE.md`.

## Cost visibility

Grafana has two CloudWatch datasources with Cost Explorer permissions, so the
cost claims in `COST.md` are checkable rather than asserted.

The second one points at **us-east-1** deliberately: CloudWatch publishes the
`AWS/Billing` namespace only into that region regardless of where anything
runs, and pointing it at ap-southeast-1 returns an empty metric list with no
error — which reads exactly like missing permissions.
