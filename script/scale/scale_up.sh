#!/usr/bin/env bash
#
# scale_up.sh — bring the platform back after scale_down.sh
#
# Restores the node groups to their working sizes and starts RDS again. Pods
# are rescheduled automatically by Kubernetes; no Helm release needs
# reinstalling and no data was lost.
#
# Sizes restored here:
#   ng-ondemand  min 5, desired 5   (control plane, labelled workload=critical:
#                                    Polaris, Trino coordinator + workers, the
#                                    four Airflow components, Harbor, the Spark
#                                    Operator, Spark drivers, and the
#                                    monitoring stack. Went 1 -> 2 when Airflow
#                                    arrived, 2 -> 3 for Harbor, 3 -> 4 for the
#                                    first Spark driver, 4 -> 5 for Prometheus
#                                    and Grafana.)
#   ng-spot      min 0, desired 0   (batch: Spark executors only. Was desired 1
#                                    while Trino workers lived here; they moved
#                                    to on-demand, so nothing needs standing
#                                    spot capacity any more and this group only
#                                    costs money while a Spark job is running.)
#
# WHY ng-ondemand GREW, ONE NODE AT A TIME
# -----------------------------------------
# Each step below was taken after a pod failed to schedule, not before. The
# measurements are kept because "add a node" is the expensive reflex, and the
# alternatives that were checked and rejected are the useful part.
#
# One m5.large is 2 vCPU / 8Gi, of which roughly 1.9 vCPU / 7Gi is allocatable
# after the kubelet and system daemons take their share.
#
# Measured on the running cluster at two nodes, before Harbor:
#
#   node 1   1200m / 1935m CPU (62%)   4992Mi / 7131Mi memory (70%)
#   node 2   1325m / 1949m CPU (68%)   4044Mi / 7095Mi memory (57%)
#   free     ~1360m CPU               ~5.1Gi memory
#
# Harbor requests roughly 1200m / 2.8Gi across its seven pods, which leaves
# about 160m of CPU for the whole cluster. Still to be placed after that:
# cloudflared (~100m), the Spark Operator (~100m), and -- the one that settles
# it -- a Spark driver of ~1000m every time an ETL job runs. Executors ride
# Spot and do not count here, but the driver cannot: losing it kills the job,
# which is why it stays on On-Demand.
#
# So CPU, not memory, is the binding constraint, and two nodes run out of it
# before the pipeline this platform exists to run has started.
#
# Kubernetes does not report that as an error. The pod that does not fit simply
# stays Pending, `helm upgrade --wait` blocks until it times out, and the cause
# appears only in `kubectl describe pod`. This has already cost time twice here
# (Trino workers, the Airflow triggerer). The third node is cheaper than the
# third occurrence.
#
# WHY IT IS NOW 4
# ----------------
# The estimate above was right about the mechanism and wrong about the margin:
# Harbor turned out larger than 1200m once Trivy and Postgres were counted. The
# first real Spark driver could not be placed. Measured at three nodes, with
# every component running and nothing scheduled from Spark yet:
#
#   node             CPU requested     free      memory requested   free
#   151-248          1855m (96%)        ~75m     6580Mi (92%)     ~570Mi
#   166-184          1590m (82%)       ~349m     4624Mi (65%)    ~2476Mi
#   97-231           1640m (84%)       ~312m     5776Mi (81%)    ~1354Mi
#
# A driver declared as `cores: 1, memory: 1g` asks for 1000m and roughly
# 1408Mi -- Spark adds memoryOverhead of max(384Mi, 10%) on top of `memory`,
# which is easy to forget when sizing. Nothing above has 1000m free, so the
# driver stayed Pending with:
#
#   0/3 nodes are available: 2 Insufficient memory, 3 Insufficient cpu
#
# Two cheaper fixes were considered and rejected on the numbers, not on
# principle:
#
#   - Lowering driver.coreRequest to 500m. The largest free block is 349m, so
#     this does not fit either, and it would leave the driver throttled during
#     a real ETL rather than a smoke test.
#   - Removing cloudflared, which is genuinely dead weight now that the ALB
#     replaced it. Worth doing, and it returns about 100m -- an order of
#     magnitude short of what is needed.
#
# The driver stays on On-Demand rather than moving to Spot with the executors.
# That is the one thing not up for negotiation here: an interrupted executor
# costs the partitions it held, an interrupted driver costs the whole job.
#
# Running this straight after scale_down.sh is safe: RDS needs several minutes
# to finish stopping and rejects a start request until it does, so this script
# waits out a 'stopping' state rather than skipping the start.
#
# Usage:
#   ./scale_up.sh            # restore nodes + start RDS, then wait until ready
#   ./scale_up.sh nowait     # kick everything off but don't block
#
# Note that `nowait` skips the RDS wait *and* the Polaris restart that follows
# it, so after a nowait run Polaris may need `kubectl delete pod -n
# data-platform -l app.kubernetes.io/name=polaris` once the database is up.
#
set -euo pipefail

CLUSTER_NAME="data-platform-prod"
REGION="ap-southeast-1"
DB_INSTANCE_ID="data-platform-prod-db"
MODE="${1:-wait}"

# nodegroup:min:desired:max
#
# max is here, and passed on every run, because it used to be left alone and
# drifted. eks-cluster.yaml said maxSize 5 while the live node group had 3, and
# nothing surfaced the difference until a scale to 4 was rejected with:
#
#   InvalidParameterException: desired capacity 4 can't be greater than max size 3
#
# A value that is only ever read from a file nobody applies is not
# configuration, it is a comment. Sending it every time makes this script the
# thing that decides, so the file and the cluster cannot disagree.
NODEGROUP_SIZES=(
  "ng-ondemand:5:5:7"
  "ng-spot:0:0:4"
)

# ng-ondemand min == desired, deliberately.
#
# Once the Cluster Autoscaler is installed it manages BOTH groups, and a min of
# 1 was an instruction to drain this one down to a single node whenever it
# looked underutilised -- evicting Harbor, Trino, Polaris and Airflow to get
# there. That is correct autoscaler behaviour and completely wrong for a group
# whose whole job is to hold things that must not move. max stays above desired
# so it can still grow when a Spark driver has nowhere to go.
#
# 4 -> 5 when the monitoring stack was added. Prometheus, Grafana,
# Alertmanager, kube-state-metrics and the operator want roughly 1 vCPU and
# 2.5Gi together, which the group did not have -- it went to four nodes in the
# first place because a driver could not find 1000m free. Monitoring stays off
# ng-spot on purpose: Prometheus keeps its recent window in memory and its EBS
# volume is pinned to one AZ, so a Spot reclamation loses observability exactly
# when node churn makes it most useful.
#
# ng-spot keeps min 0, which is the point of the exercise: no Spark job, no
# nodes, no bill.
#
# scale_down.sh still parks the entire cluster, because it passes
# `--nodes-min 0` explicitly rather than relying on these numbers.

# These four numbers must match eks-cluster.yaml. That file is what a rebuild
# reads; this one is what a running cluster obeys. They are the same setting
# expressed twice, which is a wart -- but the alternative, having only the
# yaml, means every routine scale is a full `eksctl upgrade nodegroup`.

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
need aws
need eksctl
need kubectl

echo "== Scaling up ===================================================="

for entry in "${NODEGROUP_SIZES[@]}"; do
  IFS=':' read -r ng min desired max <<< "$entry"
  if ! aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$REGION" >/dev/null 2>&1; then
    echo "node group $ng: not found, skipping"
    continue
  fi
  echo "node group $ng: min=$min desired=$desired max=$max"
  # --nodes-max is sent before anything else could reject it: EKS refuses a
  # desired size above the CURRENT max, so raising the ceiling has to be part
  # of the same call rather than a separate step someone remembers to run.
  eksctl scale nodegroup \
    --cluster "$CLUSTER_NAME" \
    --region "$REGION" \
    --name "$ng" \
    --nodes "$desired" \
    --nodes-min "$min" \
    --nodes-max "$max"
done

echo ""
db_status() {
  aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" --region "$REGION" \
    --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "missing"
}
DB_STATUS="$(db_status)"

# 'stopping' is the state this script used to give up on, and it is exactly the
# state a scale_down immediately followed by a scale_up lands in: RDS takes
# several minutes to finish stopping and refuses a start while it does. The old
# behaviour printed a "re-run later" warning and carried on, which scrolled past
# in the node-group output -- so the run looked successful, the cluster came
# back, and Polaris then CrashLoopBackOff'd on
#   java.sql.SQLException: Acquisition timeout while waiting for new connection
# with nothing pointing at RDS. Waiting here instead makes the script's promise
# ("the platform is back") actually true when it exits.
if [ "$DB_STATUS" = "stopping" ]; then
  echo "RDS $DB_INSTANCE_ID: still 'stopping' -- waiting for it to settle before starting"
  for i in $(seq 1 60); do   # up to 10 minutes
    sleep 10
    DB_STATUS="$(db_status)"
    [ "$DB_STATUS" != "stopping" ] && break
    [ $((i % 6)) -eq 0 ] && echo "   still stopping (${i}0s)..."
  done
  echo "   now '$DB_STATUS'"
fi

case "$DB_STATUS" in
  stopped)
    echo "RDS $DB_INSTANCE_ID: starting..."
    aws rds start-db-instance --db-instance-identifier "$DB_INSTANCE_ID" --region "$REGION" >/dev/null
    ;;
  available|starting)
    echo "RDS $DB_INSTANCE_ID: already $DB_STATUS"
    ;;
  stopping)
    echo "RDS $DB_INSTANCE_ID: still 'stopping' after 10 minutes -- something is wrong." >&2
    echo "  Check the console, then re-run this script." >&2
    ;;
  missing)
    echo "RDS $DB_INSTANCE_ID: not found, skipping"
    ;;
  *)
    echo "RDS $DB_INSTANCE_ID: status is '$DB_STATUS'"
    ;;
esac

if [ "$MODE" = "nowait" ]; then
  echo ""
  echo "Started (nowait). Check progress with: ./scale_down.sh status"
  exit 0
fi

echo ""
echo "Waiting for a node to become Ready (usually 2-4 minutes)..."
for i in $(seq 1 60); do
  if [ -n "$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{print}')" ]; then
    echo "  node Ready."
    break
  fi
  sleep 10
  [ "$i" -eq 60 ] && echo "  still no Ready node after 10 minutes -- check: kubectl get nodes" >&2
done

if [ "$DB_STATUS" = "stopped" ] || [ "$DB_STATUS" = "starting" ]; then
  echo "Waiting for RDS to become available (usually 3-5 minutes)..."
  aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_ID" --region "$REGION" || true

  # Polaris opens its connection pool once at startup and dies if the database
  # is not there, rather than retrying -- so a pod that started while RDS was
  # still coming up stays in CrashLoopBackOff indefinitely even though the
  # database is now fine. Restarting it here closes that window instead of
  # leaving a broken pod for someone to discover later.
  if kubectl get deployment polaris -n data-platform >/dev/null 2>&1; then
    NOT_READY="$(kubectl get pods -n data-platform -l app.kubernetes.io/name=polaris \
      --no-headers 2>/dev/null | awk '$2!="1/1"{print}')"
    if [ -n "$NOT_READY" ]; then
      echo "Polaris is not Ready (it outlived the database being down) -- restarting it."
      kubectl delete pod -n data-platform -l app.kubernetes.io/name=polaris >/dev/null 2>&1 || true
    fi
  fi
fi

echo ""
echo "--- Current state ---"
kubectl get nodes 2>/dev/null || true
echo ""
kubectl get pods -A 2>/dev/null | grep -Ev "kube-system" || true

cat <<EOF

Back up. Pods may take another minute or two to finish restarting.

  kubectl get pods -n argocd
  kubectl get pods -n data-platform
EOF
