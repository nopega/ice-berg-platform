# Component install order (prod)

Run in numeric order. The numbering is a dependency order, not a preference —
each step below either needs something the previous one created, or exists so
the next one does not have to work around its absence.

| # | Folder | Depends on the previous step for |
|---|---|---|
| 01 | `01_iceberg_catalog_and_polaris_prod` | — (needs only the cluster, IRSA role and RDS from `set_up_cluster/`) |
| 02 | `02_trino_prod` | the Polaris catalog to point at, and the `data-platform-workload` ServiceAccount created in 01 |
| 03 | `03_cloudflared_prod` | nothing technically — placed here because everything after it assumes external access exists |
| 04 | `04_airflow_prod` | a way to reach its UI (03), and the `airflow` database in RDS |
| 05 | `05_harbor_prod` | a default StorageClass, the S3 gateway VPC endpoint, and cloudflared (03) to reach it |
| 06 | `06_spark_prod` | Airflow to submit `SparkApplication` resources, and Harbor (05) holding the job image |
| 07 | `07_argocd_prod` | everything above, since it takes over reconciling what those steps installed |

## Why cloudflared is 03 and not last

It was originally numbered 06, after Airflow and Spark, and that ordering was
wrong in a way worth recording rather than quietly renumbering.

cloudflared is not an application like Trino or Airflow. It is a **cluster
capability**, in the same category as the IRSA role or a StorageClass:
something every later component uses rather than something that stands on its
own. Installing it after the components that need it meant each of those
components had to invent its own way of being reachable — which is exactly what
happened. Polaris, Trino and Airflow each grew a `port-forward` / `ui` /
`tunnel` mode in their install scripts, and the hand-rolled tunnel management
in `01_iceberg_catalog_and_polaris_prod/05_create_catalog_prod.sh` was one of
the more time-consuming things to get right in this project.

With cloudflared in place first, "how do I reach this" has one answer for every
component that follows.

## What deliberately does NOT go through the tunnel

Not everything should be externally reachable, and being able to expose
something cheaply is not a reason to.

- **Polaris management API** — creates catalogs, principals and grants. An admin
  API with that reach stays internal; `port-forward` is the correct access
  method for it even though it is less convenient.
- **Trino coordinator** — reachable in-cluster by Airflow and Spark. A UI could
  be exposed later behind Cloudflare Access if people need it; nothing needs it
  today.

Exposed through the tunnel: the Airflow UI, and Harbor once it exists. Both are
things humans use daily, and both sit behind Cloudflare Access rather than only
their own login form.

## Argo CD at 99

Argo CD reconciles the cluster against git, so it has to come after the things
it will reconcile — otherwise it starts by trying to prune resources it does not
yet know about. It is numbered 99 rather than 06 to make clear it is the last
step of the sequence and not simply the next one.

Note that Argo CD is installed but the components above are still applied by
their own scripts; moving them under Argo CD is a separate migration, described
in `docs/STACK_SUMMARY.md`.
