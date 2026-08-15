# Data model and lineage

How one day of NYC taxi trips travels from a public Parquet file to a number on
a dashboard, and what happens to it at each step.

How to *run* that pipeline — trigger it, backfill it, repair a day, extend it —
is `HOW_TO_PERFORM_ETL.md`.

## The journey of one row

```
  NYC TLC              yellow_tripdata_2024-01.parquet     ~3,000,000 rows
  (CloudFront)         published monthly, ~2 months late         │
                                                                 │  https, driver-side
                                                                 ▼
┌─ BRONZE ──────────── data_platform.bronze.transactional.taxi_trip ───────────┐
│  one day, kept exactly as published + 3 provenance columns      ~100,000 rows│
│  filtered in Arrow before Spark sees it                                      │
└──────────────────────────────────────────────────────────────────────────────┘
                                                                 │  11 quality rules
                                                                 │  + dedupe + derive
                                                                 ▼
┌─ SILVER ──────────── data_platform.silver.derived.taxi_trip_cleaned ─────────┐
│  one clean, typed, de-duplicated row per real trip               ~95,000 rows│
│  payment code resolved to a name; duration and speed derived                 │
└──────────────────────────────────────────────────────────────────────────────┘
                                                                 │  group by zone
                                                                 │  × payment method
                                                                 ▼
┌─ GOLD ──────────────  data_platform.gold.aggregate.taxi_daily_zone_revenue ──┐
│  pre-aggregated, pre-joined, ready for Power BI Import          ~500 rows    │
└──────────────────────────────────────────────────────────────────────────────┘
                                                                 │  Trino
                                                                 ▼
                                                    Power BI / DBeaver
```

Every arrow is a separate Airflow task with its own Spark driver, its own
retry, and its own idempotency. The stages have genuinely different shapes —
bronze is network-bound and driver-heavy, silver is executor-heavy, gold is
tiny — and one pod cannot be sized correctly for all three.

## Why a day, not a month

The source is published one file per month. The pipeline runs one day per run.

That means ~60 MB crosses the NAT gateway to produce about 1/30th of it, which
costs roughly \$0.003 a run. Deliberate, and the alternative is worse: landing
whole months would make every downstream stage month-grained, so one bad row in
January would mean re-running all of January and the dashboard could not be
corrected for a single Tuesday without rebuilding thirty.

Every table is partitioned on `trip_date`, and every task writes exactly one
value of it. **The unit of failure and the unit of repair are the same single
day.**

## Lineage: tracing a number back to its source

Three columns carried from bronze make this possible:

| Column | Example | Answers |
|---|---|---|
| `_ingested_at` | `2026-08-15T03:12:44Z` | when we loaded it |
| `_source_file` | `yellow_tripdata_2024-01.parquet` | which published file it came from |
| `_run_id` | `taxi-bronze-20240115` | which Spark job wrote it |

`_run_id` is the SparkApplication name, which contains the processing date — so
it also links to the Airflow run, the driver's log, and the Spark event log in
`s3://data-store-prod-logs/spark-events/`.

Working backwards from a suspicious figure in gold:

```sql
-- 1. a gold row looks wrong
SELECT * FROM data_platform."gold.aggregate".taxi_daily_zone_revenue
WHERE trip_date = DATE '2024-01-15' AND pickup_zone = 'JFK Airport';

-- 2. the silver rows behind it        (needs etl_setup)
SELECT * FROM data_platform."silver.derived".taxi_trip_cleaned
WHERE trip_date = DATE '2024-01-15' AND pickup_location_id = 132;

-- 3. and the untouched source rows, with their provenance
SELECT _source_file, _run_id, _ingested_at, count(*)
FROM data_platform."bronze.transactional".taxi_trip
WHERE trip_date = DATE '2024-01-15'
GROUP BY 1, 2, 3;
```

Three queries from a dashboard number to the file it came from.

## Bronze — a faithful copy

`data_platform.bronze.transactional.taxi_trip`

Every column TLC publishes, unchanged and unrenamed, plus the three provenance
columns. No cleaning at all: every quality decision belongs in silver, where it
can be changed and re-run without going back to a publisher who may have
replaced the file by then.

The one thing selected here is the day, because choosing which increment to
load is not cleaning — it is what makes the pipeline incremental.

**`trip_date` is set from the job's argument, not derived from the data.** The
Arrow filter has already guaranteed they agree, and a literal cannot produce a
partition for the year 2098 out of one corrupt timestamp.

The driver streams the monthly file through pyarrow one row group at a time and
filters each batch *before* Spark sees it — the difference between shipping
3,000,000 rows through py4j and shipping 100,000.

## Silver — every filter is a choice, so every filter is counted

`data_platform.silver.derived.taxi_trip_cleaned`

Eleven rules, each counted and printed:

| # | Rule | Why |
|---|---|---|
| 1-2 | pickup / dropoff timestamp not null | unusable |
| 3 | dropoff after pickup | corrupt |
| 4 | pickup falls on the partition's own day | TLC files routinely carry rows dated 2001 or 2098 |
| 5-6 | duration between 1 minute and 24 hours | a mis-punch, or a meter left running |
| 7-8 | distance > 0 and ≤ 500 miles | zero is a cancelled trip; 500 miles inside NYC is a meter fault |
| 9 | fare > 0 | zero or negative is a void or a refund posted as a trip |
| 10 | total ≥ fare | arithmetic that cannot be right |
| 11 | tip ≥ 0 | |

Then de-duplication on `(VendorID, pickup, dropoff, PULocationID, DOLocationID, total_amount)` — after filtering, because a duplicate of a row that was going to be dropped is not worth the shuffle.

**The counts matter more than they look.** A rule that quietly starts dropping
40% of a day is indistinguishable downstream from a quiet Tuesday. The task
refuses to publish if fewer than half the rows survive.

The counts are computed in a single aggregation pass and are **independent** —
each says how many rows fail that rule on its own, so a row failing three rules
is counted three times and the numbers do not sum to the total removed. The
alternative, filter-count-filter-count, costs two full scans per rule and makes
each rule's apparent impact depend on its position in the list.

Derived here: `trip_duration_min`, `avg_speed_mph`, `pickup_hour`,
`pickup_dow`, and `payment_method` — the integer payment code resolved to a
name once, so neither gold nor Power BI needs the mapping.

| Column | Type | From |
|---|---|---|
| `trip_date` | date | partition key |
| `pickup_ts`, `dropoff_ts` | timestamp | cast from source |
| `pickup_hour`, `pickup_dow` | int, string | derived |
| `trip_duration_min`, `avg_speed_mph` | double | derived |
| `pickup_location_id`, `dropoff_location_id` | int | renamed from `PULocationID` / `DOLocationID` |
| `passenger_count` | int | cast |
| `trip_distance_mi` | double | renamed and cast |
| `payment_method` | string | code resolved to a name |
| `fare_amount`, `tip_amount`, `tolls_amount`, `total_amount` | double | cast |
| `_run_id` | string | carried from bronze |

## Gold — shaped for the dashboard, not for the warehouse

`data_platform.gold.aggregate.taxi_daily_zone_revenue`

Grain: **one row per (day × pickup zone × payment method)**. A day of ~95,000
trips becomes a few hundred rows.

Three properties, each chosen so Power BI can use Import mode rather than
DirectQuery:

- **Pre-aggregated** — a year imports instantly and lives in memory. No query
  reaches Trino on a slicer click.
- **Pre-joined** — the 265-row zone lookup is resolved here and broadcast, so
  the report gets `pickup_borough` and `pickup_zone` as plain columns and needs
  no relationships modelled. A `left` join, not `inner`: an unknown LocationID
  becomes "Unknown" rather than vanishing, because trips disappearing between
  silver and gold is the kind of error only ever noticed as a total that does
  not tie out.
- **Pre-computed ratios** — `tip_pct` is stored as **sum(tip) / sum(fare)**,
  not the average of per-trip percentages. Averaging the ratio lets a \$4 trip
  with a \$2 tip count as much as a \$200 trip with a \$10 tip, and the headline
  number comes out wrong in a way that looks entirely plausible. The same rule
  applies to any DAX written against this table.

Columns: `trip_date`, `pickup_borough`, `pickup_zone`, `payment_method`,
`trip_count`, `passenger_count`, `total_distance_mi`, `total_fare`,
`total_tip`, `total_tolls`, `total_revenue`, `avg_fare`, `avg_distance_mi`,
`avg_duration_min`, `avg_speed_mph`, `tip_pct`.

The task **reconciles its own trip count against silver and fails if they
differ**, because a join that silently drops rows produces a revenue dashboard
that is understated with nothing to show for it. It also refuses to publish
more than 20,000 rows for one day — if a change upstream ever explodes the
grain, this is where it stops rather than at the moment someone tries to import
it.

## Idempotency

Every task deletes the day it is about to write, first:

```sql
DELETE FROM <table> WHERE trip_date = DATE '2024-01-15'
```

Airflow retries tasks. An append-only task retried after a partial write leaves
duplicates that no error mentions — they surface weeks later as a revenue
figure that is 1.4× too high. Deleting first means running a task twice leaves
the same table as running it once.

The `DELETE` is cheap: Iceberg rewrites only the affected files, and the table
is partitioned on exactly this column.

## Why the namespace has three levels

`medallion.category.domain` — `bronze.transactional.taxi_trip`,
`gold.aggregate.taxi_daily_zone_revenue`.

The middle level is the data classification, and it is what
`S3_DATA_TIER.md` keys retention off. `bronze.financial.invoice` and
`bronze.log.query_audit` get different lifecycle rules without anyone
maintaining a separate mapping table: **the path is the policy key**, and it is
also the S3 prefix, so a lifecycle rule and a catalog namespace are the same
string.

Trino has no nested schemas and flattens this to a single dotted name, so the
schema is literally called `gold.aggregate` and must be quoted as one
identifier in SQL. That trips people up once; see `docs/powerbi/README.md`.
