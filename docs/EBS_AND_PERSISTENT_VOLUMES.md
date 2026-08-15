# Block storage — EBS volumes and persistent volumes

Every block device this platform owns, what is on it, and what happens if it
is lost. `S3_DATA_TIER.md` is the companion for object storage; the split
matters because **the two fail completely differently** — S3 is eleven nines
across a region, an EBS volume lives in exactly one Availability Zone and can
attach to exactly one node.

The design rule underneath everything below: **block storage holds nothing that
cannot be either recomputed or restored from somewhere else.** The one
exception is the catalog database, and that is why it is not on EBS at all —
it is on RDS, which takes backups.

## The whole inventory

| # | Volume | Size | Type | Holds | Lost if deleted |
|---|---|---|---|---|---|
| 1 | `ng-ondemand` node root × 5 | 50Gi each | gp3 | OS, container images, ephemeral pod storage | nothing — nodes are cattle |
| 2 | `ng-spot` node root × 0–4 | 100Gi each | gp3 | same, plus Spark shuffle | nothing, by design |
| 3 | Prometheus TSDB | 20Gi | gp3 PVC | 7 days of metrics | 7 days of history |
| 4 | Grafana | 5Gi | gp3 PVC | dashboards created in the UI | those dashboards |
| 5 | Harbor database | 20Gi | gp3 PVC | projects, users, robots, tag metadata, **Trivy scan results** | the registry's memory of itself |
| 6 | Harbor Trivy | 10Gi | gp3 PVC | the vulnerability database | nothing — re-downloaded (~2 GB) |
| 7 | Harbor Redis | 5Gi | gp3 PVC | job queue and cache | in-flight jobs |
| 8 | Harbor jobservice | 5Gi | gp3 PVC | replication and GC job logs | log history only |
| 9 | Harbor registry | 1Gi | gp3 PVC | **nothing** — see below | nothing |
| 10 | RDS | 20Gi | gp3, managed | `iceberg_catalog` + `airflow` | **everything.** Not EBS; see below |

**316 GiB of EBS at rest** (rows 1–9; RDS is billed separately), of which
250 GiB is node root volumes that exist only while the nodes do. With `ng-spot`
at zero, the Spot group contributes nothing.

### #9 is a volume that exists to be ignored

Harbor's chart renders a registry PVC unconditionally. Image layers go to
`s3://data-store-prod-registry` via `imageChartStorage.type: s3`, so nothing is
ever written to it. It is sized down to the 1Gi minimum rather than left at the
chart's 5Gi default — a volume nobody can delete is at least a volume nobody
pays much for.

### #10 is deliberately not EBS

The Polaris catalog database is the one piece of state in this platform that
**cannot be recomputed**. Lose it and every Parquet file survives in S3 while
nothing knows which `metadata.json` is current for each table — a warehouse
full of orphaned bytes.

That is exactly the state that should not live on a single-AZ volume with no
backup story. It is on RDS with automated backups and point-in-time recovery
(`--backup-retention-period 1`), for ~\$15/month.

Polaris ships with `persistence.type: in-memory` as its default. Leaving it
there would have put the same critical state in a pod's memory, and the failure
would have been a pod restart.

## The StorageClass, and the four decisions in it

`set_up_cluster/05_storageclass_prod/gp3-storageclass.yaml`

**EKS installs the EBS CSI driver addon but creates no StorageClass for it.**
The consequence is not an error: a PVC is accepted, stays `Pending` forever,
and the pod reports `0/3 nodes are available: pod has unbound immediate
PersistentVolumeClaims` — which reads like a scheduling problem.

| Setting | Value | Why |
|---|---|---|
| `type` | **gp3** | ~20% cheaper per GB than gp2, and its 3000 IOPS / 125 MB/s baseline is included and independent of size. gp2 ties IOPS to size at 3 IOPS/GB, so matching gp3's baseline would mean provisioning 1 TB nobody needs |
| `volumeBindingMode` | **WaitForFirstConsumer** | an EBS volume exists in one AZ. With `Immediate` the volume is created before the scheduler picks a node, so the AZ is chosen blind — and a pod scheduled elsewhere can never attach it |
| `allowVolumeExpansion` | **true** | set now because it **cannot be enabled retroactively** on volumes already bound under a class that lacked it |
| `reclaimPolicy` | **Delete** | `Retain` leaves orphaned volumes billing after a namespace is deleted. Everything here is reproducible or backed up elsewhere |
| default class | **yes** | Harbor's subcharts all omit `storageClassName`; without a default, every one would need patching individually |

## ReadWriteOnce is the constraint that shapes deployments

An EBS volume attaches to **one node at a time**. Two consequences that both
produced real outages here:

**Grafana was stuck `Init:0/1` for 154 minutes.** A RollingUpdate creates the
new pod before terminating the old one, the old pod still holds the volume, and
the new one waits forever. The fix is one line, and it is not obvious from any
error message:

```yaml
deploymentStrategy:
  type: Recreate
```

Patching a live Deployment also fails unless `rollingUpdate` is explicitly
nulled — `spec.strategy.rollingUpdate: Forbidden when type is 'Recreate'`:

```bash
kubectl patch deploy kube-prometheus-stack-grafana -n monitoring \
  -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
```

**Nothing holding a PVC can have two replicas.** Prometheus and Grafana run one
each, and that is a property of the storage rather than a capacity decision.
It is also why they are pinned to `workload=critical`: a Spot reclamation would
move the pod, and the volume cannot follow it to another AZ.

## What is deliberately ephemeral

Turning persistence *off* is a decision as much as turning it on, so each is
recorded with what it costs.

| Component | Storage | Why not a volume |
|---|---|---|
| **Airflow logs** | `emptyDir` | remote logging to `s3://data-store-prod-logs/airflow`. Task pods are created and destroyed per task — a PVC would have to be ReadWriteMany, which EBS cannot do |
| **Airflow DAGs** | `emptyDir` | git-sync clones into the pod. Git is the source of truth, not a volume someone copied files into |
| **Airflow Celery workers** | *none* | the chart's deprecated `workers.persistence` block still reads `enabled: true, size: 100Gi`. **It renders nothing**, because `executor: KubernetesExecutor` creates no worker StatefulSet. A 100Gi line that provisions nothing is worth knowing about before someone "fixes" it |
| **Airflow Redis** | *none* | Redis exists only as a Celery broker. KubernetesExecutor has no broker |
| **Alertmanager** | `emptyDir` (`storage: {}`) | silences and notification state are lost on restart. Acceptable while no receiver is configured; **revisit when one is**, because a re-fired alert storm after a restart is exactly what silences exist to prevent |
| **Trino** | node root only | see below |
| **Argo CD Redis** | `persistentVolume.enabled: false` | a cache in front of git. Losing it costs one re-sync |
| **Spark drivers/executors** | node root only | shuffle data is regenerated on retry; the event log goes to S3 |
| **Polaris** | *none* | `relational-jdbc` → RDS |

### Trino has no volume, and that is a live risk worth naming

Trino runs with `spill-enabled` unset, which is Trino's default of **false**.
A query that exceeds its per-node memory limit therefore **fails rather than
spills**:

```
exceeded per-node memory limit
```

The resource-group comments size concurrency so this should not happen — six
concurrent queries at ~700 MB each against a ~4.2 G pool. But those numbers are
arithmetic, not measurement.

If spilling is ever enabled, it needs a volume chosen on purpose. The default
spill path is inside the container, which means the **node's 50Gi root volume**
— shared with every container image on that node. A large spill would fill it,
and the symptom is not a slow query: it is `DiskPressure`, kubelet evicting
pods, and an outage in workloads that had nothing to do with the query.

## Backup posture, stated honestly

| Volume | Backup | If it is lost |
|---|---|---|
| RDS (#10) | automated, 1-day retention + PITR | restore |
| Everything on EBS (#3–#9) | **none** | rebuild |

**There are no EBS snapshots.** No snapshot schedule, no Velero, nothing. The
justification is that each volume's contents are reproducible:

- Prometheus — 7 days of metrics, and the platform is not billed on them
- Grafana — dashboards *should* be provisioned as code; any created in the UI
  are genuinely at risk, and that is the weakest item in this table
- Harbor DB — projects and robots are re-creatable; **scan results are not**,
  though they regenerate on the next scan
- Trivy DB, Redis, jobservice — caches and logs

`harbor.persistence.resourcePolicy: "keep"` means `helm uninstall` leaves the
PVCs behind. An accidental uninstall costs a reinstall, not every project
definition Harbor has accumulated.

**The honest next step** is either provisioning Grafana dashboards as code, or
a scheduled EBS snapshot via AWS Backup on the two volumes that hold anything
irreplaceable (#4, #5). Both are cheap; neither is done.

## Cost

At ap-southeast-1 gp3 pricing (~\$0.096/GB-month), block storage is a small
line — roughly **\$30/month** for 316 GiB, of which about \$24 is the five node
root volumes.

Two things keep it there rather than growing:

- **`ng-spot` at zero nodes means zero Spot root volumes**, not four idle
  100Gi ones. The volume is created with the node and destroyed with it.
- **Prometheus is capped twice** — `retention: 7d` *and* `retentionSize:
  18GiB` on a 20Gi volume. Time alone is a promise the disk cannot keep if the
  ingest rate rises, and the failure mode of an unbounded TSDB is a full volume
  rather than a slow query.

The largest storage decision in this platform is not on this page: image layers
and the warehouse both go to **S3 rather than EBS**, which is what makes
"terabyte scale" a pricing question instead of a provisioning one.
`S3_DATA_TIER.md`

## Checking the live state

```bash
# every PVC and what bound it
kubectl get pvc -A

# anything stuck — the number that should always be zero
kubectl get pvc -A | awk 'NR==1 || $3!="Bound"'

# the real EBS volumes behind them, with their AZ
aws ec2 describe-volumes --region ap-southeast-1 \
  --query 'Volumes[].{ID:VolumeId,GiB:Size,Type:VolumeType,AZ:AvailabilityZone,State:State}' \
  --output table

# volumes attached to nothing — the bill nobody notices
aws ec2 describe-volumes --region ap-southeast-1 \
  --filters Name=status,Values=available --output table

# the StorageClass and the CSI driver behind it
./script/set_up_cluster/05_storageclass_prod/05_create_storageclass_prod.sh verify
```

The `verify` mode checks the two things that fail silently: the CSI controller
running (its addon label is `app=ebs-csi-controller`, **not** the upstream
chart's `app.kubernetes.io/name=aws-ebs-csi-driver` — matching on the wrong one
reports a healthy driver as missing), and any PVC not `Bound`.

`test` mode provisions a 1Gi volume and deletes it, which proves the whole
chain: StorageClass → CSI controller → IAM permission to call
`ec2:CreateVolume` → attachment to a node. Each link fails differently and only
the last is visible from `kubectl get sc`.
