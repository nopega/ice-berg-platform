# Spark image for this platform's ETL jobs.
#
# WHY BUILD ONE AT ALL, RATHER THAN --packages AT RUNTIME
# ---------------------------------------------------------
# `--packages org.apache.iceberg:...` makes Spark resolve and download the
# dependency tree from Maven Central when the job starts. That works, and it
# is wrong here for three reasons:
#
#   1. Every executor does it. A job with fifty executors downloads the same
#      jars fifty times, adding a minute of startup each, over a NAT gateway
#      that bills per GB.
#   2. Maven Central becomes a dependency of every production run. When it is
#      slow or unreachable, the ETL does not run.
#   3. Nothing pins what was resolved. The same DAG can silently pick up a
#      different transitive dependency next month.
#
# Baked in, the jars are part of an image with a tag, scanned by Trivy on push,
# and pulled from Harbor inside the VPC.
#
# BUILD FOR linux/amd64 EXPLICITLY
# ---------------------------------
# The nodes are x86. Building on Apple Silicon without --platform produces an
# arm64 image whose pods crash with "exec format error" -- a message that says
# nothing about architecture. 03_build_and_push_image_prod.sh passes the flag.

# The plain tag, with the Python interpreter installed explicitly below.
#
# Apache also publishes a `-python3` variant. Its ENTIRE Dockerfile is:
#
#     FROM spark:4.0.1-scala2.13-java21-ubuntu
#     USER root
#     RUN apt-get install -y python3 python3-pip
#     USER spark
#
# So the variant buys nothing this file does not already do, and it does NOT
# set PYTHONPATH either -- see the ENV block further down. Using the plain tag
# keeps the Python layer (version, ipython, future libraries) under our
# control rather than inheriting whatever the variant happened to choose.
FROM apache/spark:4.0.1

# Versions are pinned rather than floating.
#
# ICEBERG_VERSION is the Iceberg release. The `4.0_2.13` in the artifact name
# is the SPARK and SCALA version it was compiled against, and it must match
# the base image exactly. A mismatch does not fail the build -- it fails at
# class-load time inside a running job with NoSuchMethodError, which points at
# a method rather than at a version and wastes an afternoon.
#
# Confirmed present on Maven Central for 4.0_2.13: 1.10.0, 1.10.1, 1.10.2,
# 1.11.0. Using the current release.
ARG ICEBERG_VERSION=1.11.0
ARG SPARK_MAJOR=4.0
ARG SCALA_VERSION=2.13
# hadoop-aws MUST match the Hadoop version bundled inside this Spark image
# exactly. Spark 4.0 ships Hadoop 3.4.x; a mismatched hadoop-aws throws
# NoSuchMethodError deep inside S3AFileSystem at first read. The RUN step below
# asserts the match at BUILD time rather than letting a job discover it.
ARG HADOOP_AWS_VERSION=3.4.1

# The AWS SDK v2 version hadoop-aws 3.4.1 was compiled against. Newer v2
# releases are generally source-compatible, but "generally" is not a property
# worth relying on for the client that writes every byte of the lakehouse.
#
# Every download below uses `curl -f`, so a version that does not exist on
# Maven Central fails the build immediately with a 404 rather than producing
# an image missing a jar.
ARG AWS_SDK_VERSION=2.24.6

# py4j is the Python<->JVM bridge PySpark imports. It ships inside the Spark
# distribution as a zip, NOT as a pip package, and the version is fixed by the
# Spark release -- Spark 4.0.1's own bin/pyspark hardcodes:
#
#     export PYTHONPATH="${SPARK_HOME}/python/lib/py4j-0.10.9.9-src.zip:..."
#
# Asserted at build time below, because a wrong path here is not an error:
# Python skips missing sys.path entries silently, and the failure surfaces
# later as "No module named 'py4j'" inside a running job.
ARG PY4J_VERSION=0.10.9.9

USER root

# Copied before the RUN so this layer is cached and only rebuilt when the pins
# actually change -- not on every edit to the ETL code below.
COPY requirements.txt /tmp/requirements.txt

# Python runtime. The PySpark FILES already ship with the base image, at
# /opt/spark/python/pyspark/ and /opt/spark/python/lib/py4j-*-src.zip. What the
# base image lacks is (a) an interpreter and (b) a PYTHONPATH -- see the ENV
# block below. This comment previously claimed PySpark was already importable;
# it is not, and that cost a build cycle.
#
# ON PINNING apt PACKAGES
# ------------------------
# The apt packages below are NOT pinned to a version, and that is a deliberate
# difference from everything else in this file. `python3` from Ubuntu is a
# metapackage whose exact version is fixed by the base image's OS release --
# which IS pinned, by `FROM apache/spark:4.0.1`. Writing
# `python3=3.12.3-0ubuntu2` here would add a second thing to keep in sync with
# no extra determinism, and would break the build the day Apache rebuilds the
# base on a patched Ubuntu.
#
# Everything installed by pip is pinned exactly in requirements.txt -- see that
# file for what each package is for and why it is kept separate.
#
# No --break-system-packages here. That flag arrived in pip 23 and this base
# image (Ubuntu 22.04) ships pip 22.0.2, which rejects it outright with
# "no such option". It is also unnecessary: PEP 668's externally-managed
# marker, which the flag exists to override, is not present on 22.04. If the
# base image ever moves to 24.04, pip will refuse to install and the flag
# becomes required -- at which point the error message says so explicitly.
RUN set -eux; \
    apt-get update; \
    \
    # Patch the OS packages the base image was built with. Apache rebuilds
    # apache/spark on its own schedule, so by the time a tag is pulled its
    # Ubuntu layer is usually months behind on security updates.
    #
    # This is worth doing even though it does not come close to clearing the
    # image: the first scan of this image found 4694 vulnerabilities, and the
    # large majority are inside the JARs the Spark distribution ships, which
    # apt cannot touch. What it does fix is the OS half, for free, on every
    # rebuild.
    #
    # `upgrade`, not `dist-upgrade`: dist-upgrade is allowed to remove packages
    # to resolve dependencies, and a base image quietly losing a package it
    # shipped with is a worse failure than an unpatched one.
    apt-get upgrade -y --no-install-recommends; \
    \
    apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv curl ca-certificates; \
    ln -sf /usr/bin/python3 /usr/bin/python; \
    pip3 install --no-cache-dir -r /tmp/requirements.txt; \
    rm -f /tmp/requirements.txt; \
    \
    cd /opt/spark/jars; \
    \
    # Assert the bundled Hadoop matches HADOOP_AWS_VERSION before downloading
    # anything. The image ships hadoop-client-api-<version>.jar, so the version
    # is readable from the filename.
    bundled="$(ls hadoop-client-api-*.jar | sed 's/hadoop-client-api-//; s/\.jar//')"; \
    if [ "$bundled" != "${HADOOP_AWS_VERSION}" ]; then \
        echo "FATAL: image bundles Hadoop ${bundled} but HADOOP_AWS_VERSION is ${HADOOP_AWS_VERSION}." >&2; \
        echo "       Set --build-arg HADOOP_AWS_VERSION=${bundled} and rebuild." >&2; \
        exit 1; \
    fi; \
    \
    # Iceberg's Spark runtime: the connector itself, plus the catalog client
    # that speaks the Iceberg REST protocol to Polaris.
    curl -fsSLO "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-spark-runtime-${SPARK_MAJOR}_${SCALA_VERSION}/${ICEBERG_VERSION}/iceberg-spark-runtime-${SPARK_MAJOR}_${SCALA_VERSION}-${ICEBERG_VERSION}.jar"; \
    \
    # Iceberg's AWS bundle. Contains the S3FileIO implementation Iceberg uses
    # for table data -- this is NOT the same path as hadoop-aws, and omitting
    # it makes Iceberg fall back to the Hadoop S3A client, which is slower and
    # does not support Polaris credential vending.
    curl -fsSLO "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-aws-bundle/${ICEBERG_VERSION}/iceberg-aws-bundle-${ICEBERG_VERSION}.jar"; \
    \
    # hadoop-aws + the AWS SDK v2 bundle, for reading NON-Iceberg data from S3
    # (the raw NYC TLC Parquet files, before they become a bronze table).
    # Iceberg's own bundle does not cover that path.
    curl -fsSLO "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VERSION}/hadoop-aws-${HADOOP_AWS_VERSION}.jar"; \
    curl -fsSLO "https://repo1.maven.org/maven2/software/amazon/awssdk/bundle/${AWS_SDK_VERSION}/bundle-${AWS_SDK_VERSION}.jar"; \
    \
    apt-get purge -y --auto-remove curl; \
    rm -rf /var/lib/apt/lists/*; \
    chmod 644 /opt/spark/jars/*.jar

# Point Spark at the interpreter explicitly. Without this the driver and the
# executors can disagree about which python to use, and PySpark aborts with
# "Python in worker has different version than that in driver" -- an error
# that names versions rather than the missing setting.
ENV PYSPARK_PYTHON=/usr/bin/python3 \
    PYSPARK_DRIVER_PYTHON=/usr/bin/python3

# Make `import pyspark` work for a BARE python3, not just under spark-submit.
#
# spark-submit does not need this: PythonRunner builds a PYTHONPATH for the
# process it spawns, which is why jobs run fine without it. Every other way of
# touching Python in this image does need it --
#
#   kubectl exec -it <pod> -- ipython     # the whole reason ipython is installed
#   python3 -c "import pyspark"           # the build-time assertion at the bottom
#   any helper script invoked directly rather than submitted
#
# -- and all of them fail with ModuleNotFoundError while the platform is
# actually fine, which is a confusing place to start debugging from.
#
# Spark PREPENDS to whatever PYTHONPATH already exists, so setting it here does
# not conflict with what spark-submit does at runtime.
ENV PYTHONPATH=/opt/spark/python:/opt/spark/python/lib/py4j-${PY4J_VERSION}-src.zip

# The ETL code. Copied in rather than fetched at runtime so that an image tag
# identifies exactly one version of the logic as well as the dependencies.
#
# The chmod is not cosmetic. COPY preserves the mode of the file in the build
# context, and an editor or a strict umask on the build machine can leave a
# source file at 0600. COPY then makes it root-owned and unreadable, and the
# container -- which runs as the unprivileged `spark` user -- fails at startup
# with:
#
#   /usr/bin/python3: can't open file '/opt/spark/jobs/smoke_test.py':
#   [Errno 13] Permission denied
#
# That happened here, and the tell is that it depends on whose machine built
# the image rather than on anything in this repository. Normalising the mode
# inside the build makes the image identical regardless.
COPY jobs/ /opt/spark/jobs/
RUN chmod -R a+rX /opt/spark/jobs

# Back to the unprivileged user the base image defines. Spark does not need
# root, and the Trivy policy on the Harbor project would flag an image that
# runs as it.
USER spark

# Sanity: fail the BUILD if a jar is missing, rather than discovering it when
# a job fails at 3am. This runs during build, not at container start.
RUN set -eux; \
    ls /opt/spark/jars/iceberg-spark-runtime-*.jar; \
    ls /opt/spark/jars/iceberg-aws-bundle-*.jar; \
    ls /opt/spark/jars/hadoop-aws-*.jar; \
    python3 --version; \
    ipython --version; \
    \
    # PYTHONPATH points at this exact filename. Check it rather than trusting
    # the ARG: a missing sys.path entry is ignored silently by Python.
    if [ ! -f "/opt/spark/python/lib/py4j-${PY4J_VERSION}-src.zip" ]; then \
        echo "FATAL: py4j-${PY4J_VERSION}-src.zip not found. Present:" >&2; \
        ls /opt/spark/python/lib/ >&2; \
        echo "       Set --build-arg PY4J_VERSION=<the version above>." >&2; \
        exit 1; \
    fi; \
    \
    # py4j alongside pyspark: importing pyspark alone succeeds even when the
    # bridge zip is unreachable, and the job then dies at SparkContext setup.
    python3 -c "import pyspark, py4j; print('pyspark', pyspark.__version__, '/ py4j ok')"
