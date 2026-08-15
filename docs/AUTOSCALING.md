# Autoscaling

Three independent mechanisms, each solving a different problem. They are easy
to confuse and one of them was broken for three days without anyone noticing,
so this document is mostly about which is which and how to tell when one has
stopped.

```
                  a query burst arrives
                           │
                           ▼
        ┌─── HPA ──────────────────────────────┐
        │  more Trino worker PODS               │   needs metrics-server
        └───────────────┬───────────────────────┘
                        │  pods have nowhere to go
                        ▼
        ┌─── Cluster Autoscaler ────────────────┐
        │  more NODES in a group                │   needs ASG tags + IAM
        └───────────────────────────────────────┘

                  a Spark job is submitted
                           │
                           ▼
        ┌─── Cluster Autoscaler, from zero ─────┐
        │  ng-spot 0 → N → 0                    │   needs node-template tags
        └───────────────────────────────────────┘
```

## Layer 1 — HPA: more Trino workers

| | |
|---|---|
| Target | `Deployment/trino-worker` |
| Range | **2 – 5** replicas |
| Triggers | CPU > 50% **or** memory > 80% of request |
| Configured in | `02_trino_prod/chart/trino/values.yaml` → `server.autoscaling` |

This is the answer to the brief's "Team A sends ~100 queries at 10am". Resource
groups stop the two teams starving each other; the HPA adds capacity so the
burst finishes sooner.

`minReplicas` is unset in values and falls back to `server.workers: 2`, which
is what `kubectl describe hpa` reports. Two is the floor because a single
worker makes every query serial.

**It requires metrics-server**, which EKS does not install. See the failure
below — this is the part that was broken.

```bash
kubectl get hpa -A
kubectl describe hpa trino-worker -n data-platform | grep -A4 Conditions
```

`TARGETS` must show real percentages and `ScalingActive` must be `True`.
`<unknown>/50%` means it is not scaling and never will.

## Layer 2 — Cluster Autoscaler: more nodes

Watches for pods that cannot be scheduled and grows the node group that could
host them; removes nodes that have been underused for long enough.

| Group | min | desired | max | Holds |
|---|---|---|---|---|
| `ng-ondemand` | 5 | 5 | 7 | everything stateful — Trino, Polaris, Airflow, Harbor, Prometheus, Spark drivers |
| `ng-spot` | 0 | 0 | 4 | Spark executors only |

| Setting | Value | Why |
|---|---|---|
| `expander` | `least-waste` | picks the group whose new node would be least idle afterwards |
| `scale-down-unneeded-time` | 5m | how long a node must be idle before removal |
| `scale-down-delay-after-add` | 5m | stops a node being added and removed in a loop |
| `max-node-provision-time` | 15m | gives up on a node that never joins |
| `skip-nodes-with-system-pods` | true | will not drain a node running a DaemonSet-adjacent system pod |

Chart version is pinned to the cluster's Kubernetes **minor** — 1.34 to 1.34 —
and the install script asserts it. The autoscaler links the upstream scheduler
code and replays scheduling decisions against a simulated node; a mismatched
minor simulates different rules than the cluster enforces, and the symptom is
not a crash but a scale-up that never happens.

### `ng-ondemand` has min == desired, deliberately

With `minSize: 1` the autoscaler correctly set about draining Harbor, Trino and
Airflow off a node to shrink the group — that is what a min below desired
authorises it to do. Caught from its status ConfigMap
(`scaleDown: CandidatesPresent`) before it acted.

`maxSize` stays above desired so the group can still **grow** when a Spark
driver has nowhere to fit, and so a rolling AMI update has somewhere to place
pods while it cycles.

## Layer 3 — Spot from zero

`ng-spot` sits at zero nodes. A Spark job is submitted, its executors cannot be
scheduled, the autoscaler brings up Spot nodes, the job runs, and five minutes
after it finishes the nodes go away.

This is what makes the cost claim real: Spot's 60–70% discount only helps if
the capacity also disappears when idle. This DAG runs once a day for a few
minutes, so the group costs nothing for the other 23 hours.

**Scaling from zero needs ASG node-template tags.** With no live node to copy,
the autoscaler reads
`k8s.io/cluster-autoscaler/node-template/label/workload=batch` and
`.../taint/spot=true:NoSchedule` off the ASG to imagine what a node in that
group would look like. Without them it concludes a Spot node could not host the
executor — because it does not know the node would carry the matching label —
and does nothing at all.

eksctl's `withAddonPolicies.autoScaler: true` adds the *discovery* tags and the
IAM permissions, **not these**.
`09_cluster_autoscaler_prod/00_create_autoscaler_irsa_and_tags_prod.sh` writes
them, and `01_install...` refuses to install without them.

Proven, not assumed: `ng-spot` was scaled to 0, a Spark job submitted, and a
node appeared on its own within about two minutes.

### Executors need both a label and a toleration

The Spot nodes carry `workload=batch` (a label) and `spot=true:NoSchedule` (a
taint). These are matched by two different fields and are configured
independently:

```yaml
executor:
  nodeSelector:
    workload: batch                 # label — attracts
  tolerations:
    - key: spot                     # taint key — repels unless tolerated
      operator: Equal
      value: "true"
      effect: NoSchedule
```

The smoke test once had a toleration for `workload=batch` — a *label* key used
where the *taint* key belonged. Nothing errors: the executors simply stay
`Pending` with `FailedScheduling`.

## The failure worth reading

**Trino's HPA existed for three days and never scaled once.**

`kubectl get hpa` showed `<unknown>/50%`. The controller logged
`FailedGetResourceMetric` every 15 seconds — 5,918 times in 24 hours — into
events nobody reads. EKS does not ship metrics-server, and nothing said so.

It stayed invisible because **a Deployment parked at its minimum replicas looks
exactly like a Deployment with no reason to scale.** The pods were healthy, the
queries worked, the dashboard was green.

It surfaced only when Argo CD marked the Trino Application `Degraded`.

Installing metrics-server (`10_metrics_server_prod`) produced a *second*
failure with the same shape:

```
ScalingActive  False  FailedGetResourceMetric
missing request for memory in container jmx-exporter
```

HPA utilisation is a percentage of the **request**, so a single container in
the pod without one makes the figure undefined for the whole pod. Enabling the
Trino JMX metrics sidecar had quietly switched off the autoscaling that sidecar
was there to help observe. Fixed by giving it explicit requests — small enough
(192Mi against the worker's 4Gi) not to skew the utilisation the HPA divides by.

Both failures share a shape worth naming: **turning something on had a
consequence it did not mention, and neither produced an error at apply time.**

## Checking all three at once

```bash
# Layer 1 — is the HPA actually able to scale
kubectl get hpa -A

# Layer 2/3 — what the autoscaler thinks
cd script/set_up_cluster/09_cluster_autoscaler_prod
./01_install_cluster_autoscaler_prod.sh status     # its status ConfigMap
./01_install_cluster_autoscaler_prod.sh logs       # grep for "Scale-up:" / "Scale-down:"

kubectl get nodes -L workload,lifecycle
```

Three alerts cover the autoscaler's own failure modes —
`ClusterAutoscalerPodsStuckPending`, `ClusterAutoscalerUnableToScale`,
`ClusterAutoscalerFailedScaleUp`. See `HOW_TO_MONITOR_THE_PLATFORM.md`.

## What is not autoscaled, and why

| Component | Replicas | Why fixed |
|---|---|---|
| Trino coordinator | 1 | it holds query state; a second one is a different cluster, not more capacity |
| Polaris | 1 | stateless, but the catalog is not the bottleneck at this scale |
| Airflow scheduler | 1 | HA scheduling needs a second RDS-backed lock and buys nothing at a handful of DAG runs a day |
| Spark executors | fixed per job (`instances: 2`) | dynamic allocation is possible and deliberately not used — each job knows its own shape, and adding it would make a failed run harder to reason about |
| Prometheus / Grafana | 1 each | Prometheus owns a ReadWriteOnce volume; a second replica cannot mount it |

Spark **dynamic allocation** is the most defensible thing to add next: the
bronze task is driver-bound and barely uses its two executors, while silver
could use more. It needs an external shuffle service or shuffle tracking to be
safe on Spot, which is why it is not on by default.
