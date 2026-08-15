-- Queries for the Power BI connection to Trino.
--
-- Run these as team_b_powerbi. If any of them returns "Access Denied", that is
-- the file-based access control in 02_trino_prod/chart/trino/values.yaml doing
-- its job -- check which schema the query touches before assuming a bug.
--
-- On the quoting: Polaris stores namespaces as three levels
-- (medallion / category / domain). Trino has no nested schemas, so it flattens
-- them into one name joined by dots. That name therefore CONTAINS dots and has
-- to be double-quoted as a single identifier:
--
--     data_platform."gold.aggregate".taxi_daily_zone_revenue
--      \_ catalog _/ \_ schema  _/  \_ table _/
--
-- Writing it unquoted asks Trino for catalog `data_platform`, schema `gold`,
-- table `aggregate` -- and the error says the table does not exist, which
-- sends you looking in the wrong place.


-- ===========================================================================
-- 1. CONNECTION CHECK
-- ===========================================================================

-- Who am I, and did the ALB forward the request properly?
SELECT current_user, current_catalog;

-- What can this account actually see? bronze and silver schemas will be
-- listed, but empty -- see the access-control comment in values.yaml.
SHOW SCHEMAS FROM data_platform;
SHOW TABLES FROM data_platform."gold.aggregate";

-- These two must fail for the BI account. If either succeeds, access control
-- is not loaded.
-- SELECT * FROM data_platform."bronze.transactional".taxi_trip LIMIT 1;
-- DROP TABLE data_platform."gold.aggregate".taxi_daily_zone_revenue;


-- ===========================================================================
-- 2. WHAT POWER BI IMPORTS
-- ===========================================================================
--
-- The whole table. This is deliberate and it is the point of the gold layer:
-- a day is a few hundred rows, so a year is well under a hundred thousand, and
-- Power BI's in-memory engine handles that without a gateway, a schedule
-- window, or DirectQuery latency on every slicer click.
--
-- Paste this into the connector's "Native SQL Query" box, or just pick the
-- table in the navigator -- they produce the same import.

SELECT
    trip_date,
    pickup_borough,
    pickup_zone,
    payment_method,
    trip_count,
    passenger_count,
    total_distance_mi,
    total_fare,
    total_tip,
    total_tolls,
    total_revenue,
    avg_fare,
    avg_distance_mi,
    avg_duration_min,
    avg_speed_mph,
    tip_pct
FROM data_platform."gold.aggregate".taxi_daily_zone_revenue
ORDER BY trip_date, total_revenue DESC;


-- If the table ever outgrows a full import, filter on the partition column --
-- and ONLY on the partition column. trip_date is what the table is partitioned
-- by, so Iceberg prunes whole files; a predicate on pickup_zone reads
-- everything and then discards it.
--
-- SELECT * FROM data_platform."gold.aggregate".taxi_daily_zone_revenue
-- WHERE trip_date >= DATE '2024-01-01';


-- ===========================================================================
-- 3. THE NUMBERS THE DASHBOARD SHOWS
-- ===========================================================================
-- Run these once in the CLI and note the answers. When a Power BI visual
-- disagrees with one of them, the problem is in the report's DAX, not the
-- pipeline -- which is a much shorter thing to debug.

-- Headline totals per day.
SELECT
    trip_date,
    sum(trip_count)                                   AS trips,
    round(sum(total_revenue), 2)                      AS revenue,
    round(sum(total_revenue) / sum(trip_count), 2)    AS revenue_per_trip
FROM data_platform."gold.aggregate".taxi_daily_zone_revenue
GROUP BY trip_date
ORDER BY trip_date;

-- Top pickup zones by revenue.
SELECT
    pickup_borough,
    pickup_zone,
    sum(trip_count)              AS trips,
    round(sum(total_revenue), 2) AS revenue
FROM data_platform."gold.aggregate".taxi_daily_zone_revenue
GROUP BY pickup_borough, pickup_zone
ORDER BY revenue DESC
LIMIT 20;

-- Tipping by payment method.
--
-- Note the arithmetic: sum(tip) / sum(fare), NOT avg(tip_pct). Averaging a
-- percentage weights a $4 trip the same as a $200 one, and the resulting
-- number looks entirely plausible while being wrong. The same rule applies to
-- any measure written in DAX against this table -- SUM(total_tip) /
-- SUM(total_fare), never AVERAGE(tip_pct).
SELECT
    payment_method,
    sum(trip_count)                                        AS trips,
    round(sum(total_fare), 2)                              AS fare,
    round(sum(total_tip), 2)                               AS tip,
    round(100.0 * sum(total_tip) / nullif(sum(total_fare), 0), 2) AS tip_pct
FROM data_platform."gold.aggregate".taxi_daily_zone_revenue
GROUP BY payment_method
ORDER BY trips DESC;

-- Zones where the average trip is longest, restricted to zones with enough
-- trips for the average to mean anything. Without the HAVING, a zone with two
-- airport runs tops the list.
SELECT
    pickup_zone,
    sum(trip_count)                                                   AS trips,
    round(sum(total_distance_mi) / sum(trip_count), 2)                AS avg_miles,
    round(sum(total_revenue) / sum(trip_count), 2)                    AS avg_revenue
FROM data_platform."gold.aggregate".taxi_daily_zone_revenue
GROUP BY pickup_zone
HAVING sum(trip_count) >= 100
ORDER BY avg_miles DESC
LIMIT 20;


-- ===========================================================================
-- 4. DATA FRESHNESS
-- ===========================================================================
-- Worth putting on the report as a footer. A dashboard that silently shows
-- last week's numbers is worse than one that is visibly broken.

SELECT
    max(trip_date)                                   AS latest_day,
    count(DISTINCT trip_date)                        AS days_loaded,
    date_diff('day', max(trip_date), current_date)   AS days_behind
FROM data_platform."gold.aggregate".taxi_daily_zone_revenue;

-- `days_behind` is expected to be roughly 90, not 0: TLC publishes each month
-- about two months after it ends, and the DAG deliberately processes the same
-- calendar day three months back. A value near zero would mean someone
-- backfilled by hand.


-- ===========================================================================
-- 5. RECONCILIATION (etl_setup only -- reads silver)
-- ===========================================================================
-- team_b_powerbi cannot run this, by design. Use it from a terminal when a
-- number on the dashboard looks wrong and you need to know whether gold or the
-- report is at fault.

-- SELECT
--     g.trip_date,
--     g.gold_trips,
--     s.silver_trips,
--     g.gold_trips - s.silver_trips AS difference
-- FROM (
--     SELECT trip_date, sum(trip_count) AS gold_trips
--     FROM data_platform."gold.aggregate".taxi_daily_zone_revenue
--     GROUP BY trip_date
-- ) g
-- FULL JOIN (
--     SELECT trip_date, count(*) AS silver_trips
--     FROM data_platform."silver.derived".taxi_trip_cleaned
--     GROUP BY trip_date
-- ) s USING (trip_date)
-- ORDER BY 1;
--
-- The gold task already fails if these disagree, so a non-zero difference here
-- means someone wrote to a table outside the pipeline.
