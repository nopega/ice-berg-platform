# app-of-apps

Every Helm release on this cluster, declared in git.

```bash
kubectl apply -f root.yaml
```

That is the only object applied by hand, ever. `root.yaml` watches this
directory, so from then on adding a component is adding a file and pushing.

## What syncs, and in what order

| Wave | Application | Namespace | Why here |
|---|---|---|---|
| -20 | `polaris` | data-platform | The Iceberg catalog. Everything that reads a table resolves through it |
| -10 | `monitoring` | monitoring | Installs the ServiceMonitor and PrometheusRule CRDs four charts below need |
| 0 | `aws-load-balancer-controller` | kube-system | Turns Ingress objects into an ALB |
| 0 | `cluster-autoscaler` | kube-system | Makes `ng-spot` at zero nodes a design rather than a comment |
| 10 | `trino` | data-platform | Query engine; needs Polaris and the ServiceMonitor CRD |
| 10 | `harbor` | harbor | Must serve images before any Spark driver starts |
| 20 | `airflow` | airflow | A DAG firing at start-up should find everything already up |
| 20 | `spark-operator` | spark-operator | Turns SparkApplication objects into driver pods |

Argo CD waits for a wave to report **Healthy**, not merely Synced, before
starting the next. The ordering is therefore guaranteed rather than raced.

It is the same order as the numbered folders, for the same reasons. Both paths
have to work: someone following the README by hand, and Argo CD.

## What Argo CD does not do

It reconciles Kubernetes objects against git. It cannot create an IAM role,
read AWS Secrets Manager, request an ACM certificate, or tag an Auto Scaling
group.

So every Application here names the scripts that must run first, at the top of
its file. That split is not a limitation being worked around — anything holding
a credential stays out of git by construction.

Two things are also deliberately left to scripts even though they are plain
Kubernetes objects:

- **The `spark` namespace, ServiceAccount and RBAC.** They grant the operator
  the right to create pods. That is a permission decision, and it should be
  reviewed as one rather than arriving as a side effect of a deployment.
- **Airflow's StatsD ServiceMonitor.** The chart ships none, so
  `02_install_airflow_prod.sh` applies `statsd-servicemonitor.yaml` after the
  release.

## Why nothing is on `automated` yet

Every one of these is currently a `helm install` release. Helm keeps its state
in a Secret; Argo CD applies rendered manifests and never talks to Helm. For
the length of the migration there are two owners of the same objects.

So the children have no `automated` block. Argo CD reports OutOfSync and waits.
Sync one, confirm it took ownership, then enable automation for that component:

```bash
kubectl apply -f root.yaml
kubectl get application -n argocd

argocd app sync monitoring
argocd app get monitoring          # Synced AND Healthy before moving on
```

Once a component is settled, add to its file:

```yaml
  syncPolicy:
    automated:
      selfHeal: true
```

`selfHeal` is what actually removes configuration drift: a `kubectl edit` is
reverted within about three minutes. It also means an urgent fix at 2am has to
go through git, which is the point rather than the cost.

**`prune` stays off on the children.** On the root it is on, and there it means
deleting a file removes the Application object — not that component's
resources. The blast radius of a mistake is a component nobody is managing,
rather than a component that is gone.

## Finishing the migration, per component

After Argo CD reports Synced and Healthy, the Helm release record is redundant
and misleading — `helm list` will still claim ownership of objects Argo CD now
manages.

```bash
kubectl get secret -n <namespace> -l owner=helm,name=<release>
```

Delete those only once the Application is healthy, and one component at a time.
Deleting them first is harmless to the running workload; deleting them while
Argo CD has not yet taken ownership leaves objects with no owner at all.
