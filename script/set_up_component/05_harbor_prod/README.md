# Harbor — the platform's own container registry

Stores the images the platform runs: the Spark ETL job image, and anything
else built rather than pulled from a public registry.

---

## Why a registry at all

The Spark jobs need Iceberg's runtime jars, the AWS S3 bundle and the platform's
own ETL code. There are two ways to get them into an executor:

| | `--packages` at runtime | An image with them baked in |
|---|---|---|
| First run | works | works |
| Every subsequent run | re-downloads from Maven Central | already present |
| Maven Central unreachable | job fails | unaffected |
| A dependency's version silently changes upstream | job behaviour changes | unaffected |
| Executor start time | seconds of downloading, per executor | pull once per node |

At the scale this platform targets, a job launching fifty executors that each
resolve the same dependency tree over the internet is both slow and a genuine
availability risk on someone else's infrastructure.

Harbor adds three things a plain registry does not:

- **Trivy scanning on push**, with a project policy that can refuse to serve an
  image above a severity threshold — so a vulnerable image cannot be deployed
  rather than merely being reported after the fact
- **Project-level RBAC and robot accounts**, so CI can push without holding a
  human's credentials
- **Retention rules**, which is what keeps blob storage from growing forever

---

## What is unusual about this deployment

**Image layers live in S3, not on a volume.** The chart's default is a PVC.
That default fails badly here: an EBS volume is ReadWriteOnce, so the registry
cannot scale past one replica, and a rolling update leaves a window with no
node able to serve a pull. It is also a fixed size that fills silently.
`s3://data-store-prod-registry` has none of those properties and costs roughly
a tenth as much per GB.

**Its Postgres is a pod, not the shared RDS.** RDS here is a `db.t4g.micro`
already serving Polaris's catalog and Airflow's metadata — both on the critical
path of every query and every DAG run. Trivy's scan results are write-heavy and
have no business sharing that instance. The trade is that Harbor's database has
no managed backups; that is acceptable because its contents are rebuildable
(images are in S3, scans can be re-run) and it is stated here rather than
discovered later.

**It is the one hostname on the Cloudflare tunnel without Access in front.**
Explained under step 5.

---

## Prerequisites

| Needs | Why | Check |
|---|---|---|
| A default StorageClass | four PVCs, all Pending without one | `kubectl get storageclass` |
| ≥3 `workload=critical` nodes | Harbor adds ~900m CPU / ~2.1Gi of requests | `kubectl get nodes -l workload=critical` |
| The S3 gateway VPC endpoint | otherwise every image pull is billed through the NAT gateway | `set_up_cluster/07_vpc_endpoints_prod/… verify` |
| cloudflared running | how the registry is reached from outside | `kubectl get pods -n cloudflared` |
| `helm`, `kubectl`, `aws`, `docker` | — | — |

---

## Setup

### 1. Vendor the chart

Run once and commit the result, so the deployment does not depend on a remote
repository still serving that version later.

```bash
helm repo add harbor https://helm.goharbor.io
helm repo update
helm pull harbor/harbor --version 1.19.1 --untar --untardir ./chart
```

### 2. Bucket and IAM user

```bash
./00_create_harbor_bucket_and_iam_prod.sh
```

Creates `s3://data-store-prod-registry` (blocked from public access, encrypted,
with a lifecycle rule that only aborts stale multipart uploads) and an IAM user
scoped to that one bucket.

**Why a user and not IRSA — this is the one thing to read before changing
anything here.** Harbor 2.15.1 bundles distribution 2.8.x, whose S3 driver does
not use the AWS SDK's default credential chain. It hardcodes its own:

```go
credentials.NewChainCredentials([]credentials.Provider{
    &credentials.StaticProvider{...},          // accesskey/secretkey
    &credentials.EnvProvider{},                // AWS_ACCESS_KEY_ID/...
    &credentials.SharedCredentialsProvider{},  // ~/.aws/credentials
    &ec2rolecreds.EC2RoleProvider{...},        // IMDS = the node role
})
```

No web-identity provider. An IRSA-annotated ServiceAccount gets its token
projected into the pod and the driver never reads it, so the push fails with
`s3aws: NoCredentialProviders: no valid providers in chain. Deprecated.` —
a message that points at credentials in general and at nothing specific.

The alternative was raising the node group's IMDS hop limit so
`EC2RoleProvider` reaches the node role. That was rejected: it hands S3 access
to every pod on those nodes, which is a broader grant than one key scoped to
one bucket. Revisit when Harbor ships distribution 3.x, which uses SDK v2 and
does support web identity.

The lifecycle policy deliberately has **no expiration**. Harbor manages blob
retention itself through tag rules and garbage collection; an S3 rule deleting
objects underneath it would race with that, and losing a blob a manifest still
references corrupts the image with no warning until someone tries to pull it.

### 3. Namespace and secrets

```bash
./01_create_harbor_secrets_prod.sh
```

Four secrets, all stored in AWS Secrets Manager as the source of truth and
mirrored into Kubernetes:

- **S3 access key** — created here rather than in `00_` because AWS returns the
  secret half exactly once, at creation. Creating it in the script that can put
  it straight into Secrets Manager means it never passes through a terminal, a
  shell history, or this repo. Rotate with
  `./01_create_harbor_secrets_prod.sh rotate-s3`.
- **admin password** — the chart's default is `Harbor12345`, published in
  Harbor's own documentation
- **secretKey** — encrypts stored credentials. If the chart generates it, the
  next `helm upgrade` generates a *different* one and every previously
  encrypted value becomes unreadable. Pinning it removes that failure mode.
- **database password** — the chart's default is `changeit`

### 4. Install

```bash
./02_install_harbor_prod.sh
./02_install_harbor_prod.sh verify
```

`verify` checks the thing most likely to be wrong: whether the registry pod
actually holds the S3 key. The failure mode is quiet — a missing or misnamed
Secret mounts as an *empty* environment variable rather than failing the pod,
so the registry runs normally and only fails on the first push.

### 5. Expose the hostname

Nothing to do here — `harbor.nopega.net` is served by the shared ALB that
`set_up_cluster/09_public_alb_prod/` creates, alongside `trino` and
`airflow`. An earlier revision of this file routed it through a Cloudflare
Tunnel; that was abandoned because Cloudflare's free plan caps request bodies
at 100 MB, and a container layer is routinely larger than that. A `docker push`
through the tunnel fails partway through a layer with an HTTP error that says
nothing about size limits.

One thing that ALB script does specifically for Harbor: it adds the cluster's
NAT gateway address to the allowed inbound ranges. The nodes pull images by the
public hostname, so they arrive at the ALB from the NAT's address rather than
from any human's. Without it, pulls fail with a TCP timeout — see "Things that
will look like bugs" below.

### 6. Create the project

```bash
./01_create_harbor_secrets_prod.sh show-admin
docker login harbor.nopega.net
```

Then in the UI: **Projects → New Project**

- Name: `ice-berg-platform`
- Access level: **private**
- **Automatically scan images on push**: on
- **Prevent vulnerable images from running**: **off** — see below

#### Why the blocking policy is off, and what that costs

This was on, at severity `High`, and it worked exactly as intended: the first
image push was scanned, failed the policy, and every pull returned

```
412 Precondition Failed
```

The scan found **4694 vulnerabilities, 2156 of them fixable**, with Criticals
present. That is not a defect in this platform's image — `apache/spark:4.0.1`
is Ubuntu 22.04 plus JDK 21 plus several hundred JARs from the Spark
distribution, and Trivy scans the JARs too. Any Spark image built on the
official base lands in the same range.

So the policy as configured did not mean "block risky images". It meant "block
every image", which is the same as having no registry. The three ways out:

| | | |
|---|---|---|
| Keep blocking, add a CVE allowlist | policy still enforced | 2156 entries to curate and re-curate on every base-image bump — not workable |
| **Scan without blocking** | every CVE and an SBOM still visible and recorded | nothing is enforced at the registry |
| Hardened base (Chainguard/Wolfi, distroless) | CVE count drops to single digits | the Spark distribution has to be assembled rather than inherited |

The middle option is in force. It is a deliberate, documented trade-off, not an
oversight — the scanning half is what makes the vulnerability count *knowable*,
and turning that off too would be the actual mistake.

The third option is the correct answer for a real production platform, and is
recorded as such. The Dockerfile does what it cheaply can in the meantime: it
runs `apt-get upgrade` so the OS half of the image is patched on every build,
even though that cannot touch the JARs where most of the findings live.

---

## Verifying

```bash
./02_install_harbor_prod.sh verify
```

An end-to-end proof that S3 storage works, which `verify` cannot do for you:

```bash
docker pull public.ecr.aws/docker/library/busybox:1.36
docker tag  public.ecr.aws/docker/library/busybox:1.36 harbor.nopega.net/ice-berg-platform/busybox:test
docker push harbor.nopega.net/ice-berg-platform/busybox:test

aws s3 ls s3://data-store-prod-registry/docker/registry/v2/ --recursive | head
```

Objects appearing under that prefix means the registry is genuinely writing to
S3 rather than to the PVC the chart also renders.

---

## Things that will look like bugs and are not

**PVCs sit `Pending` with no pod.** The StorageClass uses
`WaitForFirstConsumer`, so a volume is not provisioned until something is
scheduled to use it. Expected.

**`helm uninstall` leaves PVCs behind.** `persistence.resourcePolicy` is
`keep`. An accidental uninstall should cost a reinstall, not every project
definition and scan result the platform has accumulated.

**Trivy takes several minutes on first start.** It downloads a ~2GB
vulnerability database before reporting ready. The install timeout is 15
minutes for this reason.

**Port-forwarding to the UI works but pushing to `localhost` does not.**
`externalURL` is `https://harbor.nopega.net`, and the registry redirects
clients there regardless of how they arrived.

---

## Uninstalling

```bash
./02_install_harbor_prod.sh uninstall     # release only; PVCs and S3 survive
kubectl delete pvc -n harbor --all        # only if the data is genuinely unwanted
./00_create_harbor_bucket_and_iam_prod.sh delete   # IAM user, keys and policy
```

The bucket is never deleted by any script here. Removing the store of every
image the platform runs should be a decision someone types out in full:

```bash
aws s3 rb s3://data-store-prod-registry --force
```
