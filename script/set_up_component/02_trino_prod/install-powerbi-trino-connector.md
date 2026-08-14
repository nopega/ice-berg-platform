# Installing the Power BI Trino Connector (CreativeDataEU)

Power BI ships no connector for open-source Trino. The Starburst entry in the
Get Data list is for their commercial product, and their ODBC driver is
licensed to their customers. What works is **PowerBITrinoConnector**, an
MIT-licensed custom connector that talks to the Trino client REST API directly
— no ODBC, no JDBC bridge, no Java on the client, no licence fee.

- Repository: <https://github.com/CreativeDataEU/PowerBITrinoConnector>
- Licence: MIT
- Supported mode: **Import only** — it is built on `Web.Contents`, so there is
  no query folding and no DirectQuery. Filter and aggregate on the Trino side.

## Reference environment

The values this guide was written against. Adapting it to another cluster means
changing this table and nothing else.

| Item | Value |
|---|---|
| Trino version | `480` |
| Coordinator | `trino.nopega.net` |
| Protocol / port | HTTPS / `443`, through an AWS ALB |
| Catalog | `data_platform` |
| Schema | `gold.aggregate` — the name contains a dot; see *Selecting data* |
| Table | `taxi_daily_zone_revenue` |
| Authentication | `PASSWORD` (password file, bcrypt) |
| Username | `team_b_powerbi` — reads the gold layer only |
| Password | AWS Secrets Manager → `data-platform-prod-trino-powerbi-password` |
| Client OS | Windows 11 x64 |
| Power BI Desktop | Microsoft Store build |

Retrieve the password on the machine that administers the cluster:

```bash
./02_create_trino_auth_secrets_prod.sh show-powerbi
```

## Prerequisites

| Required | Notes |
|---|---|
| Power BI Desktop, 64-bit | Store or MSI build; the folder path differs — see *Installing the .mez file* |
| Write access to Documents | for the `.mez` |
| Trino reachable over HTTPS with password auth | verify before installing anything |

**Not required:** Java, an ODBC driver, ZappySys, a JDBC jar.

Verify the server first. A failure here is not a Power BI problem and will not
become easier to diagnose from inside Power BI:

```powershell
Invoke-RestMethod https://trino.nopega.net/v1/info
```

`/v1/info` is deliberately unauthenticated so load balancers can health-check
it; everything that reads data is not.

Two server-side settings this connector depends on, both already in place in
this cluster and both worth knowing because their failure modes point
elsewhere:

- **`http-server.process-forwarded=true`** on the coordinator. The ALB
  terminates TLS and forwards over HTTP; without this Trino sees plain HTTP,
  decides password authentication over an insecure channel is forbidden, and
  rejects every login with a message about HTTPS — while the browser shows a
  padlock.
- **bcrypt cost ≥ 8** in the password file. `htpasswd -B` without `-C` produces
  cost 5 and Trino refuses it with
  `HashedPasswordException: Minimum cost of BCrypt password must be 8`,
  surfacing as HTTP 500. `02_create_trino_auth_secrets_prod.sh` uses
  `htpasswd -i -n -B -C 10`.

## Installing the .mez file

The repository publishes no GitHub Releases; the built artefact is committed
into the tree.

Close Power BI Desktop first, then in PowerShell:

```powershell
$docs = [Environment]::GetFolderPath('MyDocuments')
$paths = @(
  (Join-Path $docs 'Microsoft Power BI Desktop\Custom Connectors'),   # Store build
  (Join-Path $docs 'Power BI Desktop\Custom Connectors')              # MSI build
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$url = 'https://raw.githubusercontent.com/CreativeDataEU/PowerBITrinoConnector/master/Trino/bin/AnyCPU/Debug/Trino.mez'

foreach ($p in $paths) {
  New-Item -ItemType Directory -Force -Path $p | Out-Null
  Invoke-WebRequest -Uri $url -OutFile (Join-Path $p 'Trino.mez')
}

Get-ChildItem $paths -Filter Trino.mez | Unblock-File
Get-ChildItem $paths -Filter Trino.mez | Select-Object Directory, Name, Length
```

Expected: `Trino.mez`, **31,345 bytes**, in both folders.

Three details that each cause a silent failure:

- `[Environment]::GetFolderPath('MyDocuments')` rather than a hardcoded
  `C:\Users\<user>\Documents`, because OneDrive Known Folder Move relocates
  Documents and the hardcoded path then points at an empty directory.
- Both paths are written to. The Store build reads
  `Microsoft Power BI Desktop\`, the MSI build reads `Power BI Desktop\`, and
  the wrong one produces a connector that simply never appears.
- `Unblock-File` strips the zone marker Windows attaches to downloads. With the
  marker present Power BI may decline to load the file.

**Pin the version.** Keep a tested `Trino.mez` in an internal artefact store
rather than pulling from GitHub on every install — `master` is not a release
channel.

### Building it yourself

Needed only to modify the connector or to use OAuth:

1. Install Visual Studio Code and the **Power Query SDK** extension.
2. `git clone https://github.com/CreativeDataEU/PowerBITrinoConnector`
3. Open the `Trino` folder — not the repository root, or the SDK will not
   recognise it as a project — and edit `Trino.pq`.
4. Command Palette → **MakePQX: Build** → the new `.mez` appears in
   `Trino/bin/AnyCPU/Debug/`.

## Allowing Power BI to load an unsigned connector

The `.mez` carries no code-signing certificate, and Power BI blocks unsigned
extensions by default.

1. Open Power BI Desktop
2. **File → Options and settings → Options**
3. Left menu, under *GLOBAL* → **Security**
4. Under **Data Extensions**, select
   **(Not Recommended) Allow any extension to load without validation or warning**
5. **OK**
6. **Restart Power BI Desktop** — extensions are loaded at startup only

Check: **Get Data** → search `Trino` → the **Trino** entry appears.

Until this is done the connector does not show up at all. No warning, no error,
just absent — which reads exactly like a failed download and sends you back to
the previous section for no reason.

The setting applies to every custom connector on that machine, not only this
one. A production deployment would sign the `.mez` with an organisation
certificate and leave the default in place. For a single analyst workstation
the exposure is one file from a public repository whose `Trino.pq` can be read
in full.

## Connecting

**Get Data → Trino**, then:

| Field | Value | Notes |
|---|---|---|
| **Host** | `trino.nopega.net` | hostname only — **do not include `https://`** |
| **Port** | `443` | the connector suggests 8080 (http) / 8443 (https); this cluster is behind an ALB, so 443 |
| **Catalog** | `data_platform` | blank shows every catalog the user may access, which for `team_b_powerbi` is `data_platform` and `system` |
| **User** | *(leave empty)* | see below |
| **Timeout** | *(leave empty)* | defaults to 100 seconds |
| **Target result size** | *(leave empty)* | defaults to 1 MB per request, maximum 128 |
| **SQL Query** | *(leave empty)* | empty gives the Navigator; a query fetches that result directly |

**Leave User empty.** In the connector's source, when `User` is null and the
authentication kind is `UsernamePassword`, it fills the `X-Trino-User` header
from the credential itself. A value typed here that disagrees with the
credential is a confusing way to fail.

### Choose Basic — the most important step in this guide

The credential dialog offers **Anonymous**, **Basic** and **Organizational
account**. The connector has **no HTTPS or SSL checkbox**: it derives the
scheme from the authentication kind alone (`Trino.pq`, line 77):

```m
Http = if (Extension.CurrentCredential()[AuthenticationKind]?) = "Implicit"
       then "http://" else "https://";
```

| Tab | AuthenticationKind | Resulting URL |
|---|---|---|
| Anonymous | `Implicit` | `http://` — wrong |
| **Basic** | `UsernamePassword` | `https://` — correct |
| Organizational account | `OAuth` | `https://` |

Choosing Anonymous against an HTTPS server produces:

```
DataSource.Error: Web.Contents failed to get contents from
'http://trino.nopega.net:443/v1/statement' (400): Bad Request
```

That looks like a server fault and is a radio button.

In the **Basic** tab enter `team_b_powerbi` and the password from Secrets
Manager, then **Connect**.

## Selecting data

The Navigator shows catalog → schema → table. Choose
`data_platform` → `gold.aggregate` → `taxi_daily_zone_revenue`, then **Load**.

### The schema name contains a dot

Polaris stores namespaces as three levels — medallion / category / domain.
Trino has no nested schemas, so it flattens them into a single name joined by
dots. The schema is therefore *literally named* `gold.aggregate`; it is not a
schema `gold` containing something called `aggregate`.

The Navigator handles this without any escaping. The **SQL Query** box does
not — there the name must be quoted as one identifier:

```sql
SELECT * FROM data_platform."gold.aggregate".taxi_daily_zone_revenue
--            \_ catalog _/  \_  schema  _/  \_    table       _/
```

Unquoted, Trino reads catalog `data_platform`, schema `gold`, table
`aggregate`, and answers that the table does not exist — which sends you
hunting for a missing table instead of a missing pair of quotes.

### What this account may read

Since file-based access control was enabled
(`chart/trino/values.yaml` → `accessControl`), `team_b_powerbi` can read only
schemas beginning with `gold`.

| | `team_b_powerbi` | `etl_setup` |
|---|---|---|
| `gold.*` | SELECT | full |
| `silver.*`, `bronze.*` | denied | full |
| write / DDL | denied | allowed |
| `system.runtime` (other users' SQL) | denied | allowed |

The reason is not only security. Gold is the only layer with a contract:
bronze is a verbatim copy of whatever the publisher sent, and silver's shape
changes whenever a cleaning rule changes. A report built on either would break
without anyone having touched the report.

**Visible but unreadable.** The Navigator still lists `bronze.transactional`
and `silver.derived`, including the table names inside them, because Trino does
not apply table rules when filtering `system.jdbc.tables`
([trinodb/trino#20864](https://github.com/trinodb/trino/issues/20864)) — which
is what clients read to draw the tree. Every `SELECT` against them is denied.
Hiding the names too would mean one catalog per medallion layer, since catalog
rules *are* enforced in that path.

If a gold table returns `Access Denied`, the rules ConfigMap has not reloaded
yet; Trino re-reads it every 60 seconds.

### Import, and what follows from it

**Load**, not Transform-then-DirectQuery — the connector supports Import only,
and the gold table is built for it: a day is a few hundred rows, pre-aggregated
to zone × payment method, with the zone lookup already joined so no
relationships need modelling.

One rule for the measures. Write ratios as a ratio of sums:

```
Tip % = DIVIDE( SUM(taxi[total_tip]), SUM(taxi[total_fare]) )
```

Never `AVERAGE(taxi[tip_pct])`. Averaging a percentage weights a $4 trip with a
$2 tip the same as a $200 trip with a $10 tip, and produces a number that is
wrong while looking entirely plausible.

For a large result, raise **Timeout** and **Target result size**, or push a
`LIMIT` or a `trip_date` predicate into the SQL Query box. `trip_date` is the
partition column, so Iceberg prunes whole files; a predicate on any other
column reads everything and then discards it.

## Clearing saved credentials

Needed after choosing the wrong authentication tab, or after the password is
rotated. Power BI caches the credential and will not ask again.

1. **File → Options and settings → Data source settings**
2. Select **Global permissions** at the top — *not* "Data sources in current
   file". Connector credentials are stored globally, and the dialog opens on
   the other tab, which is why people conclude the entry is missing.
3. Select the `Trino` / `trino.nopega.net` row → **Clear Permissions** →
   **Delete**
4. **Close**, then connect again

## References

- [CreativeDataEU/PowerBITrinoConnector](https://github.com/CreativeDataEU/PowerBITrinoConnector)
- [Microsoft Learn — Connector extensibility in Power BI](https://learn.microsoft.com/en-us/power-bi/connect-data/desktop-connector-extensibility)
- [Trino — File-based authentication](https://trino.io/docs/current/security/password-file.html)
- [Trino — File-based access control](https://trino.io/docs/current/security/file-system-access-control.html)
- [Trino — JDBC driver](https://trino.io/docs/current/client/jdbc.html)
- [Trino releases](https://github.com/trinodb/trino/releases)
- `CONNECT_DBEAVER.md` in this directory — the same endpoint from a client that
  runs on macOS, and the quickest way to tell a server problem from a Power BI
  problem
- `docs/powerbi/queries.sql` — the SQL Power BI imports, and the checks that
  say whether a wrong-looking number came from the pipeline or the report
