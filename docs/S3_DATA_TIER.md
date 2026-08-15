# S3 Storage Tiering & Data Retention Policy

Object storage only. The platform's **block** storage — every EBS volume and
PersistentVolumeClaim, and what is deliberately ephemeral — is
`EBS_AND_PERSISTENT_VOLUMES.md`. The split is worth keeping in mind: S3 is
eleven nines across a region, an EBS volume lives in one Availability Zone and
attaches to one node.

## 1. Bucket Layout

The base bucket name is **`data-store`**, split by **environment** and **usage**:

| Bucket | Contents | Status |
|---|---|---|
| `data-store-prod-warehouse` | Iceberg table data files (Parquet + metadata) | **exists** |
| `data-store-prod-logs` | Airflow task logs, Spark event logs, Trino audit logs | **exists** |
| `data-store-prod-registry` | Harbor container image layers | **exists** |
| `data-store-test-*` | the same two, for a test environment | *not created — see below* |

**Why separate buckets:** IAM permissions can be scoped precisely (Trino/Spark only reach `warehouse`, the log shipper only reaches `logs`), a misconfigured rule cannot spill across data types, and per-bucket cost is immediately visible in Cost Explorer without extra cost-allocation tagging.

**On the test buckets.** The naming scheme carries an environment segment
because a test environment was designed alongside this one — a `kind` cluster
on a single EC2 instance using *real* S3 and *real* RDS rather than MinIO and a
container Postgres, so that promoting to prod needs no path or config change.
Those scripts were written and then removed from this submission: carrying a
second environment nobody was running added surface without adding evidence.

The segment stays in the naming scheme, and `01_create_s3_buckets_prod.sh`
creates only the prod buckets (`ALL_BUCKETS=("$PROD_WH" "$PROD_LOGS")`). The
lifecycle rules below are written against the prod buckets and would apply
unchanged to a test pair.

Long-term Prometheus metrics are **not** in the logs bucket. Prometheus keeps 7
days on an EBS volume and ships nothing to S3. The growth path is **Grafana
Mimir 3.1.2**, pinned as a planned upgrade in `STACK_SUMMARY.md` — when it
lands it needs its own bucket or prefix, and the lifecycle rule described at
the end of section 4 comes back with it. See
`HOW_TO_MONITOR_THE_PLATFORM.md`.

Sections 2–4 below concern the **warehouse** bucket; the **logs** bucket is covered at the end of section 4.

---

## 2. Age-Based Storage Tiers (warehouse bucket)

**Why tier:** An Iceberg table consists of many Parquet files sitting in S3. Iceberg groups those files into partitions (for example, by date) in its own metadata layer — but S3, which physically stores the files, knows nothing about those partitions. S3 sees only individual objects, each with the date it was uploaded. So when S3 Lifecycle decides which objects to move to cheaper storage, the only criterion it uses is how long ago that object was uploaded, regardless of which Iceberg partition it belongs to.

The tiering principle: recent data is queried constantly, older data is rarely touched. Leaving everything on S3 Standard wastes money, so objects are moved to progressively cheaper classes automatically as they age.

| Object age | Storage class |
|---|---|
| 0–90 days | S3 Standard |
| 90 days – 1 year | S3 Standard-IA |
| 1–3 years | S3 Glacier Instant Retrieval |
| 3+ years | Glacier Deep Archive or deletion (depends on classification, section 3) |

---

## 3. Data Classification (governs deletion only)

The tier schedule in section 2 applies identically to every category — that is purely a cost decision. Classification below affects only the **final step**: whether the data may be deleted automatically at all.

| # | Category | Examples | Deletion policy |
|---|---|---|---|
| 1 | **Financial** | `order_amount`, payment status | Never auto-deleted. Removal requires explicit approval once the legal accounting/tax retention period has passed. |
| 2 | **Transactional** | `order_status`, status-change timestamps (not monetary values themselves) | Auto-deletion permitted after a long retention window that allows for disputes and internal audits. This is a business decision rather than a statutory requirement. |
| 3 | **Operational** | Driver location tables, system/business state snapshots | Auto-deletion permitted, but retained longer than raw logs since the data still carries analytical value. |
| 4 | **Log** | Raw application/system logs (debug output, error traces); and, separately, structured log data modelled as Iceberg tables (query audit trails, access records) | Shortest retention of any category. Raw log files live in the `logs` bucket (30 days); structured log tables live under `log/` in the `warehouse` bucket and are kept for 365 days because they serve audit rather than debugging. |
| 5 | **Derived** | Cleaned/deduplicated tables built from raw tables (not summarized) | Always reproducible from raw data, so auto-deletion is safe whenever convenient. |
| 6 | **Aggregate** | e.g. `daily_merchant_sales_summary` (rolled-up totals) | Very small files with low storage cost, so retained longer than Derived even though it is equally reproducible. |

---

## 4. Lifecycle Rules per Bucket

### Bucket: `data-store-*-warehouse`

Classification is expressed through the warehouse layout. The path has three parts before the table — **medallion layer / data-governance category / business domain** — and every Iceberg namespace is created with its location pinned to the matching prefix.

```
s3://data-store-prod-warehouse/
├── bronze/                     raw, as ingested — not derivable from anything else
│   ├── financial/
│   │   └── invoice/
│   │       └── <table>/
│   │           ├── data/
│   │           └── metadata/
│   ├── transactional/
│   │   └── delivery/
│   ├── operational/
│   │   └── driver_location/
│   └── log/
│       └── query_audit/
│
├── silver/                     cleaned, deduplicated, joined
│   └── derived/
│       └── orders_cleaned/
│
└── gold/                       rolled up for consumption
    └── aggregate/
        └── merchant_sales_summary/
```

### Why two dimensions and not one

The first segment is the **medallion layer**, the second is the **data-governance category** from section 3. They answer different questions and neither replaces the other:

| | Answers | Determines |
|---|---|---|
| medallion (`bronze`/`silver`/`gold`) | how far through processing this data is | whether it can be recomputed if lost |
| category (`financial`, `log`, …) | what kind of data this is | how long it must be kept, and whether automated deletion is permitted at all |

The two are genuinely independent: financial data is never auto-deleted whether it sits in bronze or gold, and gold data is recomputable whether it started as financial or operational. Collapsing them into one level would force a choice between expressing retention and expressing recomputability.

Medallion goes first because it is the more stable split — a table changes domain occasionally and changes medallion layer essentially never — and because it makes the recomputable and non-recomputable halves of the bucket visible at the top level, which is what matters when deciding what a lifecycle rule may safely delete.

### Why `silver/derived/` and `gold/aggregate/` repeat themselves

`silver/` contains only `derived/`, and `gold/` only `aggregate/`, so the second segment there carries no information the first does not. That redundancy is kept on purpose: every table path then has the same shape — `medallion/category/domain/table` — which means one lifecycle-rule pattern, one grant pattern, and one path-parsing rule instead of a special case for two layers out of three. Bronze genuinely needs the split, because its four categories have four different retention policies.

### The path *is* the Iceberg namespace

These are not free-form folders. `bronze/financial/invoice/orders` is the table `data_platform."bronze.financial.invoice".orders` — a three-level Iceberg namespace with the table beneath it. `07_create_dg_namespaces_prod.sh` creates each level with its `location` pinned to the matching prefix, which is what stops a table from being created outside the classification it was declared under.

Everything is lowercase because Trino lowercases any SQL identifier that is not double-quoted; a namespace named `Bronze` would have to be written `"Bronze"."Financial"` at every use site, and forgetting the quotes yields "schema not found" rather than an error that explains itself.

### `bronze/log/` versus the logs bucket

`bronze/log/` holds structured log **tables** — audit trails and access records that engines read with SQL. Raw log **files** (debug output, stack traces) stay in the separate `data-store-*-logs` bucket covered at the end of this section. Both are classified Log; they differ in whether the data has a schema and is read by a query engine.

A table is placed in the correct prefix at creation time by setting its location explicitly:

```sql
CREATE TABLE data_platform."bronze.transactional.delivery".orders (...)
USING iceberg
LOCATION 's3://data-store-prod-warehouse/bronze/transactional/delivery/orders'
PARTITIONED BY (order_date);
```

Each medallion/category pair then gets its own dedicated lifecycle rule. Note that the rules key on the **two-segment** prefix, not on the medallion alone: retention is a property of the category, so `bronze/financial/` and `bronze/log/` need different treatment despite both being bronze.

```json
{
  "Rules": [
    {
      "ID": "financial-data-tiering",
      "Status": "Enabled",
      "Filter": { "Prefix": "bronze/financial/" },
      "Transitions": [
        { "Days": 90,   "StorageClass": "STANDARD_IA" },
        { "Days": 365,  "StorageClass": "GLACIER_IR" },
        { "Days": 1095, "StorageClass": "DEEP_ARCHIVE" }
      ]
    },
    {
      "ID": "transactional-data-tiering",
      "Status": "Enabled",
      "Filter": { "Prefix": "bronze/transactional/" },
      "Transitions": [
        { "Days": 90,  "StorageClass": "STANDARD_IA" },
        { "Days": 365, "StorageClass": "GLACIER_IR" }
      ],
      "Expiration": { "Days": 1095 }
    },
    {
      "ID": "operational-data-expiry",
      "Status": "Enabled",
      "Filter": { "Prefix": "bronze/operational/" },
      "Transitions": [
        { "Days": 90, "StorageClass": "STANDARD_IA" }
      ],
      "Expiration": { "Days": 180 }
    },
    {
      "ID": "log-table-expiry",
      "Status": "Enabled",
      "Filter": { "Prefix": "bronze/log/" },
      "Transitions": [
        { "Days": 90, "StorageClass": "STANDARD_IA" }
      ],
      "Expiration": { "Days": 365 }
    },
    {
      "ID": "derived-data-tiering",
      "Status": "Enabled",
      "Filter": { "Prefix": "silver/derived/" },
      "Transitions": [
        { "Days": 90,  "StorageClass": "STANDARD_IA" },
        { "Days": 365, "StorageClass": "GLACIER_IR" }
      ],
      "Expiration": { "Days": 1095 }
    },
    {
      "ID": "aggregate-data-tiering",
      "Status": "Enabled",
      "Filter": { "Prefix": "gold/aggregate/" },
      "Transitions": [
        { "Days": 90,  "StorageClass": "STANDARD_IA" },
        { "Days": 365, "StorageClass": "GLACIER_IR" }
      ],
      "Expiration": { "Days": 1825 }
    },
    {
      "ID": "abort-incomplete-multipart-uploads",
      "Status": "Enabled",
      "Filter": {},
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    },
    {
      "ID": "cleanup-noncurrent-versions",
      "Status": "Enabled",
      "Filter": {},
      "NoncurrentVersionExpiration": { "NoncurrentDays": 30 }
    }
  ]
}
```

Notes:

- Prefix filters are used rather than object tags. A tag has to be applied by the writer on every object (in Iceberg, via the `s3.write.tags.data-class` catalog property), so a job launched with that property missing silently produces untagged objects that no rule matches. A prefix is inherent to where the file was written, so classification cannot be lost through a configuration mistake, and it is visible by simply listing the bucket.
- The `financial-data-tiering` rule intentionally has no `Expiration` block: financial data is only ever removed through an approved manual process, never by automation.
- `log-table-expiry` uses 365 days, not the 30 days applied to raw logs in the `logs` bucket. The two are both classified Log but serve different purposes: raw logs are for debugging and lose value within weeks, whereas an audit table is evidence and is expected to survive a compliance review cycle. It is deliberately the shortest retention of any category in the warehouse bucket.
- Moving a table between categories means moving its files to a different prefix and updating its Iceberg location — a deliberate operation rather than a tag edit, which is appropriate given the compliance implications of reclassification.
- The final two rules apply bucket-wide with no filter. They are housekeeping (clearing failed multipart uploads and superseded object versions) rather than business-data retention, so a global scope is safe.
- Deploy with:
  ```
  aws s3api put-bucket-lifecycle-configuration \
    --bucket data-store-prod-warehouse \
    --lifecycle-configuration file://warehouse-lifecycle.json
  ```

### Bucket: `data-store-prod-logs`

Log objects are small and rarely re-read, so no tiering is needed — a straightforward expiration per prefix is sufficient.

Three prefixes exist today, and each has a different reason for its number:

| Prefix | Days | Written by | Why that long |
|---|---|---|---|
| `airflow/` | 30 | Airflow remote logging | debugging a task run; worthless after a month |
| `trino-audit/` | 365 | *(nothing yet)* | reserved for the query audit log, which is evidence rather than debugging output. `eventListenerProperties` is unset, so nothing writes here — see the gaps table in `SECURITY_GOVERNANCE.md` |
| `spark-events/` | 90 | every Spark driver | read by the Spark History Server. Long enough to compare this month's ETL runs with last month's, short enough that it does not grow without bound |

The `spark-events/` rule replaced one for `mimir/` at 730 days. That rule was
written for a component the platform does not run — a lifecycle rule matching a
prefix that will never receive an object is harmless, but it hid the fact that
the prefix which DOES grow every day had no rule at all.

**The `mimir/` rule returns when Mimir does, not before.** Mimir is a pinned
planned upgrade (3.1.2, chart 6.1.0 — see `STACK_SUMMARY.md`), and 730 days is
still the right number for it. Writing the rule now would only recreate a
guarantee nobody can verify.

```json
{
  "Rules": [
    {
      "ID": "airflow-log-expiry",
      "Status": "Enabled",
      "Filter": { "Prefix": "airflow/" },
      "Expiration": { "Days": 30 }
    },
    {
      "ID": "trino-audit-log-expiry",
      "Status": "Enabled",
      "Filter": { "Prefix": "trino-audit/" },
      "Expiration": { "Days": 365 }
    },
    {
      "ID": "spark-event-log-expiry",
      "Status": "Enabled",
      "Filter": { "Prefix": "spark-events/" },
      "Expiration": { "Days": 90 }
    },
    {
      "ID": "abort-incomplete-multipart-uploads",
      "Status": "Enabled",
      "Filter": {},
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    }
  ]
}
```

Audit logs are kept substantially longer than ordinary operational logs (365 days versus 30) because they serve a security and compliance purpose rather than a purely operational one.

Deploy with:

```
aws s3api put-bucket-lifecycle-configuration \
  --bucket data-store-prod-logs \
  --lifecycle-configuration file://logs-lifecycle.json
```
