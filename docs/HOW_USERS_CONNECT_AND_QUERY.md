# How users connect and query the data

> *"Please demonstrate how users will connect and query the data from your data
> platform."* — Constraint 4
>
> *"Guidelines on how users can connect to your platform and query the data."*
> — Deliverable 4

One endpoint, one credential, several clients. Nothing below required a change
on the server to work — which is the practical argument for having put a query
engine in front of the lake rather than handing out bucket access.

## The one thing to know first

```
your client
     │  HTTPS 443, username + password
     ▼
trino.nopega.net ──▶ AWS ALB              TLS terminates here
     │  HTTP, X-Forwarded-*
     ▼
Trino coordinator                          password file → access rules → resource groups
     │  Iceberg REST protocol
     ▼
Apache Polaris (catalog)                   vends short-lived, scoped S3 credentials
     │
     ▼
s3://data-store-prod-warehouse             Parquet + Iceberg metadata
```

**A client never sees S3, never holds an AWS credential, and cannot reach the
warehouse bucket if it tries.** All it holds is a Trino username and password.
Authorisation, resource limits and audit all sit at the same choke point.

## Getting a credential

Generated once, stored in AWS Secrets Manager, never in git:

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

Two accounts exist, and the split is deliberate:

| Account | Reads | Writes | Intended for |
|---|---|---|---|
| `team_b_powerbi` | `gold.*` only | nothing | BI tools, dashboards — the credential that leaves the cluster |
| `etl_setup` | everything | everything | a terminal, when investigating |

Use `show-etl` for the second. Do not put it in a tool other people use.

**Why the BI account cannot read bronze or silver.** Gold is the only layer
with a contract. Bronze is a verbatim copy of whatever the publisher sent, and
silver's shape changes whenever a cleaning rule changes — a report built on
either would break without anyone having touched the report. The restriction
protects the dashboard as much as it protects the data.

## Prove the endpoint before opening any client

```bash
curl -s https://trino.nopega.net/v1/info | jq .nodeVersion
```

`/v1/info` is unauthenticated on purpose so load balancers can health-check it.
Everything that reads data is not.

If this fails, stop here — the problem is DNS, the ALB or the certificate, and
none of it gets easier to diagnose from inside a BI tool.

If it fails with a **timeout**, the most likely cause is the ALB's source-IP
allowlist: your address is not on it, or a home connection changed address. See
`NETWORK-PLANE.md`.

## Naming: the part that trips everyone once

```sql
SELECT * FROM data_platform."gold.aggregate".taxi_daily_zone_revenue
--            \_ catalog _/  \_  schema  _/  \_    table       _/
```

Polaris stores namespaces as three levels — medallion / category / domain.
Trino has no nested schemas, so it flattens them into a single name joined by
dots. **The schema is literally called `gold.aggregate`** and must be quoted as
one identifier.

Written unquoted, Trino reads it as catalog `data_platform`, schema `gold`,
table `aggregate`, and answers that the table does not exist — which sends
people hunting for a missing table instead of a missing pair of quotes.

Start here:

```sql
SHOW SCHEMAS FROM data_platform;
SHOW TABLES  FROM data_platform."gold.aggregate";

SELECT trip_date,
       sum(trip_count)              AS trips,
       round(sum(total_revenue), 2) AS revenue
FROM data_platform."gold.aggregate".taxi_daily_zone_revenue
GROUP BY trip_date
ORDER BY trip_date;
```

More, including the queries that tell you whether a wrong-looking number came
from the pipeline or from the report: **`docs/powerbi/queries.sql`**.

## Choosing a client

| Client | Best for | Runs on | Guide |
|---|---|---|---|
| **Power BI** | dashboards for a reporting team | Windows only | [`docs/powerbi/README.md`](powerbi/README.md) |
| **DBeaver** | exploring, writing SQL, diagnosing | macOS, Windows, Linux | [`02_trino_prod/CONNECT_DBEAVER.md`](../script/set_up_component/02_trino_prod/CONNECT_DBEAVER.md) |
| **Trino CLI** | one-off checks, scripting | anywhere with Java | below |
| **DuckDB** | local analysis straight off Iceberg | anywhere | below, with a caveat |

**Start with DBeaver even if the goal is Power BI.** It runs everywhere,
connects in two minutes, and proves the endpoint, the certificate, the
credential and the access rules in one go. If DBeaver works and Power BI does
not, the problem is in Power BI — which is a much smaller thing to debug.

### Power BI — the reporting path

Power BI ships no connector for open-source Trino: the Starburst entry in Get
Data is for their commercial product, and their ODBC driver is licensed to
their customers. The working route is an MIT-licensed custom connector that
speaks the Trino REST API directly.

Two things from that guide are worth knowing before starting, because both fail
silently:

- **The connector has no HTTPS checkbox.** It picks the scheme from the
  authentication kind alone — `Anonymous` builds an `http://` URL, `Basic`
  builds `https://`. Choosing Anonymous produces a 400 that looks like a server
  fault and is a radio button. **Always choose Basic.**
- **Unsigned extensions must be allowed explicitly** in Options → Security →
  Data Extensions, then Power BI restarted. Without it the connector does not
  appear in Get Data at all — no warning, no error, just absent.

Use **Import**, not DirectQuery. The gold table is built for it: pre-aggregated
to a few hundred rows a day, pre-joined so no relationships need modelling, and
with ratios pre-computed.

One rule for the measures — write ratios as a ratio of sums:

```
Tip %  =  DIVIDE( SUM(taxi[total_tip]), SUM(taxi[total_fare]) )
```

Never `AVERAGE(taxi[tip_pct])`. Averaging a percentage lets a $4 trip with a $2
tip count as much as a $200 trip with a $10 tip, and the result is wrong in a
way that looks entirely reasonable.

### DBeaver — the diagnostic path

The Trino driver ships with DBeaver; it downloads the JDBC jar on first
connect.

Host `trino.nopega.net`, port `443`, database `data_platform`, then the
credential. **And one thing in the Driver properties tab that is not
optional:** set `SSL` to `true`.

The Trino JDBC driver does not infer TLS from the port number. Port 443 alone
sends plain HTTP into a TLS listener and fails as `Unexpected end of file` or a
bare `Error executing query` — nothing that mentions SSL, so it reads like a
broken credential.

The URL must end up as:

```
jdbc:trino://trino.nopega.net:443/data_platform?SSL=true
```

### Trino CLI

```bash
brew install trino
trino --server https://trino.nopega.net --user team_b_powerbi --password
```

`--password` prompts without echoing.

### DuckDB — and the caveat that matters

DuckDB can skip Trino entirely and attach the Polaris REST catalog directly,
with credential vending:

```sql
INSTALL iceberg; LOAD iceberg;
CREATE SECRET polaris (TYPE ICEBERG, CLIENT_ID '...', CLIENT_SECRET '...');
ATTACH 'data_platform' AS dp (
  TYPE ICEBERG,
  ENDPOINT 'https://<polaris>/api/catalog',
  ACCESS_DELEGATION_MODE 'vended_credentials'
);
```

That this works at all is the point of choosing Iceberg with a REST catalog:
another engine can read the same tables without moving the data.

**But know exactly what it costs.** The access control described in this
document lives in **Trino**, not in Polaris. Any engine attaching to Polaris
directly is governed only by that Polaris principal's privileges. Handing a
DuckDB user the `etl` principal's credential would give them write access to
the entire catalog and bypass every rule here.

Doing it properly means a separate Polaris principal holding read on `gold`
only — real work, not a config line, which is why Trino remains the supported
path.

## What each account can and cannot do

Verify it in one go. The first must return a number, the second must fail:

```sql
SELECT count(*) FROM data_platform."gold.aggregate".taxi_daily_zone_revenue;
SELECT count(*) FROM data_platform."bronze.transactional".taxi_trip;
```

`Access Denied` on the second is the platform working, not a broken connection.

The rules live in `02_trino_prod/chart/trino/values.yaml` under `accessControl`,
mounted as a ConfigMap and re-read every 60 seconds — so a change is a values
edit and a minute, not a restart.

**One thing the navigator will show that it should not.** `bronze.transactional`
and `silver.derived` still appear in the tree, including table names, because
Trino does not apply table rules when filtering `system.jdbc.tables`
([trinodb/trino#20864](https://github.com/trinodb/trino/issues/20864)) — which
is what clients read to draw the tree. Nothing can be read from them. Hiding
the names too would need one catalog per medallion layer.

## Sharing fairly: what happens under load

The brief describes two teams with opposite query patterns — Team A sending
~100 report queries in a burst at 10am, Team B needing fast answers to small
queries all day. Left alone, Trino runs queries first-come-first-served, so
Team B's 3-second query waits behind 90 report queries. That is not competing
for a fair share; it is one team blocking the other.

Two mechanisms handle it, and they are independent:

**Resource groups** route by username. `team_*` users land in their own group
with its own concurrency limit and memory ceiling, scheduled `weighted_fair` —
so Team B gets a slot *soon*, not merely a fair share on average. Anything
unmatched lands in a deliberately tiny `other` group: an unknown user cannot
take the cluster.

**The HPA** adds Trino workers, 2 to 5, when CPU or memory crosses a threshold —
so the burst finishes sooner rather than merely being queued politely. See
`AUTOSCALING.md`.

Concurrency limits are lower than instinct suggests, and the arithmetic is in
`values.yaml`: two workers at 3G heap leave ~4.2G of usable pool, so 12
concurrent queries get ~350MB each and spill to disk, while 6 get ~700MB and do
not. Six finishing quickly beats twelve running slowly.

## When something does not work

| Symptom | Cause |
|---|---|
| connection times out | your IP is not on the ALB allowlist, or it changed |
| `Unexpected end of file` / bare error on connect (JDBC) | `SSL=true` not set |
| `Web.Contents failed ... 'http://...' (400)` (Power BI) | Anonymous chosen instead of Basic |
| login rejected, message mentions HTTPS | `http-server.process-forwarded` missing on the coordinator |
| `Access Denied: Cannot select from table system.jdbc.tables` | login fine; `rules.json` missing the metadata grant, or the ConfigMap has not reloaded |
| `Access Denied` on bronze or silver | working as intended |
| `Table does not exist` for a table visible in the tree | the dotted schema name was not quoted as one identifier |
| certificate warning | the ACM certificate covers `trino.nopega.net` exactly — check the spelling, and that the DNS record is **DNS only**, not proxied |
| query times out on a large scan | `query.client.timeout` defaults to 5 minutes; a gold-sized query should never approach it, so treat this as a sign the query is not hitting gold |

## Related

| Document | Covers |
|---|---|
| `docs/powerbi/README.md` | the full Power BI path, install to refresh |
| `02_trino_prod/CONNECT_DBEAVER.md` | DBeaver, step by step |
| `02_trino_prod/install-powerbi-trino-connector.md` | installing the connector, written against a real installation |
| `docs/powerbi/queries.sql` | the SQL Power BI imports, plus reconciliation checks |
| `docs/DATA_MODEL.md` | what the tables mean and how to trace a number to its source |
| `docs/SECURITY_GOVERNANCE.md` | what is enforced, and what is not |
