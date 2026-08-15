# Connecting Power BI to the platform

This is deliverable 4 of the take-home: how a user connects and queries the
data. Power BI is the client shown here because it is what a reporting team
actually holds; the last section lists the other clients that work against the
same endpoint, because none of them needed a change on the server to do so.

## The path a query takes

```
Power BI Desktop  (Windows)
      |  HTTPS 443, Basic auth
      v
trino.nopega.net  ->  AWS ALB          TLS terminates here
      |  HTTP, X-Forwarded-*
      v
Trino coordinator  (EKS, namespace data-platform)
      |  password file auth -> file-based access control -> resource groups
      v
Iceberg REST catalog  (Apache Polaris)
      |  vends short-lived, scoped S3 credentials
      v
s3://data-store-prod-warehouse   Iceberg data + metadata
```

Two things worth noticing. Power BI never sees S3, never holds an AWS
credential, and cannot reach the warehouse bucket if it tries — the only thing
it holds is a Trino username and password. And the coordinator runs
`http-server.process-forwarded=true`, which is what lets it trust the ALB's
`X-Forwarded-Proto` header; without it Trino sees plain HTTP, decides password
authentication over an insecure channel is forbidden, and rejects every login
with a message about HTTPS that is confusing when the browser clearly shows a
padlock.

## Before opening Power BI

Get the credential. It is generated once and stored in AWS Secrets Manager; it
is never in git.

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

Then prove the endpoint answers, from any machine:

```bash
curl -s https://trino.nopega.net/v1/info | jq .nodeVersion
```

`/v1/info` is deliberately unauthenticated so load balancers can health-check
it. Everything that reads data is not.

If this step fails, stop here — the problem is DNS, the ALB, or the
certificate, and none of it will be easier to diagnose from inside Power BI.

## Installing the connector

Power BI ships no connector for open-source Trino. The Starburst connector in
the Get Data list is for their commercial product, and their ODBC driver is
licensed to their customers. What works is an MIT-licensed custom connector
that speaks the Trino client REST API directly and supports Basic
authentication — the Power BI side of Trino's `PASSWORD` authentication type.

**The install steps live in
`script/set_up_component/02_trino_prod/install-powerbi-trino-connector.md`**,
written against an actual installation rather than from the connector's README.
They are not repeated here. Two things from it are worth knowing before you
start, because both are silent failures:

**The connector has no HTTPS checkbox.** It picks the scheme from the
authentication kind alone — `Anonymous` maps to `Implicit`, which builds a
`http://` URL, and `Basic` maps to `UsernamePassword`, which builds `https://`.
Choosing Anonymous against this cluster produces

```
Web.Contents failed to get contents from 'http://trino.nopega.net:443/v1/statement' (400)
```

which looks like a server problem and is a radio button. **Always choose
Basic.**

**Unsigned extensions must be allowed explicitly** — File → Options and
settings → Options → Security → Data Extensions → *(Not Recommended) Allow any
extension to load without validation or warning*, then restart. Without it the
connector does not appear in Get Data at all: no warning, no error, just
absent, which reads exactly like a failed download.

That setting is a real trade-off worth stating rather than burying: it applies
to every custom connector on that machine. A production deployment would sign
the `.mez` with an organisation certificate and leave the default in place. For
one analyst workstation the exposure is a single file from a public repository
whose `Trino.pq` can be read in full.

## Connecting

Host `trino.nopega.net`, port `443`, catalog `data_platform`, schema
`gold.aggregate`, table `taxi_daily_zone_revenue`. Leave **User** empty — the
connector fills `X-Trino-User` from the credential itself, and a value typed
here that disagrees with it is a confusing way to fail.

Credential: Basic, `team_b_powerbi`, password from Secrets Manager.

### Why the schema name has a dot in it

Polaris stores namespaces as three levels — medallion / category / domain.
Trino has no nested schemas, so it flattens them into a single name joined by
dots. The schema is therefore *literally called* `gold.aggregate`, and in SQL
it must be quoted as one identifier:

```sql
SELECT * FROM data_platform."gold.aggregate".taxi_daily_zone_revenue
--            \_ catalog _/  \_  schema  _/  \_    table       _/
```

Unquoted, Trino reads it as catalog `data_platform`, schema `gold`, table
`aggregate`, and reports that the table does not exist — which sends you
looking for a missing table rather than a missing pair of quotes.

If the navigator does not show the schema, leave the Schema field empty and let
the connector enumerate the catalog.

## Import, not DirectQuery

Choose **Load**, not DirectQuery. The gold table is built for it:

- **pre-aggregated** — a day is a few hundred rows, so a year is under a
  hundred thousand. That imports in seconds and lives in memory.
- **pre-joined** — the zone lookup is already resolved, so borough and zone
  arrive as plain columns. No relationships to model.
- **pre-computed ratios** — `tip_pct` is stored as a ratio of sums.

DirectQuery would send a fresh SQL statement to Trino on every slicer click,
putting an interactive latency budget on a cluster sized for analytics, and
would consume a slot in the `team_b` resource group each time. Import asks the
cluster one question per refresh.

### One rule for the DAX

Write ratio measures as a ratio of sums:

```
Tip %  =  DIVIDE( SUM(taxi[total_tip]), SUM(taxi[total_fare]) )
```

Never `AVERAGE(taxi[tip_pct])`. Averaging a percentage weights a \$4 trip with
a \$2 tip the same as a \$200 trip with a \$10 tip. The result is wrong in a way
that looks entirely reasonable, which is the worst kind of wrong for a number
someone makes a decision on.

## Refresh

Power BI Desktop refreshes on demand — the data does not change between the
DAG's daily runs anyway, so a manual refresh after 10:00 Asia/Bangkok is
enough.

Publishing to the Power BI Service is where this gets more involved: custom
connectors are not supported by the Service directly and need an **on-premises
data gateway** on a Windows host that can reach `trino.nopega.net`. Power BI
Report Server does not support custom connectors at all.

## What this account is allowed to do

`team_b_powerbi` can read the gold layer and nothing else. The rules live in
`02_trino_prod/chart/trino/values.yaml` under `accessControl`, mounted as a
ConfigMap and re-read every 60 seconds.

```sql
-- works
SELECT * FROM data_platform."gold.aggregate".taxi_daily_zone_revenue LIMIT 5;

-- Access Denied, by design
SELECT * FROM data_platform."bronze.transactional".taxi_trip LIMIT 5;
DROP TABLE data_platform."gold.aggregate".taxi_daily_zone_revenue;
```

Gold is the only layer with a contract. Bronze is a verbatim copy of whatever
the publisher sent; silver's shape changes whenever a cleaning rule changes. A
report built on either would break without anyone having touched the report,
so this restriction protects the dashboard as much as it protects the data.

The navigator will still *list* `bronze.transactional` and `silver.derived`.
Trino filters tables by these rules, not schema names — the schemas appear and
are empty. Hiding the names too would need one catalog per layer, which is a
larger change than a schema name being visible justifies.

The account also lands in the `team_b` resource group, which guarantees it a
scheduling slot even while Team A's 100-query report burst is running. That is
the whole reason resource groups exist here.

## When it does not work

The install guide has the full table; these are the ones that are about the
platform rather than about Power BI.

| What you see | What it is |
|---|---|
| No Trino entry in Get Data | the Data Extensions security setting, or Power BI was not restarted |
| `Web.Contents failed ... 'http://...' (400)` | Anonymous was chosen instead of Basic, so the connector built an http:// URL |
| `Access Denied: Cannot select from table system.jdbc.tables` | login succeeded; `rules.json` is missing the metadata grant, or has not reloaded yet |
| `Access Denied` on a gold table | the access-control ConfigMap has not reloaded yet — it refreshes every 60s |
| `Access Denied` on bronze or silver | working as intended |
| Login rejected, message mentions HTTPS | `http-server.process-forwarded` is not set, so Trino thinks the request arrived over plain HTTP |
| `Table does not exist` for a table you can see | the schema name was not quoted as one identifier |
| Certificate error | the ACM certificate covers `trino.nopega.net`; check the host is spelled exactly that |
| Connects, then times out on a large query | `query.client.timeout` on the coordinator defaults to 5 minutes; a gold-sized import should never approach it, so treat this as a sign the query is not hitting gold |
| `ABANDONED_QUERY` | same cause as above |

## Other clients, same endpoint

Nothing below required a server-side change, which is the practical argument
for having put a query engine in front of the lake rather than handing out
bucket access.

**Trino CLI** — the quickest way to check something without opening a BI tool.

```bash
brew install trino     # or java -jar trino-cli-<version>-executable.jar
trino --server https://trino.nopega.net --user team_b_powerbi --password
```

**DBeaver** — bundles a Trino driver. Host `trino.nopega.net`, port `443`, SSL
on. Useful for browsing the catalog.

**DuckDB** — can skip Trino entirely and attach the Polaris REST catalog
directly, with credential vending:

```sql
INSTALL iceberg; LOAD iceberg;
CREATE SECRET polaris (TYPE ICEBERG, CLIENT_ID '...', CLIENT_SECRET '...');
ATTACH 'data_platform' AS dp (
  TYPE ICEBERG,
  ENDPOINT 'https://<polaris>/api/catalog',
  ACCESS_DELEGATION_MODE 'vended_credentials'
);
```

Worth knowing precisely what that costs: **the access control described above
lives in Trino, not in Polaris.** Any engine that attaches to Polaris directly
is governed only by that Polaris principal's privileges. Handing a DuckDB user
the `etl` principal's credential would give them write access to the entire
catalog and bypass every rule in this document. Doing this properly means a
separate Polaris principal holding read on `gold` only — which is a real piece
of work, not a config line, and is why Trino remains the supported path.

See `queries.sql` in this directory for the SQL Power BI imports and for the
checks that tell you whether a wrong-looking number came from the pipeline or
from the report.
