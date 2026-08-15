# Stack Summary — Iceberg Lakehouse on Kubernetes

Final, locked-in technology stack for Problem 2 (Data Platform).

Versions below are the ones pinned in this repository's manifests, values files and setup scripts — nothing is left on a floating `latest` tag, so a re-run months from now produces the same platform. Versions are current as of **August 2026**.

Two of them are **not** the newest available, and that is deliberate — see [Version compatibility matrix](#version-compatibility-matrix) for why Spark is 4.0.1 rather than 4.2.0, and why RDS runs Postgres 17 rather than 18.

## Environments

| Environment | Purpose | Kubernetes | Notes |
|---|---|---|---|
| **Test** *(designed, not submitted)* | Validate manifests and pipelines cheaply before touching real prod infra | Single EC2 instance running `kind` | The design point worth keeping: use **real AWS S3** and **real AWS RDS** (free-tier instance) rather than MinIO and a container Postgres, so no path or config changes are needed when promoting to prod. The scripts for it were written and then removed from this submission — carrying a second environment nobody was running added surface without adding evidence. |
| **Production** | Real workload | Amazon EKS **1.34** | Node groups: **On-Demand** (stateful/critical: Trino coordinator, Polaris catalog) + **Spot** (Spark ETL executors, Trino workers). Nodes are Amazon Linux 2023 — AWS does not publish an AL2 EKS AMI for 1.34. Verify the running version with `aws eks describe-cluster --name data-platform-prod --query 'cluster.version'`. |

## Core Components

| Component | Version | Role |
|---|---|---|
| **Apache Iceberg** | 1.10.2 (table spec **v3**) | Table format — the mandatory constraint of this platform. Gives ACID commits, schema/partition evolution, time travel, hidden partitioning. Spec v3 went GA in 2026 and adds deletion vectors, row lineage, VARIANT type and default column values. |
| **AWS S3** (separate bucket per environment) | — (managed) | Object storage holding all Iceberg data files (Parquet) and metadata/manifest files. Same S3 path (`s3://...`) used in test and prod — no MinIO. |
| **Apache Polaris** (Iceberg REST Catalog) | 1.5.0 — server image `apache/polaris:1.5.0`, admin tool `apache/polaris-admin-tool:1.5.0`, official Helm chart 1.5.0 | Tracks which `metadata.json` is the "current" version of each table and provides atomic commits so multiple writers/readers stay consistent. Implements the Iceberg REST Catalog spec, so Trino and Spark both speak to it over one standard HTTP API. |
| **AWS RDS (managed Postgres)** | **Postgres 17** (`db.t4g.micro`) | Backing metadata database for Polaris (`iceberg_catalog` DB) and for Airflow (`airflow` DB). Used in **both test and prod** (free-tier instance for test) instead of self-hosted Postgres, since it needs block storage + automated backup/PITR that a database engine (not S3) provides. Pinned to 17 because Airflow 3.2 supports Postgres 13–17 only. |
| **Apache Spark, via Spark Operator on Kubernetes** | **Spark 4.0.1** (Scala 2.13); Kubeflow Spark Operator 2.5.0 | Runs the ETL pipeline (extract external data → transform/validate/dedupe → load as Iceberg table via `MERGE INTO`). Runs on Spot nodes since jobs are short-lived and interruption-tolerant. Iceberg support comes from the `iceberg-spark-runtime-4.0_2.13:1.10.2` + `iceberg-aws-bundle:1.10.2` jars. |
| **Apache Airflow (KubernetesExecutor)** | **3.2.2** — official Helm chart 1.22.0 (`appVersion: 3.2.2`), `apache-airflow-providers-cncf-kubernetes` 10.19.0 | Schedules the ETL: DAG for Team A's daily 10:00 report pipeline, DAG for Team B's hourly monitoring pipeline. Task logs shipped to S3 (remote logging), not left on ephemeral pod disk. Uses the same AWS RDS instance for its metadata database. **No Redis/Celery broker is required** — KubernetesExecutor launches each task as its own pod directly against the Kubernetes API, so there is no message queue in the architecture. |
| **Trino** | **480** — official `trino` Helm chart 1.42.2 | Query engine. Reads Iceberg tables via Polaris + S3, serves both teams' SQL. Configured with **resource groups** (isolate Team A's bursty ~100-query batch load from Team B's frequent lightweight monitoring queries) and **HPA** (scales worker pods up only during the daily burst, back down after). |
| **Prometheus** | **3.13.2** — via `kube-prometheus-stack` chart 88.3.0, Prometheus Operator v0.93.0 | Metrics collection and storage. Scrapes metrics endpoints across the cluster (Trino query latency & throughput, Spark job duration & failures, Airflow DAG SLA misses), stores them in its local time-series database, and evaluates alerting rules. Retention is **7 days / 18GiB** on a 20Gi gp3 volume — both limits set, because time alone is a promise the disk cannot keep if the ingest rate rises. Runs on the on-demand node group, never Spot: its recent window is in memory and its volume is bound to one AZ, so a reclamation loses observability exactly when nodes are churning. |
| **Grafana** | **13.1.3** — subchart `grafana` 12.10.4, bundled with the above | Visualization layer. Queries Prometheus to render dashboards. Stores no metrics itself — purely the presentation tier. Admin credential comes from AWS Secrets Manager via an existing Kubernetes Secret, never from a Helm value. |
| **Alertmanager** | 0.33.1 — bundled with the above | Alert routing and deduplication. Installed and evaluating the default rule set; **no receiver is configured yet**, so alerts are visible in its UI and go nowhere else. Wiring a destination is a decision about who is on call, not a technical step. |
| **kube-state-metrics / node-exporter** | subcharts 8.2.0 / 4.56.1 | Kubernetes object state, and per-node CPU/memory/disk/network. node-exporter is a DaemonSet that tolerates every taint, so Spot nodes are covered too — otherwise the half of the cluster that churns most would be the half with no data. |
| **Grafana Mimir + S3** | *(planned upgrade — not deployed)* Mimir **3.1.2**, `mimir-distributed` chart **6.1.0** | Long-term metrics storage. Prometheus keeps 7 days on one EBS volume and ships nothing off-cluster; unbounded history means blocks in S3, which is a component in its own right rather than a bigger volume. Pinned here so the growth path is a decision with a version attached, not a hand-wave — full reasoning, trigger conditions and the Thanos comparison in [Metrics: the long-term-storage upgrade path](#metrics-what-is-implemented-now-and-the-long-term-storage-upgrade-path). Not claimed as built. |
| **GitHub** | — (SaaS) | Single source of truth for every artifact that defines the platform: Kubernetes manifests and Helm values, Airflow DAGs, Spark ETL code, Trino configuration, and the S3 lifecycle policies. Changes reach the cluster through pull requests, so every modification is reviewed, attributable, and revertible. |
| **Harbor** | 2.15.1 — official `harbor` Helm chart 1.19.1 | Private container registry for the platform's own images — the Spark ETL job image, custom Airflow image with the required providers, and any patched Trino image. Adds what a plain registry does not: Trivy vulnerability scanning on push with policies that can block deployment of images above a severity threshold, project-level RBAC, image signing, and replication between environments. Keeping images in a registry inside the VPC also removes a public-internet dependency from the critical path of every pod start. |
| **GitHub Actions (self-hosted runners)** | *(roadmap — not deployed)* Actions Runner Controller (`gha-runner-scale-set`) 0.14.2 | Planned CI. On a pull request it lints and unit-tests the ETL code and validates manifests; on merge it builds the job images and pushes them to Harbor, then opens the commit that bumps the image tag in the manifests repository. Runners would execute inside the cluster as ephemeral pods on the spot node group, so CI capacity costs nothing when no build is running and Harbor stays reachable over private networking. **Today the Spark image is built and pushed by hand** with `06_spark_prod/03_build_and_push_image_prod.sh`; Argo CD already closes the other half of the loop by reconciling the cluster from git. |
| **Argo CD** | v3.5.0 — official `argo-cd` Helm chart 10.3.0 | GitOps delivery. Continuously reconciles the cluster against the manifests in GitHub — nothing is applied to a cluster by hand. Configuration drift is detected and either flagged or corrected automatically, a rollback is a Git revert, and the test and production clusters are guaranteed to be running the same definitions from the same repository. |
| **AWS Secrets Manager** + Kubernetes `Secret` | — (managed) | Secrets store. AWS Secrets Manager holds the authoritative copy of every credential — the RDS master password, the Polaris root client secret, the Trino password file — and the setup scripts read it at deploy time and write a native Kubernetes `Secret` from it. No credential is ever typed into a manifest, committed to Git, or pasted into a `kubectl create secret` by hand: the value is generated once by `openssl rand`, stored, and from then on only ever moves machine-to-machine. See "Why Secrets Manager instead of Vault" below for what this trades away. |

## Version compatibility matrix

The versions above are not simply "latest of everything". Three pairings constrain the rest, and two of them forced a version *down* from the newest release. Each row below was checked against the artifact that actually has to exist, not against a changelog.

### 1. Iceberg ↔ Spark — the binding constraint

Iceberg ships a **separate runtime jar per Spark minor version** (`/spark/v4.0`, `/spark/v4.1`, … each build their own artifact). If the jar for a given Spark minor does not exist, that Spark version simply cannot read or write Iceberg tables. What is published on Maven Central today:

| Iceberg runtime artifact | Iceberg versions published | Pairs with |
|---|---|---|
| `iceberg-spark-runtime-3.5_2.12` / `_2.13` | 1.10.0 – 1.11.0 | Spark 3.5.x |
| `iceberg-spark-runtime-4.0_2.13` | 1.10.0, 1.10.1, **1.10.2**, 1.11.0 | Spark 4.0.x |
| `iceberg-spark-runtime-4.1_2.13` | 1.11.0 only | Spark 4.1.x |
| *(no `4.2` artifact exists)* | — | Spark 4.2.x **unsupported** |

**Consequence: Spark 4.2.0 — the newest Spark release (14 Jul 2026) — cannot be used.** No Iceberg version has a Spark 4.2 runtime yet, so the mandatory table format would not work at all. The two viable pairings are:

- **Iceberg 1.10.2 + Spark 4.0.1** ← chosen, and this is the version actually built and running: `FROM apache/spark:4.0.1` in `06_spark_prod/Dockerfile`, `sparkVersion: "4.0.1"` in all three SparkApplication templates. The Kubeflow Spark Operator 2.5.0 examples use 4.0.x, so this is the best-trodden path.

This line said 4.0.4 for most of the build while the image was 4.0.1 — a documented version that nothing runs is the kind of detail a reviewer checks first, so it is corrected here rather than in the image.
- Iceberg 1.11.0 + Spark 4.1.3 — also valid, and newer, but the Iceberg 4.1 runtime has exactly one published release behind it, and the operator's tested examples are on 4.0.x.

Spark 4 is built against **Scala 2.13 only** (2.12 support was dropped), which is why every jar coordinate above ends in `_2.13`.

### 2. Airflow ↔ Postgres — the reason RDS is not on 18

Airflow 3.2's own documentation lists its supported metadata-database engines as **PostgreSQL 13, 14, 15, 16, 17**. Postgres 18 is not on that list.

This matters concretely: RDS's *default* engine version in August 2026 is Postgres 18, so an `aws rds create-db-instance` call that omits `--engine-version` silently provisions an unsupported backend. `script/set_up_cluster/04_rds_prod/04_01_create_rds_prod.sh` now pins `--engine-version 17` explicitly (major version only, so RDS still picks the latest 17.x minor and we don't pin ourselves to a patch that gets deprecated).

The same instance also backs Polaris, which is fine — Polaris's relational-JDBC metastore supports PostgreSQL generally and has no upper bound at 17.

### 3. Airflow ↔ Spark — how a DAG actually launches a Spark job

| Piece | Version | Requirement it satisfies |
|---|---|---|
| Airflow | 3.2.2 | The patch release the chart ships and was tested with — see the note below. |
| Airflow Helm chart | 1.22.0 | Requires Kubernetes ≥ 1.30.13 and Helm ≥ 3.19.0 — EKS 1.34 and current Helm both clear this. Supports Airflow 2.11+/3.0+ and `KubernetesExecutor`. |
| `apache-airflow-providers-cncf-kubernetes` | 10.19.0 | Provides `SparkKubernetesOperator`, which submits a `SparkApplication` custom resource, waits for completion, streams driver logs and handles cleanup. Minimum Airflow it supports is 2.11.0, so 3.2.2 is in range. |

**Why 3.2.2 and not 3.2.0.** This originally read 3.2.0, chosen before the chart was vendored. Chart 1.22.0 declares `appVersion: 3.2.2`, so an install with `defaultAirflowTag` left alone runs 3.2.2, and the plan and the cluster disagreed.

The fix could have gone either way — pin `defaultAirflowTag: "3.2.0"` to match the plan, or update the plan to match the chart. The plan was updated, for the same reason Trino runs 480 rather than the newer 483 (section 4 below): the chart's `appVersion` is the application version that chart release was tested against. Overriding it downwards means running a combination nobody tested, to satisfy a number written down before the chart was read. The number was the thing that was wrong.

Worth stating because the two cases look opposite — for Trino the chart pinned us to an *older* app version than available, for Airflow a *newer* one than planned — but the rule is the same in both: the chart decides, and the document records what the chart decided.
| Kubeflow Spark Operator | 2.5.0 | Owns the `SparkApplication` CRD that the operator above creates, and turns it into driver/executor pods. |

So the chain is: **Airflow DAG → `SparkKubernetesOperator` → `SparkApplication` CR → Spark Operator 2.5.0 → Spark 4.0.1 driver/executor pods → Iceberg 1.10.2 jars → Polaris → S3.** Every hop in that chain is a version pair that exists today.

### 4. Trino ↔ its Helm chart — why 480 and not 483

The `trino` Helm chart lags the Trino release train. Chart 1.42.2, the newest published, ships `appVersion: "480"`, while Trino itself is on 483.

Overriding `image.tag: "483"` would work in all likelihood, but it would run the chart's templates and generated config properties against a version they were never tested against — for no benefit anyone can name. Trino 480 and 483 are three patch-level releases apart, not a feature gap this platform depends on.

So: chart 1.42.2 with its own `appVersion`, consistent with the rest of this document's version policy — take the pairing the maintainers tested, not the newest of each component independently.

| | |
|---|---|
| Chart | 1.42.2 (newest published) |
| Trino | 480 (the chart's `appVersion`) |
| Iceberg support | Trino's built-in `iceberg` connector, `iceberg.catalog.type=rest` |
| Requires | `fs.native-s3.enabled=true` — Trino 470+ removed the legacy Hadoop S3 filesystem, so an `s3://` path cannot be opened without it |

### 5. Kubernetes floor and ceiling

| Consumer | Requires | EKS 1.34 |
|---|---|---|
| Airflow Helm chart 1.22.0 | ≥ 1.30.13 | ✅ |
| Polaris Helm chart 1.5.0 | 1.33+ recommended | ✅ |
| Spark Operator 2.5.0 | permissive; the wider Kubeflow 26.03 *distribution* targets 1.35+, but the operator alone runs on 1.34 | ✅ (noted) |
| EKS standard support | — | ends **2 Dec 2026** |

EKS 1.34 is the right choice for a platform being stood up now: 1.35 removes cgroup v1 and ends containerd 1.x support, and 1.36 permanently disables `gitRepo` volumes and tightens IP/CIDR validation — changes worth planning an upgrade around rather than absorbing at build time. The upgrade to 1.35 should be scheduled before December 2026.

### Things left unpinned on purpose

Nothing. Every component above has an explicit version. Where a component is delivered by a Helm chart, both the chart version and the application version are recorded, because the two move independently — e.g. Argo CD v3.5.0 ships in `argo-cd` chart 10.3.0, and Airflow 3.2.2 in chart 1.22.0.

## Why Apache Polaris as the Iceberg REST Catalog

The Iceberg REST Catalog is a *specification*, not a single product — several implementations exist, and the choice matters because the catalog is the one component every engine must talk to.

| Option | Assessment |
|---|---|
| **Apache Polaris 1.5.0** — chosen | Apache Top-Level Project since February 2026 (donated by Snowflake, contributions from Google, Microsoft, Confluent). Full REST spec implementation with **built-in RBAC** (catalog/principal roles, per-namespace and per-table grants) and **credential vending** — it hands each engine short-lived, scoped-down S3 credentials via `sts:AssumeRole` rather than every engine holding blanket bucket access. That is exactly the governance model described in `SECURITY_GOVERNANCE.md`, obtained from the catalog rather than bolted on. Official Helm chart and Docker images are published by the ASF. |
| `tabulario/iceberg-rest` | The image most tutorials use. Simplest possible setup (a handful of env vars) but it is a community demo image with no RBAC, no credential vending, and no release/security process behind it. Fine for a local demo, not defensible as the control plane of a TB-scale platform. |
| **Lakekeeper** | Rust implementation, very lightweight and fast. Smaller ecosystem and community than Polaris. |
| **Nessie** | Differentiator is Git-like branching/merging across tables — genuinely useful, but solves a problem this platform does not have (the requirement is scheduled daily/hourly batch loads, not multi-table experiment branching). |
| **AWS Glue Data Catalog** | Least to operate, since it is fully managed. Rejected because it is AWS-proprietary — the point of the Iceberg + REST-catalog combination is that the same tables stay readable by any engine on any cloud, and pinning the catalog to Glue gives that portability back. |

### How credential vending works here

Polaris does **not** hold S3 permissions on its own pod identity. The chain is:

```
pod (ServiceAccount: data-platform-workload)
  → data-platform-prod-irsa-role            (IRSA, via EKS OIDC federation)
  → sts:AssumeRole  (+ ExternalId)
  → data-platform-prod-polaris-storage-role (S3 access, scoped to the warehouse prefix)
  → short-lived credentials vended to Trino / Spark per request
```

Set up by `script/set_up_component/01_iceberg_catalog_and_polaris_prod/00_create_polaris_storage_role_prod.sh`. No static AWS access key exists anywhere in the cluster.

## Security & Governance

See `SECURITY_GOVERNANCE.md` for the full breakdown (what's actually implemented vs. documented as a production guideline).

## Storage Cost Management

See `S3_DATA_TIER.md` for the S3 lifecycle tiering and data-classification/deletion policy.

## Bonus Idea (documented only, not implemented)

**Kafka → Apache Flink → ClickHouse** — a parallel, independent path fed directly from the same Kafka topic used for the main Iceberg ingestion, for use cases that genuinely need sub-second dashboard freshness (beyond what the problem statement asks for — Team A daily / Team B hourly). Not built for this take-home since it adds standing (non-scale-to-zero) infrastructure cost and the literal requirement only calls for daily + hourly patterns.

## Why this stack, in one line each

- **Iceberg**: mandatory constraint, and gives storage/compute separation.
- **Polaris over other REST catalog implementations**: Apache-governed, ships RBAC and scoped credential vending in the box, so the security story is a property of the catalog rather than something added around it — see the comparison above.
- **Trino**: most mature Iceberg read/write connector (vs. e.g. ClickHouse, which only recently gained basic catalog-write support), federatable, multi-tenant workload isolation via resource groups, scales via K8s HPA, standard JDBC/ODBC for BI tools.
- **Spark on K8s (Spark Operator)**: mature Iceberg writer (MERGE/UPDATE/DELETE), ephemeral/spot-friendly for cost.
- **Airflow with KubernetesExecutor (not CeleryExecutor)**: Celery would require a Redis or RabbitMQ broker plus a pool of standing worker pods waiting for tasks. KubernetesExecutor removes both — each task becomes an on-demand pod that exits when finished, which suits a workload that runs a handful of times per day and keeps idle cost at zero.
- **RDS over self-hosted Postgres**: the catalog DB is critical state (losing it means losing track of every table); managed backups/PITR remove that operational risk for a small, predictable cost (and it's free-tier eligible for test).
- **S3 over self-hosted MinIO**: cheaper per GB than EBS at scale, virtually unlimited durability/scalability with zero ops burden — the right call for the "terabyte scale" requirement in the problem statement.
- **Argo CD over applying manifests manually**: with two environments that must stay identical, hand-run `kubectl apply` guarantees they eventually diverge. Git becomes the definition of both clusters, promotion from test to production is a merge, and rollback is a revert.
- **Harbor over pulling straight from public registries**: images the platform runs are scanned before they can be deployed, access is controlled per project, and pod startup does not depend on an external registry being reachable.
- **GitHub Actions with self-hosted runners over cloud runners**: in-cluster runners reach Harbor and the EKS API over private networking, so neither has to be exposed to the internet, and the runners scale to zero between builds.
- **AWS Secrets Manager as the source of truth, Kubernetes `Secret` as a synced copy**: enough for three static credentials, with HashiCorp Vault documented as the planned upgrade once dynamic/rotating credentials are actually needed — see the section below.

## Secrets: what is implemented now, and the Vault upgrade path

### Implemented today

| | How |
|---|---|
| Generation | `openssl rand` inside the setup script. No human ever chooses or sees the value. |
| Storage | AWS Secrets Manager, encrypted with a KMS key, IAM-controlled, with CloudTrail recording every `GetSecretValue` call. |
| Delivery | The deploy script reads it and pipes it into `kubectl create secret --dry-run=client -o yaml \| kubectl apply -f -`, so the value never appears as a command-line argument (and therefore never in shell history or a process list). |
| Rotation | Manual: rewrite the Secrets Manager entry, re-run the deploy script. |

Current secret inventory: the RDS master password, the Polaris root client secret, and (once Trino is deployed) the Trino password file — three values.

**What this does not give us, stated plainly rather than papered over:** no per-read audit trail *inside* the cluster (CloudTrail covers the AWS API call, not `kubectl get secret`), no automatic rotation, and a Kubernetes `Secret` is readable in full by any principal holding `get` on it in that namespace.

### Planned upgrade: HashiCorp Vault 2.0.3 (`vault-helm` 0.34.0)

Vault is a **planned component, deliberately not deployed in this iteration** — deferred rather than rejected. What it adds, and how it slots in:

| Capability | What changes |
|---|---|
| Dynamic database credentials | Vault's database secrets engine issues each pod its own short-lived Postgres user instead of everyone sharing the static master password. A leaked credential expires on its own rather than being valid until someone notices. This is the single biggest gain and the reason Vault is on the roadmap at all. |
| Per-read audit log | Every secret read is recorded with who, what and when — the gap CloudTrail cannot close, because it sees the AWS call and not the in-cluster read. |
| Per-secret access policy | Policy attached to the secret itself rather than to a namespace-wide Kubernetes RBAC rule. |
| Delivery mechanism | The Vault Secrets Operator syncs each secret into a native Kubernetes `Secret` and keeps it refreshed. Pods still just mount a `Secret`, so **no application manifest changes** — the migration touches the platform layer only. |

**Why it is deferred:** Vault is stateful and HA-sensitive, with its own unseal ceremony, storage backend and operational lifecycle. Running it properly means a Raft cluster plus a KMS auto-unseal path; running it improperly — single replica, manual unseal — produces a component *less* reliable than the secrets it guards, in a platform where a Vault outage means no pod can start. For three static credentials that trade does not pay off yet.

**Trigger conditions — when to actually do it:**

- the secret inventory passes roughly a dozen values, or more than one team needs scoped access to different subsets;
- a compliance requirement appears for read-level audit of credentials;
- database credentials need to rotate on a schedule rather than on someone remembering.

**Cheaper mitigations to apply first**, both of which are cluster settings rather than new components, and both of which remain worthwhile even after Vault lands: enable EKS envelope encryption with a KMS key so `Secret` objects are not held in etcd in plaintext, and restrict `get secrets` in the `data-platform` namespace via RBAC so only the workload ServiceAccount can read them.

**Intermediate option, if Vault still looks too heavy at that point:** AWS Secrets Manager rotation Lambdas plus the External Secrets Operator gives automatic rotation and keeps the same "sync into a native `Secret`" delivery model, without operating a stateful service.

### Delivery flow

```
pull request → CI (lint, test, build image) → Harbor (scan, store)
             → image tag committed to manifests repo
             → Argo CD reconciles → cluster
```

## Metrics: what is implemented now, and the long-term-storage upgrade path

### Implemented today

| | How |
|---|---|
| Collection | Prometheus 3.13.2 scrapes 31 targets across every namespace via `ServiceMonitor` / `PodMonitor` |
| Storage | its own local TSDB, on a **20Gi gp3 EBS volume** |
| Retention | **7 days or 18GiB, whichever comes first** — both set, because time alone is a promise the disk cannot keep |
| Query | Grafana 13.1.3 reads Prometheus directly |
| Off-cluster copy | **none** |

**What this does not give us, stated plainly rather than papered over:** the
volume is ReadWriteOnce, so Prometheus can only ever have **one replica** and
must stay on the on-demand group — a Spot reclamation would cost observability
at exactly the moment nodes are churning. Past seven days the data is gone for
good, so no month-over-month capacity planning, no "was this slower than the
same day last quarter", and no history that survives the volume.

Seven days does answer what this platform is actually asked today: did last
night's DAG run slow, did the autoscaler thrash this week, was the cluster full
when that driver went Pending.

### Planned upgrade: Grafana Mimir 3.1.2 (`mimir-distributed` 6.1.0)

A **planned component, deliberately not deployed in this iteration** —
deferred rather than rejected, on the same terms as Vault above. Prometheus
`remote_write`s into Mimir, Mimir compacts and ships blocks to S3, and Grafana
points at Mimir instead of Prometheus.

| Capability | What changes |
|---|---|
| Unbounded retention | blocks land in S3 at ~\$0.023/GB-month instead of ~\$0.096/GB-month on EBS, and the limit stops being the size of one volume. This is the whole point |
| Prometheus becomes nearly stateless | local retention drops to a few hours of buffer, so the 20Gi PVC and its single-replica constraint stop mattering |
| High availability | Mimir deduplicates samples from two Prometheus replicas, which is the only way to get a second replica at all while the storage is ReadWriteOnce |
| Downsampling | the compactor keeps recent data at full resolution and older data coarser, so a year-long query does not read a year of raw samples |
| Multi-tenancy | separate limits and retention per tenant — relevant the day Team A and Team B want their own metric budgets |
| Delivery mechanism | Grafana speaks the Prometheus query API to Mimir unchanged, so **no dashboard is rewritten**; the migration touches the datasource and one `remote_write` block |

`kubeVersion: ^1.32.0-0`, so EKS 1.34 clears it. Chart 6.1.0 pins Mimir 3.1.2 —
the same chart-decides-the-version rule as everything else in this document.

**Why it is deferred.** Mimir's microservices topology is six components plus a
hash ring: distributor, ingester, querier, query-frontend, store-gateway,
compactor. The ingesters are stateful, replicate each series three ways, and
each want a PVC — on a five-node cluster that is a meaningful fraction of the
platform, added to store metrics about the platform. Run badly it becomes a
component *less* reliable than the thing it observes, which is the same trap
described for Vault.

**Start monolithic, not microservices.** Mimir runs as a single binary with the
same S3 backend and the same API, and that is where this should begin — the
microservices topology is a scaling decision, not an installation step.

**Trigger conditions — when to actually do it:**

- someone asks a question seven days cannot answer, and asks it twice;
- capacity planning needs month-over-month numbers rather than a snapshot;
- a second Prometheus replica becomes necessary, at which point deduplication
  has to live somewhere.

**Cheaper mitigations to apply first**, both of which are settings rather than
new components: raise `retentionSize` and grow the PVC — `allowVolumeExpansion`
is already `true` on the gp3 class precisely so this is possible — and record
the handful of numbers worth keeping long-term as Grafana snapshots or a
recording rule exported on a schedule.

**Why Mimir rather than Thanos, and when that flips.** Thanos runs as a sidecar
next to the existing Prometheus and uploads its blocks, which at *one*
Prometheus is genuinely less machinery than a Mimir cluster. Mimir is chosen
because the write path (`remote_write`) is what makes Prometheus disposable,
and because multi-tenancy is already a shape this platform has — two teams with
different query patterns. **If the cluster stays at one Prometheus and cost is
the binding constraint, Thanos is the better answer**, and choosing it would
not contradict anything else in this design.

**Where the data would live.** A fourth bucket (or a prefix beside the existing
three), with its own lifecycle rule. `S3_DATA_TIER.md` records that a
`mimir/` lifecycle rule was written once and then removed, because a rule
guarding a prefix that will never receive an object is a rule nobody can
verify — it comes back the day Mimir does, not before.
