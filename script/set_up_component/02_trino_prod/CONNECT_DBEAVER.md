# Connecting DBeaver to Trino

The fastest way to prove the platform is reachable and that the access rules
work. Everything here uses the same endpoint and the same credential a BI tool
does, so if this works, Power BI has nothing left to discover.

Works on macOS, Windows and Linux — unlike Power BI Desktop, which is Windows
only. That is the practical reason to check here first.

## What you need

DBeaver Community Edition. The Trino driver ships with it; DBeaver downloads
the JDBC jar itself the first time you connect, so that machine needs internet
access once.

The credential comes from AWS Secrets Manager and is never in git:

```bash
cd script/set_up_component/02_trino_prod
./02_create_trino_auth_secrets_prod.sh show-powerbi
```

```
host:     trino.nopega.net
port:     443
username: team_b_powerbi
password: <printed here>
```

Use `show-etl` instead to get the `etl_setup` account, which can read every
layer. Do not put that one in a tool other people use — see *What each account
can see* below.

## Creating the connection

**Database → New Database Connection → search `Trino`**

Older DBeaver builds list it as `PrestoSQL`; that driver works too.

### Main tab

| Field | Value |
|---|---|
| Host | `trino.nopega.net` |
| Port | `443` |
| Database/Schema | `data_platform` |
| Username | `team_b_powerbi` |
| Password | from the command above |

### Driver properties tab — do not skip this

Set **`SSL`** to **`true`**.

The Trino JDBC driver does not infer TLS from the port number. Port 443 alone
sends plain HTTP into a TLS listener, and the failure surfaces as something
like `Unexpected end of file` or a bare `Error executing query` — nothing that
mentions SSL. It reads like a broken credential, which is where people then
spend their time.

Check the read-only JDBC URL at the top of the Main tab. It must end with
`?SSL=true`:

```
jdbc:trino://trino.nopega.net:443/data_platform?SSL=true
```

If the property is hard to find, switch **Connect by** to **URL** and type that
string in directly, then fill in the username and password as usual.

**Test Connection** should return the server version.

## Writing queries

Polaris stores namespaces as three levels — medallion / category / domain.
Trino has no nested schemas, so it flattens them into one name joined by dots.
The schema is therefore *literally called* `gold.aggregate`, and it has to be
quoted as a single identifier:

```sql
SELECT * FROM data_platform."gold.aggregate".taxi_daily_zone_revenue LIMIT 10;
--            \_ catalog _/  \_  schema  _/  \_    table       _/
```

Written unquoted, Trino reads it as catalog `data_platform`, schema `gold`,
table `aggregate`, and answers that the table does not exist — which sends you
hunting for a missing table instead of a missing pair of quotes.

Start with these:

```sql
SELECT current_user, current_catalog;

SHOW SCHEMAS FROM data_platform;
SHOW TABLES  FROM data_platform."gold.aggregate";

SELECT trip_date,
       sum(trip_count)              AS trips,
       round(sum(total_revenue), 2) AS revenue
FROM data_platform."gold.aggregate".taxi_daily_zone_revenue
GROUP BY trip_date
ORDER BY trip_date;
```

More, including the reconciliation queries that tell you whether a wrong-looking
number came from the pipeline or from the report, are in
`docs/powerbi/queries.sql`.

## What each account can see

| | `team_b_powerbi` | `etl_setup` |
|---|---|---|
| `gold.*` | SELECT | full |
| `silver.*`, `bronze.*` | denied | full |
| write / DDL anywhere | denied | allowed |
| `system.runtime` (other users' SQL) | denied | allowed |

Verify it in one go. The first must return a number, the second must fail:

```sql
SELECT count(*) FROM data_platform."gold.aggregate".taxi_daily_zone_revenue;
SELECT count(*) FROM data_platform."bronze.transactional".taxi_trip;
```

`Access Denied` on the second is the platform working, not a broken connection.

Gold is the only layer with a contract. Bronze is a verbatim copy of whatever
the publisher sent, and silver's shape changes whenever a cleaning rule
changes; a report built on either would break without anyone having touched the
report. The restriction protects the dashboard as much as it protects the data.

The rules live in `chart/trino/values.yaml` under `accessControl`, are mounted
as a ConfigMap, and Trino re-reads them every 60 seconds — a change needs
`./03_install_trino_prod.sh` and a minute, not a restart.

## When it does not work

| What you see | What it is |
|---|---|
| `Unexpected end of file`, or a bare `Error executing query` on connect | `SSL=true` is not set; the URL has no `?SSL=true` |
| `Access Denied: Cannot select from table system.jdbc.tables` | the `system.jdbc` grant is missing from `rules.json`, or the ConfigMap has not reloaded yet. Connection and login are fine — this is authorization |
| `Access Denied` on a bronze or silver table | working as intended |
| Login rejected with a message about HTTPS | `http-server.process-forwarded=true` is missing, so Trino sees the ALB's plain HTTP and refuses password auth over an insecure channel |
| Certificate error | the ACM certificate covers `trino.nopega.net` exactly; check the host spelling |
| `Table does not exist` for a table you can see in the tree | the dotted schema name was not quoted as one identifier |
| Tree still stale after fixing rules | DBeaver caches metadata — right-click the connection → Invalidate/Reconnect |

### One thing the tree will show that it should not

`bronze.transactional` and `silver.derived` appear in the navigator, and so do
the table names inside them. Trino does not apply table rules when filtering
`system.jdbc.tables` ([trinodb/trino#20864](https://github.com/trinodb/trino/issues/20864)),
which is what DBeaver reads to draw the tree.

Nothing can be read from them — every `SELECT` is denied. Hiding the names as
well would mean one catalog per medallion layer, because catalog rules *are*
enforced in that path. That is a larger change than a visible table name
justifies, so it is a deliberate, documented limit rather than an oversight.

## Where this fits

DBeaver is the diagnostic client. For the reporting path see
`docs/powerbi/README.md`; for querying Iceberg without Trino at all — and the
governance caveat that comes with it — see the last section of that file.
