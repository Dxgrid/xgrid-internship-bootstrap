# Failure Injection Tests — Flask SRE Platform (Week 6)

_Cluster: `flask-sre-ecs-dev-cluster` | Region: `us-east-1`_  
_ALB: `http://flask-sre-ecs-dev-alb-388642593.us-east-1.elb.amazonaws.com`_  
_Grafana: `<ALB>/grafana` | SNS alerts → `daniyal.tufail@xgrid.co`_

Each test has three parts: **inject** the failure, **observe** the signals, **verify** recovery. Run the alarm state check at the bottom after every test.

---

## Test 1 — Kill One Demo-App Task (HA Recovery)

**Goal:** Verify ECS reschedules a replacement task automatically and the app stays reachable.  
**Expected signal:** `ecs-low-task-count` may briefly fire (2→1), then clears when the replacement starts.  
**Expected result:** App returns HTTP 200 throughout. Running count returns to 2 within ~60s.

```bash
ALB="http://flask-sre-ecs-dev-alb-388642593.us-east-1.elb.amazonaws.com"

# Step 1 — Stop one task
TASK=$(aws ecs list-tasks \
  --cluster flask-sre-ecs-dev-cluster \
  --service-name flask-sre-ecs-dev-demo-app-svc \
  --region us-east-1 \
  --query "taskArns[0]" --output text)

echo "Stopping: $TASK"
aws ecs stop-task \
  --cluster flask-sre-ecs-dev-cluster \
  --task "$TASK" \
  --reason "Failure injection test 1 — HA recovery" \
  --region us-east-1

# Step 2 — App should still respond (ALB routes to the surviving task)
curl -sw "HTTP %{http_code}\n" -o /dev/null "${ALB}/"

# Step 3 — Watch ECS recover (Ctrl+C when running=2)
watch -n 5 "aws ecs describe-services \
  --cluster flask-sre-ecs-dev-cluster \
  --services flask-sre-ecs-dev-demo-app-svc \
  --region us-east-1 \
  --query 'services[0].{Running:runningCount,Desired:desiredCount,Pending:pendingCount}' \
  --output table"
```

**Pass criteria:** `curl` returns HTTP 200 during the test. Running count returns to 2.

---

## Test 2 — Inject 5xx Errors (HighErrorRate Alert)

**Goal:** Drive the error rate above 5% to trigger the `HighErrorRate` Prometheus alert and verify it fires, then clears.  
**Expected signal:** `HighErrorRate` alert PENDING after first scrape, FIRING after 2 minutes, clears when clean traffic flushes the 5m window.

```bash
ALB="http://flask-sre-ecs-dev-alb-388642593.us-east-1.elb.amazonaws.com"

# Step 1 — Send 200 error requests alongside 50 normal ones
ab -n 200 -c 10 -q "${ALB}/simulate/error" &
ab -n 50  -c 5  -q "${ALB}/" &
wait
echo "Done. Wait 30s for Prometheus scrape, then check error rate."

# Step 2 — Check current error rate via Grafana proxy
sleep 30
curl -s "${ALB}/grafana/api/datasources/proxy/uid/PBFA97CFB590B2093/api/v1/query" \
  -u "admin:GrafanaSecure2026" \
  --data-urlencode 'query=job:app_request_errors:ratio_rate5m * 100' | \
  python3 -c "import sys,json; r=json.load(sys.stdin)['data']['result']; \
    print(f'Error rate: {float(r[0][\"value\"][1]):.2f}%')"

# Step 3 — Check alert state (PENDING → FIRING after 2m for= window)
curl -s "${ALB}/grafana/api/datasources/proxy/uid/PBFA97CFB590B2093/api/v1/alerts" \
  -u "admin:GrafanaSecure2026" | \
  python3 -c "import sys,json; alerts=json.load(sys.stdin)['data']['alerts']; \
    [print(f'[{a[\"state\"].upper()}] {a[\"labels\"][\"alertname\"]}') for a in alerts] \
    or print('No alerts firing')"

# Step 4 — Flush errors by sending 1000 clean requests
ab -n 1000 -c 20 -q "${ALB}/" > /dev/null
echo "Clean traffic sent. Alert clears within 5m as error ratio drops in the rate window."
```

**Pass criteria:** Error rate exceeds 5%. `HighErrorRate` transitions PENDING → FIRING. Clears automatically after clean traffic.

---

## Test 3 — Simulate CPU Spike (HighCPU Alert)

**Goal:** Drive host CPU above 80% to trigger the `HighCPU` Prometheus alert.  
**Expected signal:** `HighCPU` alert fires after 3 minutes of sustained high CPU (per `for: 3m` rule).  
**Note:** The app's `/simulate/cpu` endpoint burns CPU for 2 seconds per request. Concurrent requests keep it sustained.

```bash
ALB="http://flask-sre-ecs-dev-alb-388642593.us-east-1.elb.amazonaws.com"

# Step 1 — Sustain CPU spike for ~5 minutes (200 concurrent requests, repeated)
echo "Spiking CPU for 5 minutes..."
for i in $(seq 1 3); do
  ab -n 100 -c 20 -q "${ALB}/simulate/cpu" &
done
wait

# Step 2 — Check current CPU per host via recording rule
curl -s "${ALB}/grafana/api/datasources/proxy/uid/PBFA97CFB590B2093/api/v1/query" \
  -u "admin:GrafanaSecure2026" \
  --data-urlencode 'query=instance:node_cpu_utilisation:rate5m' | \
  python3 -c "
import sys,json
for r in json.load(sys.stdin)['data']['result']:
    inst = r['metric'].get('instance','?')
    val  = float(r['value'][1])
    print(f'  {inst}: {val:.1f}%')
"

# Step 3 — Check alert state
curl -s "${ALB}/grafana/api/datasources/proxy/uid/PBFA97CFB590B2093/api/v1/alerts" \
  -u "admin:GrafanaSecure2026" | \
  python3 -c "import sys,json; alerts=json.load(sys.stdin)['data']['alerts']; \
    [print(f'[{a[\"state\"].upper()}] {a[\"labels\"][\"alertname\"]}') for a in alerts] \
    or print('No alerts firing')"
```

**Pass criteria:** `instance:node_cpu_utilisation:rate5m` exceeds 80 on at least one host. `HighCPU` transitions to FIRING within 3 minutes.

---

## Test 4 — Stop All Demo-App Tasks (Composite Alarm)

**Goal:** Trigger the `service-degraded` composite alarm by stopping all running tasks simultaneously.  
**Expected signals:** `ecs-low-task-count` fires → `alb-unhealthy-hosts` fires → composite `service-degraded` fires. SNS email sent.  
**Expected result:** App returns 503. ECS scheduler replaces both tasks automatically.

```bash
ALB="http://flask-sre-ecs-dev-alb-388642593.us-east-1.elb.amazonaws.com"

# Step 1 — Stop all demo-app tasks
TASKS=$(aws ecs list-tasks \
  --cluster flask-sre-ecs-dev-cluster \
  --service-name flask-sre-ecs-dev-demo-app-svc \
  --region us-east-1 \
  --query "taskArns[]" --output text)

for TASK in $TASKS; do
  echo "Stopping: $TASK"
  aws ecs stop-task \
    --cluster flask-sre-ecs-dev-cluster \
    --task "$TASK" \
    --reason "Failure injection test 4 — composite alarm" \
    --region us-east-1
done

# Step 2 — App should return 503
sleep 10
curl -sw "HTTP %{http_code}\n" -o /dev/null "${ALB}/"

# Step 3 — Check composite alarm (fires when BOTH component alarms are ALARM)
aws cloudwatch describe-alarms \
  --alarm-names \
    "flask-sre-ecs-dev-service-degraded" \
    "flask-sre-ecs-dev-ecs-low-task-count" \
    "flask-sre-ecs-dev-alb-unhealthy-hosts" \
  --region us-east-1 \
  --query "MetricAlarms[].{Name:AlarmName,State:StateValue}" \
  --output table

# Step 4 — Watch ECS recover automatically
watch -n 5 "aws ecs describe-services \
  --cluster flask-sre-ecs-dev-cluster \
  --services flask-sre-ecs-dev-demo-app-svc \
  --region us-east-1 \
  --query 'services[0].{Running:runningCount,Desired:desiredCount,Pending:pendingCount}' \
  --output table"
```

**Pass criteria:** App returns 503 while tasks are stopped. `service-degraded` composite alarm fires. SNS email received. Running count returns to 2 without manual intervention.

---

## Test 5 — Kill Grafana Task (Monitoring Unavailable)

**Goal:** Verify monitoring failure is detected without affecting the demo app.  
**Expected signal:** `grafana-unhealthy` CloudWatch alarm fires within 2 minutes.  
**Expected result:** Demo app stays fully operational. Only `/grafana` becomes unreachable.

```bash
ALB="http://flask-sre-ecs-dev-alb-388642593.us-east-1.elb.amazonaws.com"

# Step 1 — Stop the Grafana task
TASK=$(aws ecs list-tasks \
  --cluster flask-sre-ecs-dev-cluster \
  --service-name flask-sre-ecs-dev-grafana-svc \
  --region us-east-1 \
  --query "taskArns[0]" --output text)

aws ecs stop-task \
  --cluster flask-sre-ecs-dev-cluster \
  --task "$TASK" \
  --reason "Failure injection test 5 — grafana unavailable" \
  --region us-east-1

# Step 2 — Demo app should still be healthy
curl -sw "HTTP %{http_code} (demo app)\n" -o /dev/null "${ALB}/"

# Step 3 — Grafana should be unreachable (~30s for ALB health check to fail)
sleep 30
curl -sw "HTTP %{http_code} (grafana)\n" -o /dev/null "${ALB}/grafana/api/health"

# Step 4 — Check grafana-unhealthy alarm
aws cloudwatch describe-alarms \
  --alarm-names "flask-sre-ecs-dev-grafana-unhealthy" \
  --region us-east-1 \
  --query "MetricAlarms[0].{State:StateValue,Reason:StateReason}" \
  --output table

# Step 5 — ECS will restart Grafana automatically (desired_count=1)
# Watch recovery
watch -n 5 "aws ecs describe-services \
  --cluster flask-sre-ecs-dev-cluster \
  --services flask-sre-ecs-dev-grafana-svc \
  --region us-east-1 \
  --query 'services[0].{Running:runningCount,Desired:desiredCount}' \
  --output table"
```

**Pass criteria:** Demo app returns HTTP 200 throughout. `grafana-unhealthy` alarm fires. Grafana task restarts and `/grafana/api/health` returns 200 again.

---

## Test 6 — Run Daily Reliability Report

**Goal:** Verify the report collects metrics from all sources and publishes to SNS.

```bash
cd "week 6"

# Dry run — print to stdout, no SNS publish
python3 scripts/daily-reliability-report.py --dry-run

# Full run — publishes to SNS (email to daniyal.tufail@xgrid.co)
python3 scripts/daily-reliability-report.py
```

**Pass criteria:** Report shows ECS running counts, host CPU/memory/disk, RDS state, both SLO statuses, and alarm states. Email received within 2 minutes when run without `--dry-run`.

---

## Alarm State Check (run after any test)

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix "flask-sre-ecs-dev" \
  --region us-east-1 \
  --query "MetricAlarms[].{Alarm:AlarmName,State:StateValue}" \
  --output table
```

## Reset All Services to Desired State

```bash
# Force demo-app back to 2 tasks
aws ecs update-service \
  --cluster flask-sre-ecs-dev-cluster \
  --service flask-sre-ecs-dev-demo-app-svc \
  --desired-count 2 \
  --force-new-deployment \
  --region us-east-1

# Force Grafana back to 1 task
aws ecs update-service \
  --cluster flask-sre-ecs-dev-cluster \
  --service flask-sre-ecs-dev-grafana-svc \
  --desired-count 1 \
  --force-new-deployment \
  --region us-east-1
```
