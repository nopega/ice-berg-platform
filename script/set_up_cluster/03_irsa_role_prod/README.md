# Prod IAM — IRSA, not an instance profile

Prod runs on **EKS**, not a single EC2 instance, so the TEST approach
(`../03_iam_role_test/` — one instance profile attached to one EC2 instance)
does not apply here. Every pod (Trino worker, Spark executor, ...) needs its
own scoped AWS identity — that mechanism is **IRSA** (IAM Roles for Service
Accounts).

## Why this is different from the TEST role

| | TEST (`../03_iam_role_test/`) | PROD (this folder) |
|---|---|---|
| Compute | 1 EC2 instance | Many pods on EKS, scheduled/rescheduled constantly |
| Identity granted to | The whole instance | A specific Kubernetes ServiceAccount (namespace-scoped) |
| Trust policy principal | `ec2.amazonaws.com` | The **EKS cluster's OIDC provider** (`Federated` principal) |
| Mechanism | EC2 instance metadata service | Web identity federation — the pod exchanges a Kubernetes-signed token for temporary AWS credentials |

## Why the script can't just run yet

The trust policy for an IRSA role has to reference the specific OIDC
provider URL of *your* EKS cluster (it's unique per cluster). That URL does
not exist until the EKS cluster itself has been created — that's
`../../02_eks_cluster_prod/`, which must run **before** this folder.

`03_create_irsa_role_prod.sh` in this folder is written to run for real, but
it checks for the cluster first and exits with a clear message if it isn't
there yet, instead of failing on a confusing AWS error.

## What it does once the cluster exists

1. Look up the cluster's OIDC issuer URL via `aws eks describe-cluster`.
2. Confirm an IAM OIDC identity provider is registered for it (created
   automatically by `eksctl create cluster` when using a recent eksctl, or
   via `eksctl utils associate-iam-oidc-provider` otherwise).
3. Generate a trust policy scoped to one Kubernetes ServiceAccount
   (`data-platform` namespace, `data-platform-workload` service account) —
   only pods running under that exact ServiceAccount can assume the role.
4. Create/attach the S3 access policy in `s3-access-policy.json` (same
   least-privilege shape as TEST, but pointed at the prod buckets).
5. Print the annotation to put on the Kubernetes ServiceAccount so pods
   using it actually pick up the role.

## Hardening note (not implemented, documented for completeness)

This creates **one shared role** for both Trino and Spark workloads to keep
this take-home scoped. A stricter production setup would split this into
two roles/ServiceAccounts (e.g. `trino-workload`, `spark-etl-workload`),
since Trino only needs read access in normal operation while Spark needs
read/write — separating them narrows what a compromised Trino worker could
do to zero write access.
