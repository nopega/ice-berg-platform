# Cost

Every decision in this platform that was made for money, and what each one
saves. Deliverable 1 asks for cost-awareness justification; this is it in one
place, with the reasoning that produced each number.

The pattern worth noticing: **compute is the visible half of the bill and
rarely the surprising one.** You choose the instance type, so you know what it
costs. Data movement does not work that way — it accrues quietly, in a service
nobody was thinking about, under a line item nobody checks, which is why the
largest saving below is a VPC endpoint rather than a smaller node.

## Running cost

| Item | Monthly | Note |
|---|---|---|
| EKS control plane | ~\$73 | \$0.10/hr. Would be \$438 on a version in extended support — which is why `eks-cluster.yaml` deliberately does not pin an old Kubernetes version |
| `ng-ondemand` 5 × m5.large | ~\$425 | the platform itself |
| `ng-spot` 0 → N | ~\$0 idle | Spark executors only; the group holds zero nodes when nothing is running |
| RDS `db.t4g.micro` | ~\$15 | Polaris catalog + Airflow metadata |
| ALB (one, shared) | ~\$22 | six hostnames on one load balancer |
| NAT gateway (one) | ~\$32 | plus data processing — see below |
| S3 | a few \$ | warehouse + logs + registry |
| **S3 gateway endpoint** | **\$0** | and it is the largest saving here |

## The four decisions that matter

### One NAT gateway, and an S3 gateway endpoint beside it

HA would want one NAT per availability zone. At ~\$32/month each that is a
deliberate availability trade, and it is the smaller half of the story.

The larger half is **data processing at ~\$0.045/GB**. S3 is this platform's
storage layer, so a single 1 TB Trino scan would cost about \$45 in NAT charges
— billed under *NAT Gateway*, not under *S3*, which is where nobody thinks to
look.

A gateway VPC endpoint has no hourly rate and no per-GB rate, and routes S3
traffic straight out of the subnet. At the terabyte scale this platform is
designed for it is the difference between a rounding error and a monthly line
item that grows with usage.

`set_up_cluster/07_vpc_endpoints_prod/`

### `ng-spot` at zero nodes

Spark executors are the only workload on the Spot group, and the group sits at
`desiredCapacity: 0`. The Cluster Autoscaler brings nodes up when a job asks
and removes them afterwards.

That combination is what makes "Spot's 60–70% discount applies to the bulk of
the compute" true rather than aspirational: the discount only helps if the
capacity also disappears when idle. This DAG runs once a day for a few minutes,
so the group costs nothing for the other 23 hours.

It requires ASG node-template tags to work from zero — without a live node to
copy, the autoscaler cannot imagine the shape of one and silently does nothing.
`09_cluster_autoscaler_prod/00_create_autoscaler_irsa_and_tags_prod.sh`

### One ALB for six hostnames

Every Ingress carries `alb.ingress.kubernetes.io/group.name:
data-platform-public`, so the controller merges them into a single load
balancer: one ALB, one certificate, six host rules.

Six separate ALBs would cost roughly \$132/month instead of \$22, and need six
certificates, for no benefit at this scale.

### The fifth node, bought on purpose

`ng-ondemand` went 1 → 2 → 3 → 4 → 5, each step after a pod failed to schedule
rather than in anticipation. The last one was for the monitoring stack:
Prometheus, Grafana, Alertmanager, kube-state-metrics and the operator ask for
roughly 1 vCPU and 2.5Gi, and the group had nothing like that free.

~\$85/month to be able to answer "is the platform healthy" without
port-forwarding into it. The measurements behind every step are in
`scale/scale_up.sh`.

## Making it visible

Grafana has a CloudWatch datasource with Cost Explorer permissions, so the
claims above can be checked rather than asserted.
`06_monitoring_prod/02_create_grafana_cloudwatch_irsa_prod.sh`

Two things it needs that are not obvious: **billing metrics only exist in
us-east-1** whatever region the resources are in, which is why there are two
CloudWatch datasources; and `AWS/Billing` is only published at all once
*Receive CloudWatch billing alerts* is enabled in Billing preferences.

## Turning the whole thing off

```bash
./scale/scale_down.sh     # node groups to zero, stop RDS
./scale/scale_up.sh       # back to 5 / 0, start RDS
```

Node groups to zero and RDS stopped leaves the EKS control plane (~\$73/month)
and storage. Helm releases and the RDS databases survive, so bringing it back
is one command rather than a reinstall.
