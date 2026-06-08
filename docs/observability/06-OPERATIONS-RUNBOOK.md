# Temporal Order Platform — Operations Runbook

_Last updated: 2026-06-08 | Owner: daniyal.tufail@xgrid.co_

> This is the **incident-response** runbook (what to do when something breaks).
> For the scripted demo walkthrough see [05-DEMO-RUNBOOK.md](05-DEMO-RUNBOOK.md).
> For architecture see [01-ARCHITECTURE.md](01-ARCHITECTURE.md).

---

## 1. Service Overview

This stack runs a **Temporal**-orchestrated order-processing platform on Amazon ECS
(EC2 launch type) in `us-east-1`. An `OrderWorkflow` drives each order through fraud
check → inventory reservation → a human/event validation gate → payment → parallel
per-item shipping (child workflows) → notification, with a **saga** that compensates
(refund + revert inventory) on any failure.

Topology: a public **ALB** fronts the FastAPI order service (`:8000`), the Temporal Web
UI (`:8080`) and Grafana (`:80`/`:8443`). An internal **NLB** carries Temporal gRPC
(`:7233`). Workers, the Temporal server, five mock dependency services, Prometheus,
AlertManager and Grafana all run as ECS services on the cluster; Node Exporter runs as a
daemon (one task per instance). State lives in **RDS PostgreSQL** (`temporal`,
`temporal_visibility`, `grafana` databases); Prometheus TSDB + Grafana data live on
**EFS**. Service discovery is **Cloud Map** (`temporal-order-dev.local`).

Two independent alerting paths exist:
1. **App-level:** Prometheus → AlertManager → SNS-bridge → SNS (needs the monitoring stack healthy).
2. **AWS-native:** CloudWatch `RunningTaskCount` alarms → SNS (fires even if monitoring is down).

---

## 2. Quick Reference

> ⚠️ The **ALB DNS and Grafana password change on every `terraform destroy` + re-apply.**
> Don't trust hardcoded values — discover them (see commands below). The values here are
> current as of the last update.

| Resource | Value / how to get it |
|---|---|
| Region / Account | `us-east-1` / `432500708329` |
| ECS cluster | `temporal-order-dev` |
| Temporal namespace | `temporal-dev` |
| Search attribute | `OrderStatus` (Keyword) |
| ALB DNS | `aws elbv2 describe-load-balancers --region us-east-1 --query "LoadBalancers[?contains(LoadBalancerName,'temporal-order-dev-alb')]|[0].DNSName" --output text` |
| Temporal UI | `http://<ALB_DNS>:8080` |
| Order API / Swagger | `http://<ALB_DNS>:8000` · `/docs` |
| Grafana | `http://<ALB_DNS>` (admin / `terraform -chdir=Temporal/terraform/environments/dev output -raw grafana_admin_password`) |
| Temporal gRPC (NLB) | `temporal-order-dev-temporal-nlb-...elb.us-east-1.amazonaws.com:7233` (internal only) |
| RDS endpoint | `temporal-order-dev-temporal-db.ckn6gqcccz2y.us-east-1.rds.amazonaws.com:5432` |
| SNS topic | `arn:aws:sns:us-east-1:432500708329:temporal-order-dev-alarms` |
| ECR repos | `temporal-order-api`, `temporal-order-worker`, `temporal-order-services` |
| Log groups | `/ecs/temporal-order/dev/{temporal-server,worker,api}` |
| Prometheus (internal) | `prometheus.temporal-order-dev.local:9090` (reach via Grafana proxy, below) |
| Test / failure-injection suite | `temporal_test_suite.py` (16-option menu) |
| Daily report | `Temporal/scripts/daily-reliability-report.py` (cron 06:00) |
| Terraform root | `Temporal/terraform/environments/dev` |

**Reach internal Prometheus from anywhere (via Grafana datasource proxy):**
```bash
ALB=$(aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[?contains(LoadBalancerName,'temporal-order-dev-alb')]|[0].DNSName" --output text)
GPASS=$(terraform -chdir=Temporal/terraform/environments/dev output -raw grafana_admin_password)
curl -s -u admin:$GPASS \
  "http://$ALB/api/datasources/proxy/uid/temporalprom/api/v1/query?query=up" | jq .
```

---

## 3. Health-Check One-Liners

**Are all services up?**
```bash
aws ecs describe-services --region us-east-1 --cluster temporal-order-dev \
  --services temporal-order-temporal-server temporal-order-temporal-ui \
    temporal-order-api temporal-order-worker temporal-order-dev-prometheus \
    temporal-order-dev-grafana \
  --query 'services[*].{name:serviceName,desired:desiredCount,running:runningCount,deploy:deployments[0].rolloutState}' \
  --output table
```
(Mock services + node-exporter are a second group — service names can have at most 10 items per call.)

**Is the API serving and can it start a workflow?**
```bash
ALB=$(aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[?contains(LoadBalancerName,'temporal-order-dev-alb')]|[0].DNSName" --output text)
curl -s -o /dev/null -w "health %{http_code}\n" "http://$ALB:8000/health"
curl -s -X POST "http://$ALB:8000/orders" -H "Content-Type: application/json" \
  -d '{"order_id":"smoke","address":"1 Main St","items":[{"item_id":1001,"description":"KB","quantity":1}]}'
```

**Is the NLB gRPC target healthy? (workers/API can't connect if not)**
```bash
TG=$(aws elbv2 describe-target-groups --region us-east-1 \
  --query "TargetGroups[?TargetGroupName=='temporal-order-dev-tgrpc'].TargetGroupArn" --output text)
aws elbv2 describe-target-health --region us-east-1 --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[*].{ip:Target.Id,state:TargetHealth.State}' --output table
```

---

## 4. CloudWatch Alarm Playbooks (service-DOWN)

These six alarms fire when a service drops to **0 running tasks** for ~2 min
(`RunningTaskCount < 1`, `treat_missing_data=breaching`). They email via SNS on both
DOWN and recovery. Alarm names: `temporal-order-dev-<svc>-DOWN`.

### `temporal-order-dev-temporal-server-DOWN`
**Severity:** SEV-1 — nothing works without the server (UI, API, workers all depend on it).

**First action — read the latest task's logs (the cause is almost always here):**
```bash
LG=/ecs/temporal-order/dev/temporal-server
S=$(aws logs describe-log-streams --region us-east-1 --log-group-name $LG \
  --order-by LastEventTime --descending --max-items 1 --query 'logStreams[0].logStreamName' --output text)
aws logs get-log-events --region us-east-1 --log-group-name $LG --log-stream-name "$S" \
  --start-from-head --output text --query 'events[*].message' | tr '\t' '\n' | grep -iE "error|fatal" | tail -20
```

**Common causes & fixes:**
| Log signature | Cause | Fix |
|---|---|---|
| `database "temporal" does not exist` | Fresh RDS (post-rebuild) — DBs not created | **§7 DB bootstrap** |
| `unable to refresh database connection pool` / TLS | RDS unreachable or SG egress missing | Check `temporal_sg → RDS:5432` egress + RDS ingress |
| `Not enough hosts to serve the request` | **Transient** Ringpop membership at startup | Wait ~60s; only act if it persists >3 min |
| Exits code 1 silently after `Not using any authorizer` | Single-node broadcast/membership | See [04-DISCOVERIES.md](04-DISCOVERIES.md); confirm `BIND_ON_IP=0.0.0.0` |

After fixing, force a clean start:
```bash
aws ecs update-service --region us-east-1 --cluster temporal-order-dev \
  --service temporal-order-temporal-server --force-new-deployment
```

### `temporal-order-dev-worker-DOWN`
**Severity:** SEV-1 — no worker = workflows accepted but never progress.

1. Confirm desired count and recent stop reason:
   ```bash
   aws ecs describe-services --region us-east-1 --cluster temporal-order-dev \
     --services temporal-order-worker --query 'services[0].events[0:3].message' --output text
   ```
2. Pull a stopped task's reason:
   ```bash
   T=$(aws ecs list-tasks --region us-east-1 --cluster temporal-order-dev \
     --service-name temporal-order-worker --desired-status STOPPED --query 'taskArns[0]' --output text)
   aws ecs describe-tasks --region us-east-1 --cluster temporal-order-dev --tasks "$T" \
     --query 'tasks[0].{stopped:stoppedReason,containers:containers[*].{reason:reason,exit:exitCode}}'
   ```
3. **`CannotPullContainerError` / `exec format error`** → image missing or wrong arch → **§7 image rebuild** (`--platform linux/amd64`).
4. Healthy but workflows still stuck → check the worker can reach the NLB (§3) and that the task queue has pollers:
   ```bash
   # via temporal CLI on an ECS instance — see §6
   temporal --address <NLB>:7233 task-queue describe --namespace temporal-dev --task-queue order-task-queue
   ```

### `temporal-order-dev-temporal-ui-DOWN`
**Severity:** SEV-3 — operator visibility only; no customer impact.
The UI has no metrics endpoint, so this CloudWatch alarm is its *only* down-signal.
Check logs (`/ecs/temporal-order/dev/...`); the UI just needs the server reachable on `:7233`.

### `temporal-order-dev-api-DOWN`
**Severity:** SEV-1 — customers can't submit orders.
Usually one of: image missing (§7), or the API can't reach the Temporal server (NLB, §3).
Logs: `/ecs/temporal-order/dev/api`.

### `temporal-order-dev-prometheus-DOWN` / `temporal-order-dev-grafana-DOWN`
**Severity:** SEV-2 — you're flying blind, but orders still flow.
- **Grafana `database "grafana" does not exist`** → **§7 DB bootstrap** (the `grafana` DB).
- Prometheus down → metrics + the app-level alert path are dead; CloudWatch alarms still cover service-down. Check EFS mount (`fsap-...`) and the task logs.

---

## 5. Prometheus / AlertManager Alert Playbooks (app-level)

These come from PromQL rules → AlertManager → SNS. They require the monitoring stack to be up.

| Alert | Means | First moves |
|---|---|---|
| **WorkflowSLOFastBurn** (critical) | Error budget burning ~14.4× — 99% SLO gone in ~2 days | Open Grafana SLO dashboard; find which step fails. Check `send_notification`/`charge_customer` activity errors and the failing mock service. |
| **WorkflowSLOSlowBurn** (warning) | 6h burn > 6× | Same, less urgent — investigate within the hour. |
| **HighWorkflowTaskExecutionFailure** (critical) | `workflow_task_execution_failed` by `error_type` > 0 — the **non-determinism canary** | A bad deploy changed workflow code with running executions. See versioning note in [04-DISCOVERIES.md]. Roll back the worker image or add a `patched()` guard. |
| **LowPollSyncRate** (warn <95 / crit <90) | Workers can't keep up / too few pollers | Scale workers (`desired_worker_count`) or check worker health. |
| **Activity sched-to-start p95 > 150ms** | Backlog building | Same — more worker capacity. |
| **BadSearchAttributes in worker logs** | `OrderStatus` not registered (post-rebuild) | **§7 search-attribute registration** |

**Find which step is failing (per workflow status):** Temporal UI → filter `OrderStatus`, or query the `temporal_*` golden-signals panels in Grafana.

---

## 6. Common Operational Tasks

**Run the temporal CLI** (NLB is internal — run from an ECS instance via SSM, no separate install):
```bash
NLB=temporal-order-dev-temporal-nlb-XXXX.elb.us-east-1.amazonaws.com
IID=$(aws ec2 describe-instances --region us-east-1 \
  --filters "Name=tag:AmazonECSManaged,Values=true" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ssm send-command --region us-east-1 --instance-ids "$IID" \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["docker run --rm --entrypoint temporal temporalio/auto-setup:1.25.2 --address '"$NLB"':7233 operator namespace describe temporal-dev 2>&1 | tail"]}' \
  --query 'Command.CommandId' --output text
# then: aws ssm get-command-invocation --command-id <id> --instance-id $IID --region us-east-1
```

**Restart a service (rolling):**
```bash
aws ecs update-service --region us-east-1 --cluster temporal-order-dev \
  --service <service-name> --force-new-deployment
```

**Scale workers manually:**
```bash
aws ecs update-service --region us-east-1 --cluster temporal-order-dev \
  --service temporal-order-worker --desired-count 4
```

**Reseed mock inventory** (in-memory stock 1001:50, 1002:30, 1003:10):
```bash
aws ecs update-service --region us-east-1 --cluster temporal-order-dev \
  --service temporal-order-dev-inventory --force-new-deployment
```

**Generate load / inject failures:** `python3 temporal_test_suite.py` (option 9 = traffic;
options for alarm fire-test, outage drill, kill-task self-heal). It auto-discovers the live ALB + Grafana password.

**Send the daily report now:** `python3 Temporal/scripts/daily-reliability-report.py` (add `--dry-run` to print without emailing).

---

## 7. Disaster Recovery — Full Rebuild (`terraform destroy` → re-apply)

A destroy + re-apply recreates all AWS resources but **NOT data inside them**. As of the
2026-06-08 change, `bootstrap.tf` automates all three of the items below — but if a step
is ever skipped or you're recovering by hand, here are the manual procedures.

> **Why these break:** RDS comes back with only the default `postgres` DB; ECR repos come
> back empty; the namespace exists (auto-setup creates it) but the `OrderStatus` search
> attribute registration can silently no-op if it ran while the server was crash-looping.

### 7a. Create the databases (server + Grafana crash-loop without these)
```bash
IID=$(aws ec2 describe-instances --region us-east-1 \
  --filters "Name=tag:AmazonECSManaged,Values=true" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
RDS=temporal-order-dev-temporal-db.ckn6gqcccz2y.us-east-1.rds.amazonaws.com
PW=$(aws secretsmanager get-secret-value --region us-east-1 \
  --secret-id temporal-order/dev/temporal-db-credentials --query SecretString --output text \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['password'])")
aws ssm send-command --region us-east-1 --instance-ids "$IID" --document-name AWS-RunShellScript \
  --parameters '{"commands":["docker run --rm -e PGPASSWORD='"'"''"$PW"''"'"' postgres:15 psql '"'"'host='"$RDS"' port=5432 user=temporal dbname=postgres sslmode=require'"'"' -c '"'"'CREATE DATABASE temporal;'"'"' -c '"'"'CREATE DATABASE temporal_visibility;'"'"' -c '"'"'CREATE DATABASE grafana;'"'"' 2>&1"]}'
# then force-new-deployment temporal-server and grafana
```

### 7b. Build & push all 7 images (ECR is empty → API/worker/mocks have nothing to pull)
```bash
REG=432500708329.dkr.ecr.us-east-1.amazonaws.com
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $REG
# IMPORTANT: linux/amd64 + buildx --push + SEQUENTIAL (parallel push → connection reset)
docker buildx build --platform linux/amd64 --push -t $REG/temporal-order-api:latest    -f Temporal/python/Dockerfile.api    Temporal/python
docker buildx build --platform linux/amd64 --push -t $REG/temporal-order-worker:latest -f Temporal/python/Dockerfile.worker Temporal/python
for d in fraud inventory notification payment shipping; do
  docker buildx build --platform linux/amd64 --push -t $REG/temporal-order-services:$d Temporal/services/${d}_service
done
# then force-new-deployment api, worker, and the 5 mock services
```

### 7c. Register the OrderStatus search attribute (workflows fail BAD_SEARCH_ATTRIBUTES without it)
```bash
NLB=temporal-order-dev-temporal-nlb-XXXX.elb.us-east-1.amazonaws.com
# via SSM on an ECS instance (server must be healthy first):
docker run --rm --entrypoint temporal temporalio/auto-setup:1.25.2 \
  --address $NLB:7233 operator search-attribute create \
  --namespace temporal-dev --name OrderStatus --type Keyword
```

### 7d. Correct ordering for a clean rebuild
1. `terraform apply` (cluster + RDS + ECR come up).
2. **DBs** (7a) — before server/grafana stabilize. *(automated: `null_resource.db_bootstrap`)*
3. **Images** (7b) — before api/worker/mocks settle. *(automated: `null_resource.image_build_push`)*
4. Server reaches healthy → **search attribute** (7c). *(automated: `null_resource.temporal_namespace_setup`)*
5. Smoke test (§3) + run `temporal_test_suite.py` option 9.
6. Update any consumers that cached the **old ALB DNS** (the test suite + daily report now auto-discover it).

---

## 8. Escalation & Severity

| Severity | Definition | Examples |
|---|---|---|
| **SEV-1** | Customer-facing outage | server / api / worker DOWN; orders can't start or complete |
| **SEV-2** | Degraded / blind | Prometheus or Grafana down; SLO fast-burn |
| **SEV-3** | Internal only | Temporal UI down; single mock service flapping with retries absorbing it |

**Primary owner:** daniyal.tufail@xgrid.co · **Alerts:** SNS topic `temporal-order-dev-alarms`
(confirm your email subscription is in `Confirmed` state, or you won't receive pages).

---

## 9. Known Gaps (dev environment)

- Single-node Temporal server (`SERVICES=history,matching,frontend,worker` co-located) —
  not HA; a server task restart is a brief full outage. Production would split the 4 roles.
- `temporalio/auto-setup` is used for bring-up convenience (deprecated for prod).
- Workers scale on **CPU 25%** as an ECS proxy; the *correct* signal is
  `schedule_to_start_latency` (alerted, but not yet wired to scaling).
- See [04-DISCOVERIES.md](04-DISCOVERIES.md) for the full list of gotchas.
