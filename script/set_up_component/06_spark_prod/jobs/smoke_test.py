"""
End-to-end proof that the platform is wired together.

This is not an ETL job. It exists to fail loudly at the exact point where
something is misconfigured, because every one of these links fails silently or
misleadingly when it is broken:

  1. the image pulled from Harbor has the Iceberg jars in it
  2. the pod received IRSA credentials (not "AccessDenied" three hours in)
  3. Spark can reach Polaris and speak the Iceberg REST protocol
  4. the 3-level namespace really is addressable as one identifier
  5. Spark can WRITE Parquet to the right S3 prefix, and read it back

Run it after any change to the image, the IAM role, or the catalog.

    kubectl apply -f 06_smoke_test.yaml
    kubectl get sparkapplication -n spark -w
"""

import os
import sys

from pyspark.sql import SparkSession

CATALOG = "data_platform"
# Deliberately in bronze/log/query_audit -- the one namespace whose contents
# are expected to be disposable. Writing a smoke-test table into a business
# namespace would leave debris somewhere that matters.
NAMESPACE = "bronze.log.query_audit"

# NO BACKTICKS AROUND THE NAMESPACE.
#
# This read `{CATALOG}.\`{NAMESPACE}\`.smoke_test` and failed with
#
#   NoSuchNamespaceException: Namespace does not exist: bronze.log.query_audit
#
# which is easy to misread as "the namespace was never created". It was.
# Backticks make Spark treat the quoted text as ONE identifier part, so it
# asked Polaris for a single-level namespace literally named
# "bronze.log.query_audit" -- dots included -- rather than for the three-level
# namespace bronze > log > query_audit. Polaris answered accurately.
#
# Spark's multipart identifiers already carry nesting: every dot outside
# backticks is a level boundary. Quoting is only needed for a level whose own
# name contains a dot or a reserved word, which is a good reason not to give
# one such a name.
TABLE = f"{CATALOG}.{NAMESPACE}.smoke_test"


def fail(msg: str) -> None:
    print(f"\nSMOKE TEST FAILED: {msg}\n", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    # ------------------------------------------------------------------
    # Preflight, in the spirit of the missing_vars check in the old
    # run_weekly_data_pipeline.sh: fail before doing work, naming what is
    # missing, rather than dying halfway through with a stack trace.
    # ------------------------------------------------------------------
    required = ["POLARIS_URI", "POLARIS_CREDENTIAL", "WAREHOUSE_BUCKET"]
    missing = [v for v in required if not os.environ.get(v)]
    if missing:
        fail("required environment variables are not set: " + ", ".join(missing))

    print("[1/5] Building the SparkSession...")
    spark = (
        SparkSession.builder.appName("platform-smoke-test")
        # Register the Iceberg catalog. Every one of these lines is load-bearing:
        #   type=rest             -> talk to Polaris over the REST protocol
        #   io-impl=S3FileIO      -> use Iceberg's own S3 client, not Hadoop S3A
        #   oauth2-server-uri     -> Polaris issues its own tokens
        .config(f"spark.sql.catalog.{CATALOG}", "org.apache.iceberg.spark.SparkCatalog")
        .config(f"spark.sql.catalog.{CATALOG}.type", "rest")
        .config(f"spark.sql.catalog.{CATALOG}.uri", os.environ["POLARIS_URI"])
        .config(f"spark.sql.catalog.{CATALOG}.warehouse", CATALOG)
        .config(f"spark.sql.catalog.{CATALOG}.credential", os.environ["POLARIS_CREDENTIAL"])
        .config(f"spark.sql.catalog.{CATALOG}.scope", "PRINCIPAL_ROLE:ALL")
        .config(
            f"spark.sql.catalog.{CATALOG}.io-impl",
            "org.apache.iceberg.aws.s3.S3FileIO",
        )
        .config(
            "spark.sql.extensions",
            "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
        )
        .getOrCreate()
    )
    spark.sparkContext.setLogLevel("WARN")
    print(f"      Spark {spark.version}")

    # ------------------------------------------------------------------
    print("[2/5] Listing namespaces from Polaris...")
    # If the credential or URI is wrong this raises here, before any data is
    # touched -- and the exception names the catalog rather than a table.
    try:
        namespaces = spark.sql(f"SHOW NAMESPACES IN {CATALOG}").collect()
    except Exception as exc:  # noqa: BLE001 - we want the raw message
        fail(f"could not reach Polaris at {os.environ['POLARIS_URI']}: {exc}")
    print(f"      {len(namespaces)} namespaces visible")

    # The 3-level namespace is the design decision most likely to be quietly
    # wrong, because a client that does not support nesting simply does not
    # list it rather than erroring.
    names = {row[0] for row in namespaces}
    if not any(str(n).startswith("bronze") for n in names):
        fail(
            "no 'bronze...' namespace is visible. Either the namespaces were "
            "not created, or this client cannot see nested namespaces."
        )

    # Descend to the actual leaf rather than stopping at the top level.
    #
    # The check above used to be the whole test, and it passed while the write
    # below failed with NoSuchNamespaceException -- because SHOW NAMESPACES
    # returns only the FIRST level. Seeing "bronze" says nothing about whether
    # bronze.log.query_audit exists, so the smoke test reported the catalog
    # healthy right up to the point where it wasn't.
    parent, _, leaf = NAMESPACE.rpartition(".")
    try:
        children = spark.sql(f"SHOW NAMESPACES IN {CATALOG}.{parent}").collect()
    except Exception as exc:  # noqa: BLE001
        fail(f"namespace {CATALOG}.{parent} is not reachable: {exc}")
    leaves = {str(row[0]).rpartition(".")[2] for row in children}
    if leaf not in leaves:
        fail(
            f"namespace {NAMESPACE} does not exist. Under {parent} there is: "
            f"{sorted(leaves) or 'nothing'}.\n"
            f"                  07_create_dg_namespaces_prod.sh creates this tree."
        )
    print(f"      {NAMESPACE} exists")

    # ------------------------------------------------------------------
    print(f"[3/5] Writing {TABLE}...")
    df = spark.createDataFrame(
        [(1, "alpha"), (2, "beta"), (3, "gamma")],
        "id INT, label STRING",
    )
    try:
        df.writeTo(TABLE).createOrReplace()
    except Exception as exc:  # noqa: BLE001
        fail(
            f"write failed. If this says AccessDenied, the pod did not receive "
            f"IRSA credentials or the IAM policy does not cover the prefix: {exc}"
        )
    print("      wrote 3 rows")

    # ------------------------------------------------------------------
    print("[4/5] Reading it back...")
    count = spark.table(TABLE).count()
    if count != 3:
        fail(f"expected 3 rows, read {count}")
    print(f"      read {count} rows")

    # ------------------------------------------------------------------
    print("[5/5] Confirming the data landed in the right S3 prefix...")
    # The path matters as much as the row count: a table written to the wrong
    # prefix still reads back correctly, and only reveals itself months later
    # when a lifecycle rule does not match it.
    location = (
        spark.sql(f"DESCRIBE TABLE EXTENDED {TABLE}")
        .filter("col_name = 'Location'")
        .collect()
    )
    if not location:
        fail("could not read the table's location")
    path = location[0][1]
    print(f"      {path}")

    expected = f"s3://{os.environ['WAREHOUSE_BUCKET']}/bronze/log/query_audit/"
    if not path.startswith(expected):
        fail(
            f"table is at {path}\n"
            f"                  expected it under {expected}\n"
            f"                  The namespace location in Polaris is wrong; S3 "
            f"lifecycle rules key on this prefix and would not match."
        )

    # Left in place on purpose. It is small, it lives in a disposable
    # namespace, and having it there means the next run proves createOrReplace
    # works on an existing table -- a different code path from creating one.
    print("\nSMOKE TEST PASSED -- image, IRSA, Polaris, namespaces and S3 all work.\n")
    spark.stop()


if __name__ == "__main__":
    main()
