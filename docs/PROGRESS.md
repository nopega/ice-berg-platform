# Progress / hand-off notes

Read this first when picking the work back up — it says what's built, what's
running, and exactly what to do next. Detailed reasoning for each component
lives in its own README; this file is the map, not the territory.

Last updated: 2026-08-15

---

## 1. What's actually deployed right now on the live cluster

Everything in this section has been run against the real AWS account, not
just written.

| | |
|---|---|
| **EKS** | `data-platform-prod`, Kubernetes 1.34, ap-southeast-1 |
| `ng-ondemand` | m5.large — **min 5 / desired 5 / max 7**, `workload=critical` |
| `ng-spot` | **min 0 / desired 0 / max 4**, `workload=batch` + taint `spot=true:NoSchedule` |
| **RDS** | Postgres 17, `db.t4g.micro` — databases `iceberg_catalog`, `airflow` |
| **S3** | `data-store-prod-warehouse`, `-logs`, `-registry`, all with lifecycle rules |
| **Polaris** | 1.5.0, catalog `data_platform`, 3-level namespaces `medallion.category.domain` |
| **Trino** | 480 — 2 workers, HPA 2–5, PASSWORD auth, **file access control rules**, resource groups, JMX exporter sidecar + ServiceMonitor |
| **Airflow** | 3.2.2, KubernetesExecutor, DAGs by git-sync from `nopega/airflow_dag`, SMTP failure alerts to Gmail via the `smtp_default` connection |
| **Harbor** | 2.15.1 — layers in `s3://data-store-prod-registry`, project `ice-berg-platform` |
| **Spark** | Operator 2.5.0, namespace `spark`, IRSA, RBAC; image `datapipeline:v1.0.2` |
| **Cluster Autoscaler** | 1.34.2 — `ng-spot` proven to go 0 → N → 0 on demand |
| **metrics-server** | EKS managed addon (step 10), so the HPAs actually scale |
| **Monitoring** | kube-prometheus-stack 88.3.0 — Prometheus 3.13.2, Grafana 13.1.3, Alertmanager 0.33.1. **31 targets, zero DOWN.** Two CloudWatch datasources (ap-southeast-1 + us-east-1 for Billing) |
| **Argo CD** | v3.5.0 — app-of-apps, one root Application reconciling 8 Helm releases in sync waves |
| **Public access** | one shared ALB, **6 hostnames**, HTTPS only, source-IP allowlist, one ACM certificate |

### The pipeline runs green, end to end

`nyc_taxi_medallion` — bronze → silver → gold, one day of NYC TLC trips per
run, landing as three Iceberg tables. It took five distinct code bugs to get
there; each is recorded in §6 so the next pipeline is cheaper.

The delivery chain it proves: git push → git-sync → DAG processor → scheduler →
task pod → `SparkApplication` → Spark Operator → driver on On-Demand →
executors on Spot from zero → Polaris credential vending → Iceberg write → read
back through Trino.

## 2. Immediate next actions (pick up here)

**1. Push the restructured `script/` tree to `nopega/ice-berg-platform`.**
Argo CD's root Application points at `set_up_component/07_argocd_prod/applications/`
and will not find it until the push lands. Everything else in this section is
smaller than this one.

**2. Rotate the `team_b_powerbi` Trino password.** It was pasted into a chat
transcript during setup and must not survive into the submission.

```bash
cd script/set_up_component/02_trino_prod

# ONLY this one secret. Do not touch the internal shared secret: rotating it
# while the cluster is running makes the workers fail to authenticate to the
# coordinator, and the error does not say so.
aws secretsmanager delete-secret --region ap-southeast-1 \
  --secret-id data-platform-prod-trino-powerbi-password \
  --force-delete-without-recovery

./02_create_trino_auth_secrets_prod.sh   # regenerates, re-stores, rewrites password.db
./03_install_trino_prod.sh               # coordinator remounts the new file
./02_create_trino_auth_secrets_prod.sh show-powerbi   # on the BI machine only
```

**3. Finish disabling EKS control-plane logging on the LIVE cluster.**
`eks-cluster.yaml` now sets `enableTypes: []`, but that file only affects
cluster *creation*. The running cluster still has `audit` + `authenticator` on
and 645 GB accumulated:

```bash
aws eks update-cluster-config --name data-platform-prod --region ap-southeast-1 \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":false}]}'
aws logs delete-log-group --region ap-southeast-1 \
  --log-group-name /aws/eks/data-platform-prod/cluster
```

**4. Give Alertmanager a receiver.** It is installed and evaluating rules;
nothing is configured to receive them, so alerts fire into a UI nobody has
open. This is a decision about who is on call, not a technical step.

## 3. Built but not deployed

- **Spark History Server** — `06_spark_prod/history-server.yaml` and
  `07_deploy_history_server_prod.sh` are written and unrun. `spark.nopega.net`
  is on **neither the certificate nor the ALB**: the ACM request covers six
  names (`trino` + 5 SANs) and there is no host rule, because a DNS record
  aimed at an ALB with no matching rule returns 404 from the default action —
  which reads like a broken deployment rather than an absent one. Publishing it
  means a **new** certificate; ACM cannot add a name to an issued one.
- **GitHub Actions self-hosted runners** — roadmap, not built. The Spark image
  is built and pushed by hand with `06_spark_prod/03_build_and_push_image_prod.sh`.
  Argo CD already closes the deploy half of the loop.

## 4. Known gaps and deliberate trade-offs

Ordered by how much they matter.

- **No NetworkPolicy anywhere.** Pod-to-pod traffic is flat, so a compromised
  Airflow task pod can reach Polaris or Trino directly, bypassing the ALB and
  its allowlist. The largest single gap in the platform. `NETWORK-PLANE.md`

- **No query audit log.** `eventListenerProperties: []` — nothing records who
  ran which query against which table. The `bronze.log.query_audit` namespace
  was created for exactly this and is empty.

- **The EKS API audit trail was turned off.** It existed, reached 645 GB in
  CloudWatch unread, and cost more per month than the ALB. Turning it back on
  is a decision to pay for something someone will actually read — which means a
  destination that is not "CloudWatch, forever". `SECURITY_GOVERNANCE.md`

- **Harbor's image scanning does not block.** The first scan of the Spark image
  found 4694 vulnerabilities because `apache/spark:4.0.1` is Ubuntu 22.04 + JDK
  21 + several hundred JARs. With blocking set to High, every pull returned
  `412 Precondition Failed` — the policy blocked everything rather than
  blocking risky things. Scanning on, blocking off, `apt-get upgrade` in the
  Dockerfile. The real answer is a hardened base image.

- **Harbor authenticates to S3 with an IAM access key, not IRSA.** Not a
  choice — Harbor 2.15.1 bundles distribution 2.8.x, whose S3 driver hardcodes
  a credential chain with no web-identity provider in it. The projected token
  is ignored. Key scoped to one bucket, stored in Secrets Manager. Revisit when
  Harbor ships distribution 3.x.

- **`data-platform-prod-polaris-storage-role` looks over-broad and should stay
  that way.** Polaris mints a narrow session policy per request from this role;
  tightening the role itself makes vending fail for individual tables with
  errors that do not explain why.

- **Spark's own warehouse grants are now redundant**, because table data access
  runs on Polaris-vended credentials and Spark's IRSA covers only the event
  log. Narrowing them is deferred: a job that stages raw files in S3 and reads
  them with `s3a://` would be outside the catalog path and would need direct
  access.

- **cloudflared is still installed.** Superseded by the ALB, kept only because
  the tunnel also fronts `ssh.nopega.net`, which is not part of this platform.

- **`RESTMetricsReporter: 404 NoSuchTableException` in Spark logs is noise.**
  Iceberg reports scan metrics back to the catalog; Polaris does not implement
  that endpoint. Full stack trace, mid-job, nothing wrong.

- **A new hostname will look unreachable from a laptop for a while.** `dig
  +short <host> @1.1.1.1` returns the ALB IPs while `curl` says "Could not
  resolve host", because a resolver cached NXDOMAIN from a lookup made before
  the record existed (SOA minimum, 1800s). Prove it with `curl --resolve` and
  wait the cache out. **Do not curl a hostname before creating its DNS record.**

## 5. Documentation status

| Deliverable / bonus | Document |
|---|---|
| D1 — architecture, reasons, cost | `ARCHITECTURE.md` + `diagrams/system_architecture.svg`, `COST.md` |
| D2 — how to set up and deploy | `HOW_TO_SET_UP_AND_DEPLOY.md` — one ordered read-through; per-folder READMEs carry the detail |
| D3 — how to perform ETL | `HOW_TO_PERFORM_ETL.md` |
| D4 — how users connect and query | `HOW_USERS_CONNECT_AND_QUERY.md` → `powerbi/README.md`, `CONNECT_DBEAVER.md` |
| B1 — Kubernetes | the whole `script/` tree |
| B2 — monitoring | `HOW_TO_MONITOR_THE_PLATFORM.md` |
| B3 — security & governance | `SECURITY_GOVERNANCE.md`, `IDENTITY_AND_SECRETS.md` |
| B4 — improvement ideas | `AUTOSCALING.md`, `S3_DATA_TIER.md`, `EBS_AND_PERSISTENT_VOLUMES.md`, `DATA_MODEL.md`, and the roadmap rows above |

Every deliverable and bonus now has a document whose name says which question
it answers.

## 6. Lessons this build actually paid for

Each cost a debugging cycle. They are here so the next one is cheaper.

**Turning something on has consequences it does not mention.**

- **EKS does not ship metrics-server**, and nothing says so. Trino's HPA
  existed for three days and never scaled once — `<unknown>/50%`, and
  `FailedGetResourceMetric` logged 5,918 times in 24 hours into events nobody
  reads. It stayed invisible because **a Deployment parked at its minimum
  replicas looks exactly like a Deployment with no reason to scale.**
- **HPA utilisation is a percentage of the *request*.** One container in the
  pod without one makes the figure undefined for the whole pod. Enabling the
  Trino JMX metrics sidecar silently switched off the autoscaling that sidecar
  existed to help observe.
- Neither produced an error at apply time.

**A file nobody re-applies is documentation, not configuration.**
`00_create_polaris_storage_role_prod.sh` created its IAM policy once and then
printed "already exists, reusing" forever, so edits to the policy JSON never
reached AWS. `scale_up.sh` never sent `--nodes-max`, so `eks-cluster.yaml` said
5 while the live group was 3. Both now write on every run.

**Labels attract, taints repel, and they are configured separately.** The smoke
test's executors carried a toleration for `workload=batch` — a node *label*.
The taint is `spot=true`. A toleration naming the wrong key is rejected by
nothing; the pod just stays Pending.

**`pc.scalar` is not `pa.scalar`.** `pyarrow.compute.scalar` builds an
Expression for the dataset filter DSL, which compute kernels reject outright.
Cost a full DAG run to find.

**`F.col()` at module import time has no SparkContext.** A module-level list of
rules using `F.col` raises a bare `AssertionError` with no message. Move it
into a function.

**PySpark 4.0 takes a `pyarrow.Table` directly** — no pandas needed, and no
Arrow → pandas → Arrow double copy at the peak. That is why the image does not
carry pandas.

**Spark's multipart identifiers already express nesting.** Writing
``catalog.`bronze.log.query_audit`.table`` asks for a single namespace whose
name contains dots. Drop the backticks.

**Two S3 clients, two access patterns.** Iceberg uses S3FileIO and addresses
objects directly; the Spark event log uses S3A, which emulates directories and
calls HeadObject on the bare key before listing. A policy covering only
`spark-events/*` produces a 403, and S3A treats 403 as fatal. The directory
also has to *exist* as a zero-byte object ending in `/`.

**ACM certificates are immutable.** There is no API to add a subject
alternative name — only a full re-request and re-validation. That list was
extended three times (grafana, argocd, prometheus), each costing a new
certificate. `verify` prints what the live certificate actually carries; trust
that, not a list in a script.

**Cloudflare's zone-file import silently drops new rows.** A file containing
rows Cloudflare considers duplicates reports errors for those and quietly skips
the ones that were new. It failed this way three times before being replaced
with per-record API calls.

**Helm never upgrades CRDs.** `kube-prometheus-stack` ships them in a subchart
that only applies on first install.

**Some charts run alert rules through `tpl`.** A `{{ $value }}` in a
hand-written annotation is evaluated by Helm, not by Prometheus, and fails with
`undefined variable "$value"`. A `null` interval is also not the same as an
omitted one.

**`COPY` preserves the build machine's file mode.** A source file left at 0600
by an editor becomes unreadable to the unprivileged container user.
`RUN chmod -R a+rX` after the COPY makes the image independent of whose laptop
built it.

**`aws --output text` is TAB-separated.** Any shell membership test written for
spaces silently returns the wrong answer. This has bitten twice.

## 7. Folder layout

```
script/
  set_up_cluster/            infrastructure — run first, in order
    00_aws_cli_setup/
    01_s3_bucket_setup/
    02_eks_cluster_prod/
    03_irsa_role_prod/
    04_rds_prod/
    05_storageclass_prod/
    06_monitoring_prod/        <- must precede anything shipping a ServiceMonitor
    07_vpc_endpoints_prod/
    08_load_balancer_controller_prod/
    09_cluster_autoscaler_prod/
    10_metrics_server_prod/

  set_up_component/          the platform itself
    01_iceberg_catalog_and_polaris_prod/
    02_trino_prod/
    03_cloudflared_prod/       <- superseded by the ALB, kept for ssh.nopega.net
    04_airflow_prod/
    05_harbor_prod/
    06_spark_prod/
    07_argocd_prod/            <- app-of-apps: root.yaml + 8 Applications

  set_up_public_access/      run AFTER the components exist
  scale/                     scale_down.sh / scale_up.sh
```

**Monitoring sits at 06 because that is its real dependency order**, not a
preference: the Prometheus Operator installs the ServiceMonitor and
PrometheusRule CRDs, and a chart cannot create objects of a kind that does not
exist yet. The load balancer controller (08) and the cluster autoscaler (09)
both ship ServiceMonitor templates. Its only hard predecessor is 05, the
StorageClass — Prometheus and Grafana need a PVC that can bind. Its Ingress is
created before the load balancer controller exists and simply sits
unreconciled until 08 arrives, which is ordinary declarative behaviour.

**`set_up_public_access/` is separate rather than numbered** because it must
run *after* the components: an Ingress needs a Service to point at, and the ACM
certificate has to cover every hostname before any of them resolve.

## 8. Standing conventions to keep following

- **Chart-decides-the-version**: use whatever `appVersion` the vendored Helm
  chart declares and record it in `STACK_SUMMARY.md`. Don't pin to a
  pre-written number or chase the newest release.
- **Vendor charts into `chart/<name>/`** next to the install script and commit
  them. Configure by editing the vendored `values.yaml` **in place**, marking
  every deviation with a `CHANGED (data-platform)` comment saying why —
  `grep -n "data-platform)" chart/*/values.yaml` then lists every decision.
  No separate overrides file.
- **`workload=critical` = on-demand, `workload=batch` = spot.** Anything whose
  failure is user-visible or hard to retry safely goes on critical, including
  Spark *drivers*: losing an executor costs the partitions it held, losing the
  driver costs the whole job. Only Spark executors are on spot.
- Every install script supports at least `deploy` (default), `verify`, and
  where relevant `uninstall`/`delete`.
- **`verify` checks the thing most likely to be *quietly* wrong**, not the
  thing that is easiest to check. A pod being Running proves very little.
- AWS Secrets Manager is the source of truth for every generated credential;
  Kubernetes `Secret` objects are a mirror written by scripts, never edited by
  hand. Use the `store_sm_secret` / `get_or_create_sm_secret` pattern in
  `05_harbor_prod/01_create_harbor_secrets_prod.sh`, including the "secret
  marked for deletion" recovery path.
- Scripts numbered in execution order. If a step is inserted, renumber and fix
  the cross-references rather than leaving the order implicit.
- **Secrets are never pasted into chat, a manifest, or a command-line
  argument.** Values arrive via hidden `read -rs` prompts and leave via
  `kubectl apply -f -` from stdin.
