# AWS Load Balancer Controller (prod)

This installs the Kubernetes controller that can create and reconcile AWS
Application Load Balancers (ALBs) from `Ingress` resources. It **does not**
create an ALB, public DNS record, listener, or open an application to the
internet by itself.

The explicit public entry point comes later, after Trino has HTTPS-compatible
authentication and an ACM certificate. Keeping those as separate steps
prevents an accidental public, unauthenticated Trino coordinator.

## Why it is a cluster component

The controller watches the whole cluster. Later, one Ingress will create one
shared ALB with host routing:

```text
https://airflow.nopega.net -> Airflow API server
https://trino.nopega.net   -> Trino coordinator (Power BI ODBC)
```

The ALB distributes inbound HTTP(S) requests to healthy pods and terminates
TLS. It does not make Trino execute more SQL simultaneously: worker count and
Trino resource groups determine query capacity.

## Files

- `iam-policy.json` — AWS's controller IAM policy, copied from the upstream
  v2.14.1 release and committed so the requested AWS permissions are reviewable.
- `01_create_irsa_prod.sh` — creates a policy and a role trusted only by
  `kube-system/aws-load-balancer-controller`.
- `02_install_controller_prod.sh` — installs the vendored Helm chart using
  that ServiceAccount.

## Install

Vendor the chart once and commit `chart/aws-load-balancer-controller/`:

```bash
cd problem2_answer/script/set_up_cluster/08_load_balancer_controller_prod
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm pull eks/aws-load-balancer-controller --version 1.14.0 --untar --untardir ./chart
```

Then run:

```bash
./01_create_irsa_prod.sh
./02_install_controller_prod.sh
./02_install_controller_prod.sh verify
```

Expected: a two-replica controller Deployment in `kube-system`. The AWS Load
Balancer console should still show no new ALB from this step alone.

## Prerequisites

- EKS cluster `data-platform-prod`, with its IAM OIDC provider enabled
- `aws`, `kubectl`, and `helm`
- At least two suitable subnets. An `eksctl`-created VPC normally tags public
  subnets with `kubernetes.io/role/elb=1`; this will be verified before the
  public Ingress is applied.

## Operations

```bash
./02_install_controller_prod.sh diff
./02_install_controller_prod.sh verify
./02_install_controller_prod.sh logs
./02_install_controller_prod.sh uninstall
```

Do not remove the controller while an Ingress that it owns still exists.
Delete the Ingress first and confirm the ALB is gone, otherwise AWS resources
may outlive the controller and continue costing money.
