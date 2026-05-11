# Load Testing Guide for WordPress ECS HA

This guide shows you how to load test your WordPress deployment and monitor what happens to CPU, memory, tasks, and ALB health during heavy traffic.

## Quick Start: 3-Terminal Setup

You'll need **3 terminals open simultaneously**:

### Terminal 1: Run the Load Test

#### Mild Load Test (100 requests, 10 concurrent)
```bash
cd /home/xgrid/xgrid-internship-bootstrap/week\ 3/environments/dev
ALB_DNS=$(terraform output -raw alb_dns_name)
ab -n 100 -c 10 http://$ALB_DNS/
```

#### Medium Load Test (500 requests, 20 concurrent) — **RECOMMENDED**
```bash
cd /home/xgrid/xgrid-internship-bootstrap/week\ 3/environments/dev
ALB_DNS=$(terraform output -raw alb_dns_name)
ab -n 500 -c 20 http://$ALB_DNS/
```

#### Heavy Load Test (2000 requests, 50 concurrent) — **Warning: May degrade service**
```bash
cd /home/xgrid/xgrid-internship-bootstrap/week\ 3/environments/dev
ALB_DNS=$(terraform output -raw alb_dns_name)
ab -n 2000 -c 50 http://$ALB_DNS/
```

---

### Terminal 2: Watch ECS Service Health

**Copy and paste this entire command block:**
```bash
watch -n 5 'aws ecs describe-services \
  --cluster wordpress-ecs-ha-dev-cluster \
  --services wordpress-ecs-ha-dev-wordpress-svc \
  --region us-east-1 \
  --query "services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount,Status:status}" \
  --output table'
```

**What you'll see:**
- `Desired`: How many tasks should be running (target)
- `Running`: How many are healthy
- `Pending`: How many are starting up
- `Status`: Service state (ACTIVE = good)

---

### Terminal 3: Watch CloudWatch Metrics

#### ECS CPU & Memory Utilization
```bash
watch -n 5 'aws cloudwatch get-metric-statistics \
  --namespace AWS/ECS \
  --metric-name CPUUtilization \
  --dimensions Name=ClusterName,Value=wordpress-ecs-ha-dev-cluster Name=ServiceName,Value=wordpress-ecs-ha-dev-wordpress-svc \
  --statistics Average \
  --start-time $(date -u -d "10 minutes ago" +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --region us-east-1 \
  --query "Datapoints | sort_by(@, &Timestamp) | [-10:]" \
  --output table'
```

#### ALB Response Time & Error Rate
```bash
export ALB_ARN_SUFFIX=$(aws elbv2 describe-load-balancers --region us-east-1 --query "LoadBalancers[?contains(LoadBalancerName, 'wordpress-ecs-ha-dev')].LoadBalancerArn" --output text | sed 's/.*loadbalancer\///' | head -1)

watch -n 5 'aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name TargetResponseTime \
  --dimensions Name=LoadBalancer,Value='"$ALB_ARN_SUFFIX"' \
  --statistics Average \
  --start-time $(date -u -d "10 minutes ago" +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --region us-east-1 \
  --query "Datapoints | sort_by(@, &Timestamp) | [-10:]" \
  --output table'
```

#### ALB Target Health (Healthy vs Unhealthy)
```bash
export TG_ARN=$(aws elbv2 describe-target-groups --region us-east-1 --query "TargetGroups[?contains(TargetGroupName, 'wordpress-ecs-ha-dev')].TargetGroupArn" --output text)

watch -n 5 'aws elbv2 describe-target-health \
  --target-group-arn '$TG_ARN' \
  --region us-east-1 \
  --query "TargetHealthDescriptions[*].{IP:Target.Id,Port:Target.Port,Health:TargetHealth.State,Reason:TargetHealth.Reason}" \
  --output table'
```

---

## What to Expect During Load Test

### Thresholds That Trigger Alarms

Your CloudWatch alarms (defined in `week 3/modules/monitoring/main.tf`) will trigger when:

| Alarm | Metric | Threshold | Duration | Action |
|-------|--------|-----------|----------|--------|
| **ECS High CPU** | `CPUUtilization` | > 80% | 10 min avg | SNS email |
| **ECS High Memory** | `MemoryUtilization` | > 80% | 10 min avg | SNS email |
| **ECS Low Task Count** | `RunningTaskCount` | < 2 | 1 min | SNS email |
| **ALB Unhealthy Hosts** | Unhealthy count | > 0 | 1 min | SNS email |

### Healthy Load Test Indicators ✅

✅ **ECS Tasks remain running** → Desired count stays at 2, Running stays at 2  
✅ **ALB response time < 1 second** → Requests complete quickly  
✅ **No 5XX errors** → WordPress container handles requests  
✅ **CPU stays under 80%** → No alarm threshold breach  
✅ **All targets healthy** → Target health shows "healthy"

### Warning Signs ⚠️

⚠️ **Tasks drop to 0 or 1** → Service can't handle load, recovery kicking in  
⚠️ **Response time spikes > 5 seconds** → Container or DB bottleneck  
⚠️ **5XX error spike** → WordPress crashed or connection pool exhausted  
⚠️ **CPU/Memory breach thresholds** → Alerting fires via SNS  

---

## Understanding the Response: Apache Bench Output

After the load test completes, you'll see something like:

```
This is ApacheBench, Version 2.3
Benchmarking wordpress-ecs-ha-dev-alb-...
Completed 100 requests
Completed 200 requests
...
Finished 500 requests

Server Software:        nginx/1.19.0
Server Hostname:        wordpress-ecs-ha-dev-alb-...
Server Port:            80

Document Path:          /
Document Length:        Variable (bytes)

Concurrency Level:      20
Time taken for tests:   45.234 seconds
Complete requests:      500
Failed requests:        0
Total transferred:      XXX bytes
HTML transferred:       XXX bytes
Requests per second:    11.05 [#/sec] (mean)
Time per request:       1809.36 [ms] (mean, across all concurrent requests)
Time per request:       90.47 [ms] (mean, across concurrent requests)
Transfer rate:          XXX [Kbytes/sec] received
```

**Key metrics to understand:**

- **Requests per second**: Throughput of your ALB (11.05 req/sec in example)
- **Failed requests**: Should be 0 — any failures indicate service degradation
- **Time per request (mean)**: Average response time across all requests
- **Time per request (across concurrent)**: Per-request time in parallel execution

---

## Step-by-Step Walkthrough

### Before Starting
1. Confirm infrastructure is running:
   ```bash
   terraform output -raw alb_dns_name
   ```

2. Verify ECS tasks are healthy:
   ```bash
   aws ecs describe-services --cluster wordpress-ecs-ha-dev-cluster --services wordpress-ecs-ha-dev-wordpress-svc --region us-east-1 --query "services[0].{Running:runningCount,Desired:desiredCount}" --output table
   ```
   Should show: `Desired: 2, Running: 2`

### During Load Test

**Terminal 1:** Launch Apache Bench  
**Terminal 2:** Watch ECS task count stay at 2  
**Terminal 3:** Watch CPU/memory/response time climb

**Expected sequence:**
```
T=0s   :  Load test starts, CPU rises
T=5-10s:  Response times increase, all targets still healthy
T=15-30s: Peak load, CPU at 50-70%, memory at 40-60%, response time 500-1500ms
T=30s+ :  Load test completes, metrics stabilize
```

### After Load Test

1. **Check if alarms fired:**
   ```bash
   aws cloudwatch describe-alarms --state-value ALARM --region us-east-1 --query "MetricAlarms[?contains(AlarmName, 'wordpress')].{Name:AlarmName,State:StateValue,Reason:StateReason}" --output table
   ```

2. **Verify tasks recovered:**
   ```bash
   aws ecs describe-services --cluster wordpress-ecs-ha-dev-cluster --services wordpress-ecs-ha-dev-wordpress-svc --region us-east-1 --query "services[0].{Running:runningCount,Desired:desiredCount}" --output table
   ```

3. **Check email for SNS alerts** (if alarms triggered)

---

## Advanced: Monitoring with CloudWatch Dashboard

Your infrastructure has a pre-built CloudWatch dashboard at:
```
AWS Console → CloudWatch → Dashboards → wordpress-ecs-ha-dev-dashboard
```

It shows 9 widgets in real-time:
1. ECS CPU %
2. ECS Memory %
3. Running Tasks (count)
4. ALB Requests/min
5. ALB 5XX Errors
6. ALB Response Time
7. RDS CPU %
8. RDS DB Connections
9. RDS Free Storage Space

### Access Dashboard via CLI
```bash
aws cloudwatch get-dashboard --dashboard-name wordpress-ecs-ha-dev-dashboard --region us-east-1 | jq '.DashboardBody | fromjson'
```

---

## Troubleshooting Load Test Issues

### "Connection refused" or "timeout"
- WordPress container may not be running
- Check: `aws ecs describe-services --cluster wordpress-ecs-ha-dev-cluster --services wordpress-ecs-ha-dev-wordpress-svc --region us-east-1`
- Fix: Re-run `terraform apply` to restore tasks

### "apr_pollset_poll: timeout expired"
- Load test was too aggressive and timed out
- Use fewer concurrent connections: `ab -n 500 -c 20` instead of `-c 50`
- Or increase timeout: `ab -n 500 -c 50 -s 60` (60-second timeout)

### "All tasks stopped during load test"
- CPU/memory utilization exceeded hard limits
- ECS service recovered them (check running count)
- This is the HA mechanism working as designed
- For production, increase task CPU/memory in `week 3/modules/ecs/main.tf`

### "Alarms fired but service stayed healthy"
- This is expected! Alarms fire based on thresholds (80% CPU for 10 min)
- SNS emails should have arrived
- Check spam folder if you didn't see them

---

## Next Steps: Scaling for Production

If your load test shows the service is struggling:

1. **Increase ECS task resources:**
   Edit `week 3/modules/ecs/main.tf`, find the task definition, and increase:
   ```hcl
   cpu    = "512"   # Increase from 256
   memory = "1024"  # Increase from 512
   ```

2. **Add more ECS tasks:**
   Edit `week 3/modules/ecs/main.tf`, increase:
   ```hcl
   desired_count = 4  # From 2
   ```

3. **Enable ALB autoscaling:**
   Add autoscaling policy in `week 3/modules/ecs/main.tf` based on CPU/memory

4. **Scale RDS database:**
   Edit `week 3/modules/rds/main.tf`:
   ```hcl
   instance_class = "db.t3.small"  # From db.t3.micro
   multi_az       = true           # For HA
   ```

---

## Quick Reference Commands

```bash
# Get ALB DNS
terraform output -raw alb_dns_name

# Check service status
aws ecs describe-services --cluster wordpress-ecs-ha-dev-cluster --services wordpress-ecs-ha-dev-wordpress-svc --region us-east-1 --query "services[0].{Desired:desiredCount,Running:runningCount}" --output table

# Get CPU metrics
aws cloudwatch get-metric-statistics --namespace AWS/ECS --metric-name CPUUtilization --dimensions Name=ClusterName,Value=wordpress-ecs-ha-dev-cluster Name=ServiceName,Value=wordpress-ecs-ha-dev-wordpress-svc --statistics Average --start-time $(date -u -d "1 hour ago" +%Y-%m-%dT%H:%M:%S) --end-time $(date -u +%Y-%m-%dT%H:%M:%S) --period 300 --region us-east-1

# Check alarms
aws cloudwatch describe-alarms --state-value ALARM --region us-east-1 --query "MetricAlarms[?contains(AlarmName, 'wordpress')].{Name:AlarmName,State:StateValue}" --output table

# List tasks
aws ecs list-tasks --cluster wordpress-ecs-ha-dev-cluster --region us-east-1

# Inspect a stopped task
aws ecs describe-tasks --cluster wordpress-ecs-ha-dev-cluster --tasks <TASK_ARN> --region us-east-1 --query "tasks[0].{StopReason:stoppedReason,Status:lastStatus,CreatedAt:createdAt}"
```

