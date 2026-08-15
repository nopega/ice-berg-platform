# How to perform ETL

> *"Please demonstrate one data pipeline that performs ETL of external data
> into this data platform and stores the data as an Iceberg table."*
> — Constraint 3
>
> *"Guidelines on how to perform ETL."* — Deliverable 3

The pipeline is `nyc_taxi_medallion`: one day of NYC TLC Yellow Taxi trips,
downloaded from a public CloudFront endpoint and landed as three Iceberg tables.
This document is how to **run, watch, verify, repair and extend** it.

What the tables contain and why they are shaped that way is a separate
question — `DATA_MODEL.md`.

## What one run actually does

```
Airflow scheduler                          10:00 Asia/Bangkok, or a manual trigger
      │  creates a task pod (KubernetesExecutor)
      ▼
SparkKubernetesOperator                    renders spark/<stage>.yaml through Jinja
      │  creates a SparkApplication object — it never creates a pod itself
      ▼
Spark Operator                             sees the object, creates the driver pod
      │
      ▼
Spark driver  ──https──▶ raw.githubusercontent.com     fetches its own job code
      │                  nopega/ice-berg-data-pipeline
      │  OAuth2
      ▼
Apache Polaris ──vends short-lived scoped S3 creds──▶ s3://data-store-prod-warehouse
      │
      └──requests 2 executors──▶ ng-spot        Spot nodes start from zero
```

Three tasks in a line, `bronze_ingest >> silver_clean >> gold_aggregate`. Each
is its own SparkApplication with its own driver, its own resources and its own
retry, because the stages have genuinely different shapes: bronze is
network-bound and driver-heavy, silver is executor-heavy, gold is tiny. One pod
cannot be sized correctly for all three.

**Two repos, and neither is this one.** Airflow git-syncs the DAG from
`nopega/airflow_dag`; the Spark driver downloads its Python from
`nopega/ice-berg-data-pipeline` at submit time. `dags/` and `pipeline_repo/`
here are mirrors — see their READMEs for why the split exists and what it costs.

---

## Running it

### 1. On a schedule — nothing to do

`0 10 * * *` Asia/Bangkok, `catchup=False`, `max_active_runs=1`.

A scheduled run processes **the same calendar day three months earlier**. TLC
publishes each month's file roughly two months after the month ends, so
"yesterday" does not exist as source data and never will. Ask for a recent date
and CloudFront answers 403, which reads like a permissions problem and is not.

A fixed 10:00 rather than `@daily`: a failure at 10:00 is noticed the same
morning; a failure at 00:15 is noticed at 09:00 anyway.

### 2. One specific day — from the UI

`https://airflow.nopega.net` → `nyc_taxi_medallion` → **Trigger**.

Every parameter renders as a form field with its description, because each is a
typed `Param` rather than a bare dict entry. Set `date` and leave the rest:

```json
{ "date": "2024-01-15" }
```

### 3. One specific day — from a terminal

```bash
kubectl exec -n airflow deploy/airflow-scheduler -c scheduler -- \
  airflow dags trigger nyc_taxi_medallion -c '{"date": "2024-01-15"}'
```

### 4. A range of days

The pipeline's unit is a day, so a range is a loop of triggers:

```bash
for d in 2024-01-1{5,6,7,8,9}; do
  kubectl exec -n airflow deploy/airflow-scheduler -c scheduler -- \
    airflow dags trigger nyc_taxi_medallion -c "{\"date\": \"$d\"}"
done
```

`max_active_runs=1` makes them queue and run one at a time, which is what stops
a five-day backfill asking a five-node cluster for fifteen concurrent Spark
jobs.

**Airflow's own `airflow backfill create` also works, with one trap.** It sets
the run's logical date, and `resolve_date()` subtracts three months from that
when `params.date` is empty — so a backfill of `2024-04-15 → 2024-04-20`
processes January, not April. Its `--dag-run-conf` applies the *same* conf to
every run in the range, so it cannot be used to pass a per-day `date`. The loop
above says what it means.

### 5. Without Airflow at all

For debugging the Spark side while Airflow is down or suspect, render a
template yourself and apply it. There are only four `{{ }}` values in the file
and they are all literals:

```bash
python3 - <<'PY' > /tmp/bronze.yaml
import jinja2, pathlib
tpl = pathlib.Path("dags/spark/bronze_ingest.yaml").read_text()
print(jinja2.Template(tpl).render(
    params={"image_tag": "v1.0.2",
            "pipeline_repo": "nopega/ice-berg-data-pipeline",
            "pipeline_ref": "refs/heads/main"},
    resolve_date=lambda *_: "2024-01-15",
    data_interval_start=None,
))
PY

kubectl apply -f /tmp/bronze.yaml
kubectl logs -n spark -l spark-role=driver -f
```

Useful precisely because it removes Airflow from the picture: if this works and
the DAG does not, the problem is scheduling, RBAC or templating — not Spark,
Polaris or S3.

---

## The knobs

| Param | Default | Pins |
|---|---|---|
| `date` | derived from the run, minus 3 months | which day to process |
| `image_tag` | `v1.0.2` | the **runtime** — Spark 4.0.1, Iceberg jars, AWS SDK, pinned Python libs |
| `pipeline_repo` | `nopega/ice-berg-data-pipeline` | where the **logic** comes from |
| `pipeline_ref` | `refs/heads/main` | which commit of it |

For a run that must not move underneath itself, pin the ref to a SHA:

```json
{ "date": "2024-01-15", "pipeline_ref": "3f2a9c1" }
```

Every param carries a regex `pattern`, and that is not decoration. All four are
interpolated into the `https://` URL the driver fetches its code from. A
character that is illegal in a URI makes Spark's `Utils.resolveURI()` throw,
fall back to treating the whole URL as a *local* path, and die several minutes
in with:

```
URISyntaxException: Expected scheme-specific part at index 6: https:
```

— which names neither the parameter nor the URL. The pattern rejects the value
at trigger time instead, while the message can still be useful.

---

## Watching a run

Four places, in the order worth trying them.

| Ask | Where |
|---|---|
| did the task run, and what did the driver print | Airflow task log — the operator streams driver stdout into it |
| why is there no driver pod | `kubectl get sparkapplication -n spark` and its `.status` |
| why is the driver Pending | `kubectl describe pod -n spark <driver>` |
| what did the finished job actually do | Spark History Server — stages, shuffle, skew |

```bash
kubectl get sparkapplications -n spark
kubectl logs -n spark -l spark-role=driver --tail=100 -f
kubectl get pods -n spark -w
```

Each job prints numbered progress — `[1/4] Downloading...`, `[3/5] Applying 11
quality rules...` — so the Airflow log alone usually says which step it reached.

Driver pods are kept after a **failed** run (`delete_on_termination=False`) so
the log survives long enough to read; successful ones are cleaned up by
`timeToLiveSeconds: 3600` in the template.

**A finished driver serves nothing.** Its UI on port 4040 dies with it, and its
name carries a random suffix that changes every run, so it can never have a
stable hostname. That is what the Spark History Server exists for — it reads
the event logs the drivers already write to
`s3://data-store-prod-logs/spark-events/` and renders the same UI back.
`06_spark_prod/07_deploy_history_server_prod.sh`

Failures also arrive by mail. `SmtpNotifier` fires **once, on final failure
only** — not on success, not on retry. A daily pipeline that mails every run
produces 365 messages a year that all say "fine", and the one that says
otherwise lands in a folder nobody reads any more.

---

## Verifying the result

The tasks verify themselves — each counts what it wrote and fails if the table
disagrees — but the independent check is SQL:

```sql
-- one day, all three layers, from Trino
SELECT count(*) FROM data_platform."bronze.transactional".taxi_trip
WHERE trip_date = DATE '2024-01-15';                    -- ~100,000

SELECT count(*) FROM data_platform."silver.derived".taxi_trip_cleaned
WHERE trip_date = DATE '2024-01-15';                    -- ~95,000

SELECT count(*), sum(trip_count) FROM data_platform."gold.aggregate".taxi_daily_zone_revenue
WHERE trip_date = DATE '2024-01-15';                    -- ~500 rows, tying back to silver
```

`sum(trip_count)` in gold must equal silver's row count exactly. The gold task
already asserts this, so a mismatch here means someone wrote to a table outside
the pipeline.

Needs the `etl_setup` credential — the BI account can only see gold. See
`HOW_USERS_CONNECT_AND_QUERY.md`.

---

## Re-running is safe by construction

Every task deletes the day it is about to write, first:

```sql
DELETE FROM <table> WHERE trip_date = DATE '2024-01-15'
```

Airflow retries tasks. An append-only task retried after a partial write leaves
duplicates that no error ever mentions — they surface weeks later as a revenue
figure that is 1.4× too high. Deleting first means **running a task twice
leaves the same table as running it once**, which is what makes a retry, a
manual re-trigger and a correction all the same operation.

The `DELETE` is cheap: Iceberg rewrites only the affected files, and every
table is partitioned on exactly this column.

To correct one bad day, re-trigger that day. Nothing else is touched.

---

## Changing the pipeline

Three kinds of change, three different blast radiuses. This is the part people
get wrong, because a push to one repo has no effect on the other.

| Change | Where | Takes effect | Needs |
|---|---|---|---|
| a filter, a rule, an aggregation | `nopega/ice-berg-data-pipeline` | **next task run** | a push |
| the DAG, a SparkApplication template | `nopega/airflow_dag` | next scheduler parse, ~1 min | a push |
| a Python library, a Spark or Iceberg version | `06_spark_prod/Dockerfile`, `requirements.txt` | next run using the new tag | rebuild, push to Harbor, bump `image_tag` |

**The image supplies the runtime; git supplies the logic.** The image tag
answers "what could this have run with"; the git ref answers "what did it run".
That separation is why fixing a cleaning rule needs no image rebuild and no
Airflow restart.

```bash
cd script/set_up_component/06_spark_prod
./03_build_and_push_image_prod.sh            # tag derived from git, `-dirty` if uncommitted
```

**A new shared module must be added to `deps.pyFiles` in all three templates.**
Spark downloads exactly the files it is told about. A missing one surfaces as
`ModuleNotFoundError` *after* the pod has started and the executors have been
requested — not at submit time.

---

## Adding a new pipeline

The taxi pipeline is deliberately not special. A second one is the same six
steps:

1. **Create the namespace leaves** the tables will live in.
   `01_iceberg_catalog_and_polaris_prod/07_create_dg_namespaces_prod.sh` —
   `medallion.category.domain`, lowercase, and the category is what
   `S3_DATA_TIER.md` keys retention off. The path is the policy key.
2. **Write the jobs** under `pipelines/<family>/` in the pipeline repo. Reuse
   `common.py`: `build_spark()`, `date_arg()`, `replace_day()`. Take
   `--date YYYY-MM-DD`, delete that day, write it, verify the count.
3. **Copy a SparkApplication template** per stage. Change
   `metadata.name`, `mainApplicationFile`, and the driver/executor sizes —
   nothing else in it is stage-specific.
4. **Copy the DAG**, keeping `user_defined_macros` for the date (BaseOperator's
   `params` is not a templated field, so a Jinja expression assigned to it
   arrives at the YAML as literal text).
5. **Grant read on the new gold namespace** to the BI principal, in
   `02_trino_prod/chart/trino/values.yaml` → `accessControl`. Rules are
   first-match-wins and the last one denies everything.
6. **Run `platform_smoke_test` first** if anything about the delivery chain has
   changed. It has no dependency on Spark, Polaris or S3, so a failure there
   means the problem is Airflow itself and not the pipeline you just wrote.

---

## When the pipeline refuses to publish

Silent bad data is worse than a red task, so each stage has a gate it will not
write through:

| Stage | Refuses when | Because |
|---|---|---|
| bronze | zero rows kept for the day | the date is outside the month its file covers, or TLC published an empty file — both look like success otherwise |
| bronze | rows written ≠ rows kept | a partial write |
| silver | **fewer than 50% of rows survive cleaning** | a rule that quietly starts dropping 40% of a day is indistinguishable downstream from a quiet Tuesday |
| gold | **more than 20,000 rows for one day** | the grain exploded upstream; a gold table this size is one Power BI cannot import |
| gold | `sum(trip_count)` ≠ silver's row count | the zone join dropped rows, and the revenue dashboard would be understated with nothing to show for it |

Silver also **counts and prints every one of its eleven rules individually**,
in a single aggregation pass. The counts are independent — a row failing three
rules is counted three times, so they do not sum to the total removed. The
alternative, filter-count-filter-count, costs two full scans per rule and makes
each rule's apparent impact depend on its position in the list.

---

## Failure modes

| Symptom | Cause |
|---|---|
| driver dies at once, 404 on `raw.githubusercontent.com` | `pipeline_repo` / `pipeline_ref` wrong, or the repo is private |
| `URISyntaxException: ... index 6: https:`, **no driver pod at all** | a param contains a character illegal in a URI. The `pattern` on each Param rejects this at trigger time now |
| `ModuleNotFoundError: common` | a shared module was added but not listed in `deps.pyFiles` |
| task stays **queued** forever | the DAG is paused, or the scheduler cannot create task pods (RBAC) |
| driver `Pending`, task hangs | no room on `workload=critical`; `kubectl describe pod` names the reason |
| `Initial job has not accepted any resources` | executors Pending — a Spot node is still starting, or the Cluster Autoscaler is not running. See `AUTOSCALING.md` |
| `403` from CloudFront in bronze | asked for a date in a month TLC has not published |
| `no trips on <date>` | the date is outside the month its file covers, or a genuinely empty file |
| `NoSuchNamespaceException` | `07_create_dg_namespaces_prod.sh` has not created the leaves |
| `ImagePullBackOff` | the `harbor-pull` secret is missing from the `spark` namespace |

## What Airflow is allowed to do

```bash
kubectl auth can-i create pods -n spark \
  --as=system:serviceaccount:airflow:airflow-worker       # no
kubectl auth can-i create sparkapplications -n spark \
  --as=system:serviceaccount:airflow:airflow-worker       # yes
```

A compromised DAG can ask the cluster for a Spark job — a known image running
known code from a known repo — but cannot start a container of its own
choosing. `06_spark_prod/01_create_namespace_and_sa_prod.sh` asserts both.
