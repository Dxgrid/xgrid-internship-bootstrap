# WordPress ECS HA — SRE Runbook

_Last updated: 2026-05-21 | Owner: daniyal.tufail@xgrid.co_

---

## 1. Service Overview

This stack runs WordPress 6.5 on Amazon ECS (EC2 launch type) in a high-availability configuration across two Availability Zones, backed by RDS MySQL 8.0 and shared EFS storage. Traffic enters through an Application Load Balancer that routes WordPress requests to two ECS tasks and Grafana traffic to a dedicated monitoring EC2. Uptime matters because WordPress is the customer-facing web property: every minute of downtime is a direct user impact, and SLO-1 budgets only 3 hours 36 minutes of 5xx responses per calendar month before the error budget is exhausted.

---

## 2. Quick Reference

| Resource | Value |
|---|---|
| Grafana | http://wordpress-ecs-ha-dev-alb-1325349632.us-east-1.elb.amazonaws.com/grafana |
| Prometheus | http://98.92.178.35:9090 |
| RDS endpoint | terraform-2026052004531822060000000b.ckn6gqcccz2y.us-east-1.rds.amazonaws.com |
| SNS topic | arn:aws:sns:us-east-1:432500708329:wordpress-ecs-ha-dev-alerts |
| ECS cluster | wordpress-ecs-ha-dev-cluster |
| ECS service | wordpress-ecs-ha-dev-wordpress-svc |
| CloudWatch log group | /ecs/wordpress-ecs-ha/dev/wordpress |
| Daily report log | /var/log/daily-report.log (on monitoring EC2) |

---

## 3. Alert Playbooks

---

### wordpress-ecs-ha-dev-ecs-high-cpu

**What it means:** ECS WordPress service CPU utilization has exceeded 70% for 10 consecutive minutes, indicating sustained compute pressure that may degrade response time.
**Severity:** SEV-2

**First action:**
```bash
aws ecs describe-services --cluster wordpress-ecs-ha-dev-cluster \
  --services wordpress-ecs-ha-dev-wordpress-svc \
  --region us-east-1 \
  --query "services[0].{Running:runningCount,Desired:desiredCount,CPU:deployments}"
```

**Triage steps:**
1. Check Grafana ECS CPU panel at http://wordpress-ecs-ha-dev-alb-1325349632.us-east-1.elb.amazonaws.com/grafana — if trending down, monitor and close; if still rising, continue.
2. Check whether traffic spike is causing the load:
   ```bash
   aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB \
     --metric-name RequestCount \
     --dimensions Name=LoadBalancer,Value=app/wordpress-ecs-ha-dev-alb/355411d356f09837 \
     --start-time $(date -u -d '30 minutes ago' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
     --period 60 --statistics Sum --region us-east-1
   ```
   If request count is elevated → traffic-driven; consider scaling. If request count is normal → suspect a runaway process.
3. Check CloudWatch logs for PHP errors or slow processes:
   ```bash
   aws logs filter-log-events --log-group-name /ecs/wordpress-ecs-ha/dev/wordpress \
     --start-time $(date -d '15 minutes ago' +%s000) \
     --filter-pattern "ERROR" --region us-east-1 --limit 20
   ```
   If PHP Fatal or out-of-memory errors found → force redeploy (see section 5).
4. If load is sustained and legitimate, temporarily scale to 3 tasks:
   ```bash
   aws ecs update-service --cluster wordpress-ecs-ha-dev-cluster \
     --service wordpress-ecs-ha-dev-wordpress-svc --desired-count 3 --region us-east-1
   ```
5. If CPU does not drop below 60% within 10 minutes after scaling → escalate.

**Resolution:** CloudWatch alarm returns to OK state; CPU sustained below 70% for two evaluation periods.
**Escalate if:** CPU exceeds 90% or task crashes occur alongside sustained high CPU.

---

### wordpress-ecs-ha-dev-ecs-high-memory

**What it means:** ECS WordPress service memory utilization has exceeded 75% for 10 consecutive minutes; at 100% the container is OOM-killed.
**Severity:** SEV-2

**First action:**
```bash
aws cloudwatch get-metric-statistics --namespace AWS/ECS \
  --metric-name MemoryUtilization \
  --dimensions Name=ClusterName,Value=wordpress-ecs-ha-dev-cluster \
              Name=ServiceName,Value=wordpress-ecs-ha-dev-wordpress-svc \
  --start-time $(date -u -d '30 minutes ago' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
  --period 60 --statistics Average --region us-east-1
```

**Triage steps:**
1. Check Grafana ECS Memory panel — if value is above 90% → treat as SEV-1, proceed to step 4 immediately.
2. Check for stopped tasks (OOM kills already occurring):
   ```bash
   aws ecs list-tasks --cluster wordpress-ecs-ha-dev-cluster \
     --desired-status STOPPED --region us-east-1 \
     --query "taskArns[:5]" --output text
   ```
   If stopped tasks exist → run describe on them for stop reason (see section 5 command).
3. Check logs for memory-related errors:
   ```bash
   aws logs filter-log-events --log-group-name /ecs/wordpress-ecs-ha/dev/wordpress \
     --start-time $(date -d '20 minutes ago' +%s000) \
     --filter-pattern "memory" --region us-east-1 --limit 20
   ```
   If memory errors logged → restart the service with a force redeploy.
4. Force new deployment to recycle containers and clear any memory leak:
   ```bash
   aws ecs update-service --cluster wordpress-ecs-ha-dev-cluster \
     --service wordpress-ecs-ha-dev-wordpress-svc \
     --force-new-deployment --region us-east-1
   ```
5. If memory returns above 75% after redeploy → the task CPU/memory allocation (256/512) is undersized for current load; escalate.

**Resolution:** Alarm returns to OK; memory sustained below 75% for two evaluation periods.
**Escalate if:** Tasks are actively being OOM-killed (running count drops) or memory stays above 90% after redeploy.

---

### wordpress-ecs-ha-dev-ecs-low-task-count

**What it means:** Fewer than 2 ECS tasks are running, meaning HA is degraded — the service is operating on a single task or has failed entirely.
**Severity:** SEV-1

**First action:**
```bash
aws ecs describe-services --cluster wordpress-ecs-ha-dev-cluster \
  --services wordpress-ecs-ha-dev-wordpress-svc --region us-east-1 \
  --query "services[0].{Running:runningCount,Desired:desiredCount,Pending:pendingCount}"
```

**Triage steps:**
1. If `runningCount == 0` → service is completely down; jump to step 4 immediately.
2. Check why tasks stopped — get the stop reason:
   ```bash
   aws ecs list-tasks --cluster wordpress-ecs-ha-dev-cluster \
     --desired-status STOPPED --region us-east-1 --query "taskArns[:3]" --output text | \
   xargs -I{} aws ecs describe-tasks --cluster wordpress-ecs-ha-dev-cluster \
     --tasks {} --region us-east-1 \
     --query "tasks[].{StopCode:stopCode,StopReason:stoppedReason}"
   ```
   If `EssentialContainerExited` → container crashed; check logs. If `CannotPullContainerError` → image pull issue.
3. Check CloudWatch logs for crash details:
   ```bash
   aws logs filter-log-events --log-group-name /ecs/wordpress-ecs-ha/dev/wordpress \
     --start-time $(date -d '15 minutes ago' +%s000) --region us-east-1 --limit 30
   ```
4. Force ECS to launch replacement tasks:
   ```bash
   aws ecs update-service --cluster wordpress-ecs-ha-dev-cluster \
     --service wordpress-ecs-ha-dev-wordpress-svc \
     --force-new-deployment --region us-east-1
   ```
5. Monitor recovery — task count should return to 2 within 2–3 minutes:
   ```bash
   watch -n 10 "aws ecs describe-services --cluster wordpress-ecs-ha-dev-cluster \
     --services wordpress-ecs-ha-dev-wordpress-svc --region us-east-1 \
     --query 'services[0].{Running:runningCount,Desired:desiredCount}'"
   ```

**Resolution:** `runningCount == 2`; `ecs-low-task-count` alarm returns to OK.
**Escalate if:** Tasks launch and stop repeatedly (crash loop) or `runningCount` does not reach 2 within 10 minutes.

---

### wordpress-ecs-ha-dev-alb-5xx

**What it means:** The ALB 5xx error rate has exceeded 0.5% of total requests for 2 consecutive minutes — this is the SLO-1 breach boundary for 99.5% HTTP availability.
**Severity:** SEV-1

**First action:**
```bash
aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB \
  --metric-name HTTPCode_Target_5XX_Count \
  --dimensions Name=LoadBalancer,Value=app/wordpress-ecs-ha-dev-alb/355411d356f09837 \
  --start-time $(date -u -d '10 minutes ago' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
  --period 60 --statistics Sum --region us-east-1
```

**Triage steps:**
1. Check whether ECS tasks are healthy — if `ecs-low-task-count` is also in ALARM, treat as full outage and work that playbook first.
2. Check ALB target health directly:
   ```bash
   aws elbv2 describe-target-health \
     --target-group-arn arn:aws:elasticloadbalancing:us-east-1:432500708329:targetgroup/wp-tg-20260520045259208400000005/0f99d4fd19b1676b \
     --region us-east-1 \
     --query "TargetHealthDescriptions[].{Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}"
   ```
   If targets show `unhealthy` → proceed to ecs-low-task-count or alb-unhealthy-hosts playbook.
3. Check application logs for PHP errors or 500s:
   ```bash
   aws logs filter-log-events --log-group-name /ecs/wordpress-ecs-ha/dev/wordpress \
     --start-time $(date -d '15 minutes ago' +%s000) \
     --filter-pattern "PHP Fatal" --region us-east-1 --limit 20
   ```
   If fatal errors found → force redeploy.
4. Check RDS — 5xx errors often mean the database is unreachable:
   ```bash
   aws rds describe-db-instances \
     --db-instance-identifier terraform-2026052004531822060000000b \
     --region us-east-1 \
     --query "DBInstances[0].{Status:DBInstanceStatus,Connections:Endpoint}"
   ```
   If RDS status is not `available` → work rds playbooks.
5. If application logs and RDS are normal → force redeploy to cycle containers:
   ```bash
   aws ecs update-service --cluster wordpress-ecs-ha-dev-cluster \
     --service wordpress-ecs-ha-dev-wordpress-svc --force-new-deployment --region us-east-1
   ```

**Resolution:** 5xx alarm returns to OK; error rate below 0.5% sustained for 2 minutes.
**Escalate if:** Error rate exceeds 5% or error count does not trend downward within 15 minutes.

---

### wordpress-ecs-ha-dev-alb-unhealthy-hosts

**What it means:** One or more ECS tasks are failing ALB health checks, meaning those tasks are receiving no traffic but are still consuming capacity.
**Severity:** SEV-2

**First action:**
```bash
aws elbv2 describe-target-health \
  --target-group-arn arn:aws:elasticloadbalancing:us-east-1:432500708329:targetgroup/wp-tg-20260520045259208400000005/0f99d4fd19b1676b \
  --region us-east-1 \
  --query "TargetHealthDescriptions[].{IP:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}"
```

**Triage steps:**
1. Note the `Reason` field from the first action — `Target.ResponseCodeMismatch` means the app is returning a non-200/302 response; `Target.Timeout` means the app is not responding within 5 seconds.
2. Check WordPress is reachable through the ALB:
   ```bash
   curl -o /dev/null -s -w "%{http_code}" \
     http://wordpress-ecs-ha-dev-alb-1325349632.us-east-1.elb.amazonaws.com/
   ```
   If HTTP 200 or 302 → one task is healthy, one is not; partial failure.
3. Check logs for the unhealthy task:
   ```bash
   aws logs filter-log-events --log-group-name /ecs/wordpress-ecs-ha/dev/wordpress \
     --start-time $(date -d '10 minutes ago' +%s000) \
     --filter-pattern "error" --region us-east-1 --limit 30
   ```
4. Check RDS connectivity — health check failures are often caused by RDS being unavailable:
   ```bash
   aws cloudwatch get-metric-statistics --namespace AWS/RDS \
     --metric-name DatabaseConnections \
     --dimensions Name=DBInstanceIdentifier,Value=terraform-2026052004531822060000000b \
     --start-time $(date -u -d '15 minutes ago' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
     --period 60 --statistics Average --region us-east-1
   ```
   If connections are 0 → RDS issue is root cause.
5. Force redeploy to replace unhealthy tasks with fresh containers:
   ```bash
   aws ecs update-service --cluster wordpress-ecs-ha-dev-cluster \
     --service wordpress-ecs-ha-dev-wordpress-svc --force-new-deployment --region us-east-1
   ```

**Resolution:** All targets return to `healthy` state; alarm clears.
**Escalate if:** Both tasks show unhealthy simultaneously, or tasks cycle through healthy/unhealthy repeatedly.

---

### wordpress-ecs-ha-dev-alb-traffic-drop

**What it means:** The ALB has received fewer than 5 requests per minute for 3 consecutive minutes — indicating an upstream failure, DNS issue, or complete loss of traffic to the service.
**Severity:** SEV-2

**First action:**
```bash
curl -o /dev/null -s -w "%{http_code}\n" \
  http://wordpress-ecs-ha-dev-alb-1325349632.us-east-1.elb.amazonaws.com/
```

**Triage steps:**
1. If the curl returns any HTTP response → ALB is reachable; the drop may be legitimate low traffic (off-peak hours). Check the time and compare to normal traffic patterns in Grafana.
2. If curl times out or fails → ALB may be unreachable; check ALB status:
   ```bash
   aws elbv2 describe-load-balancers \
     --names wordpress-ecs-ha-dev-alb --region us-east-1 \
     --query "LoadBalancers[0].{State:State.Code,DNSName:DNSName}"
   ```
3. Verify DNS resolution is working:
   ```bash
   nslookup wordpress-ecs-ha-dev-alb-1325349632.us-east-1.elb.amazonaws.com
   ```
   If resolution fails → DNS propagation or Route 53 issue.
4. Check ALB listener rules are intact:
   ```bash
   aws elbv2 describe-listeners \
     --load-balancer-arn arn:aws:elasticloadbalancing:us-east-1:432500708329:loadbalancer/app/wordpress-ecs-ha-dev-alb/355411d356f09837 \
     --region us-east-1 \
     --query "Listeners[].{Port:Port,Protocol:Protocol,DefaultAction:DefaultActions[0].Type}"
   ```
5. Check ECS tasks are running and registered to target group:
   ```bash
   aws ecs describe-services --cluster wordpress-ecs-ha-dev-cluster \
     --services wordpress-ecs-ha-dev-wordpress-svc --region us-east-1 \
     --query "services[0].{Running:runningCount,Desired:desiredCount}"
   ```

**Resolution:** RequestCount returns above 5/min; alarm clears after 3 minutes.
**Escalate if:** ALB is reachable and ECS tasks are running but traffic is still being reported as dropped.

---

### wordpress-ecs-ha-dev-rds-high-cpu

**What it means:** RDS MySQL CPU utilization has exceeded 70% for 15 consecutive minutes, which on a db.t3.micro indicates slow queries or connection pressure that will degrade WordPress page load times.
**Severity:** SEV-2

**First action:**
```bash
aws cloudwatch get-metric-statistics --namespace AWS/RDS \
  --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=terraform-2026052004531822060000000b \
  --start-time $(date -u -d '30 minutes ago' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
  --period 300 --statistics Average --region us-east-1
```

**Triage steps:**
1. Check the slow query log in CloudWatch for long-running queries:
   ```bash
   aws logs filter-log-events \
     --log-group-name /aws/rds/instance/terraform-2026052004531822060000000b/slowquery \
     --start-time $(date -d '30 minutes ago' +%s000) --region us-east-1 --limit 20
   ```
   If slow queries found → identify the query pattern and consider adding an index or caching layer.
2. Check current active connection count:
   ```bash
   aws cloudwatch get-metric-statistics --namespace AWS/RDS \
     --metric-name DatabaseConnections \
     --dimensions Name=DBInstanceIdentifier,Value=terraform-2026052004531822060000000b \
     --start-time $(date -u -d '15 minutes ago' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
     --period 60 --statistics Average --region us-east-1
   ```
   If connections are near 60 → also work the rds-high-connections playbook.
3. Check if a recent WordPress deployment or plugin activation correlates with the CPU spike — compare the spike start time to ECS deployment events in Grafana.
4. Force-redeploy ECS to recycle WordPress connections and clear any runaway query loops:
   ```bash
   aws ecs update-service --cluster wordpress-ecs-ha-dev-cluster \
     --service wordpress-ecs-ha-dev-wordpress-svc --force-new-deployment --region us-east-1
   ```
5. If CPU remains above 70% after ECS redeploy → RDS needs investigation at the database level; escalate.

**Resolution:** RDS CPU drops below 70%; alarm clears after 3 evaluation periods.
**Escalate if:** CPU exceeds 90% or the instance is showing `BurstBalance` exhaustion (db.t3.micro uses burstable credits).

---

### wordpress-ecs-ha-dev-rds-low-storage

**What it means:** RDS free storage has fallen below 2 GB; autoscaling is enabled up to 100 GB, but if writes are faster than autoscaling can respond, the instance risks running out of space and refusing writes.
**Severity:** SEV-2

**First action:**
```bash
aws cloudwatch get-metric-statistics --namespace AWS/RDS \
  --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value=terraform-2026052004531822060000000b \
  --start-time $(date -u -d '60 minutes ago' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
  --period 300 --statistics Minimum --region us-east-1
```

**Triage steps:**
1. Check current allocated vs used storage:
   ```bash
   aws rds describe-db-instances \
     --db-instance-identifier terraform-2026052004531822060000000b --region us-east-1 \
     --query "DBInstances[0].{AllocatedGB:AllocatedStorage,Status:DBInstanceStatus}"
   ```
   If `AllocatedStorage` has grown → autoscaling already triggered. If still at original 20 GB → autoscaling has not fired yet.
2. Check if autoscale is in progress (status will show `storage-optimization`):
   ```bash
   aws rds describe-db-instances \
     --db-instance-identifier terraform-2026052004531822060000000b --region us-east-1 \
     --query "DBInstances[0].DBInstanceStatus"
   ```
3. Check the RDS error log for out-of-space errors:
   ```bash
   aws logs filter-log-events \
     --log-group-name /aws/rds/instance/terraform-2026052004531822060000000b/error \
     --start-time $(date -d '60 minutes ago' +%s000) --region us-east-1 --limit 20
   ```
   If "no space left" errors → WordPress is actively failing writes; escalate immediately.
4. Check binlog size — this is the most common source of unexpected RDS storage growth. Review slow query logs for large transactions or bulk inserts.
5. If autoscaling has not kicked in and free storage is below 1 GB → manually modify the instance to increase storage:
   ```bash
   aws rds modify-db-instance \
     --db-instance-identifier terraform-2026052004531822060000000b \
     --allocated-storage 40 --apply-immediately --region us-east-1
   ```

**Resolution:** Free storage returns above 5 GB (SLO-4 target); alarm clears.
**Escalate if:** Storage drops below 500 MB or WordPress starts returning database write errors.

---

### wordpress-ecs-ha-dev-rds-high-connections

**What it means:** Active database connections have exceeded 60, which is 70% of the db.t3.micro `max_connections` value of 100 (set via parameter group). Above 100, new connections are refused and WordPress returns 500 errors.
**Severity:** SEV-2

**First action:**
```bash
aws cloudwatch get-metric-statistics --namespace AWS/RDS \
  --metric-name DatabaseConnections \
  --dimensions Name=DBInstanceIdentifier,Value=terraform-2026052004531822060000000b \
  --start-time $(date -u -d '20 minutes ago' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
  --period 60 --statistics Average --region us-east-1
```

**Triage steps:**
1. Check how many ECS tasks are running — each WordPress task holds a pool of DB connections:
   ```bash
   aws ecs describe-services --cluster wordpress-ecs-ha-dev-cluster \
     --services wordpress-ecs-ha-dev-wordpress-svc --region us-east-1 \
     --query "services[0].runningCount"
   ```
   If running count is above 2 (e.g., during a rolling deploy) → wait for the deploy to complete and connections will normalize.
2. Check whether connections are trending up or stabilizing in Grafana "DB Connections" panel at http://wordpress-ecs-ha-dev-alb-1325349632.us-east-1.elb.amazonaws.com/grafana — if stabilizing, monitor; if still rising, continue.
3. Check for stuck connections by reviewing RDS error logs:
   ```bash
   aws logs filter-log-events \
     --log-group-name /aws/rds/instance/terraform-2026052004531822060000000b/error \
     --start-time $(date -d '20 minutes ago' +%s000) --region us-east-1 --limit 20
   ```
4. Force-redeploy ECS to recycle WordPress connection pools:
   ```bash
   aws ecs update-service --cluster wordpress-ecs-ha-dev-cluster \
     --service wordpress-ecs-ha-dev-wordpress-svc --force-new-deployment --region us-east-1
   ```
5. If connections remain above 80 after redeploy → the application connection pool is misconfigured or there is a connection leak; escalate.

**Resolution:** DatabaseConnections metric drops below 60; alarm clears after 2 evaluation periods.
**Escalate if:** Connections reach 90+ (near exhaustion) or WordPress is already returning 500 errors.

---

### wordpress-ecs-ha-dev-grafana-unhealthy

**What it means:** The Grafana ALB target group health check is failing — the monitoring UI is unreachable via the ALB, though the underlying monitoring EC2 may still be running.
**Severity:** SEV-3

**First action:**
```bash
curl -o /dev/null -s -w "%{http_code}\n" \
  http://wordpress-ecs-ha-dev-alb-1325349632.us-east-1.elb.amazonaws.com/grafana/api/health
```

**Triage steps:**
1. If curl returns 200 → ALB routing has recovered; alarm may be clearing. Monitor and close.
2. Check monitoring EC2 instance state:
   ```bash
   aws ec2 describe-instances \
     --filters "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
     --region us-east-1 \
     --query "Reservations[].Instances[].{ID:InstanceId,State:State.Name,IP:PublicIpAddress}"
   ```
   If instance is stopped → start it. If terminated → monitoring EC2 needs to be re-provisioned via Terraform.
3. SSM into the monitoring EC2 and check Docker container status:
   ```bash
   aws ssm send-command \
     --instance-ids $(aws ec2 describe-instances \
       --filters "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
       --region us-east-1 --query "Reservations[0].Instances[0].InstanceId" --output text) \
     --document-name "AWS-RunShellScript" \
     --parameters 'commands=["docker ps --format \"table {{.Names}}\t{{.Status}}\""]' \
     --region us-east-1
   ```
   If Grafana container is not running → restart it (step 4).
4. Restart Prometheus and Grafana via SSM:
   ```bash
   aws ssm send-command \
     --instance-ids $(aws ec2 describe-instances \
       --filters "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
       --region us-east-1 --query "Reservations[0].Instances[0].InstanceId" --output text) \
     --document-name "AWS-RunShellScript" \
     --parameters 'commands=["cd /opt/monitoring && docker compose down && docker compose up -d"]' \
     --region us-east-1
   ```
5. Wait 60 seconds for Grafana to start, then re-test the health endpoint.

**Resolution:** `/grafana/api/health` returns HTTP 200; alarm clears.
**Escalate if:** Monitoring EC2 is terminated and needs re-provisioning, or Docker fails to start.

---

### wordpress-ecs-ha-dev-service-degraded (composite)

**What it means:** Both `ecs-low-task-count` AND `alb-unhealthy-hosts` are simultaneously in ALARM — this is a confirmed full service outage. WordPress is down and not recovering automatically.
**Severity:** SEV-1 — page immediately

**First action:**
```bash
curl -o /dev/null -s -w "%{http_code}\n" \
  http://wordpress-ecs-ha-dev-alb-1325349632.us-east-1.elb.amazonaws.com/
```

**Triage steps:**
1. Confirm both component alarms are active:
   ```bash
   aws cloudwatch describe-alarms \
     --alarm-names wordpress-ecs-ha-dev-ecs-low-task-count wordpress-ecs-ha-dev-alb-unhealthy-hosts \
     --region us-east-1 --query "MetricAlarms[].{Name:AlarmName,State:StateValue}"
   ```
2. Check how many tasks are running and why they stopped:
   ```bash
   aws ecs describe-services --cluster wordpress-ecs-ha-dev-cluster \
     --services wordpress-ecs-ha-dev-wordpress-svc --region us-east-1 \
     --query "services[0].{Running:runningCount,Desired:desiredCount,Events:events[:3]}"
   ```
3. Check ECS capacity — if EC2 instances in the ASG are not running, ECS cannot place tasks:
   ```bash
   aws autoscaling describe-auto-scaling-groups \
     --region us-east-1 \
     --query "AutoScalingGroups[?contains(AutoScalingGroupName,'wordpress-ecs-ha-dev-ecs-asg')].{Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,Instances:Instances[].LifecycleState}"
   ```
   If no InService instances → ASG has scaled to 0 or instances are terminated; investigate ASG events.
4. Force a new deployment to attempt task recovery:
   ```bash
   aws ecs update-service --cluster wordpress-ecs-ha-dev-cluster \
     --service wordpress-ecs-ha-dev-wordpress-svc \
     --force-new-deployment --region us-east-1
   ```
5. Monitor recovery every 30 seconds:
   ```bash
   watch -n 30 "aws ecs describe-services --cluster wordpress-ecs-ha-dev-cluster \
     --services wordpress-ecs-ha-dev-wordpress-svc --region us-east-1 \
     --query 'services[0].{Running:runningCount,Desired:desiredCount,Pending:pendingCount}'"
   ```

**Resolution:** `runningCount == 2`, both alarms return to OK, composite alarm clears.
**Escalate if:** Tasks do not launch within 10 minutes or the root cause is not recoverable by redeploy (e.g., ASG failure, RDS down, EFS unmountable).

---

### DiskAlmostFull (Prometheus)

**What it means:** A Node Exporter target (ECS EC2 host) has less than 15% disk space free on the root filesystem for 5 consecutive minutes; Prometheus TSDB write failures or ECS task evictions may follow.
**Severity:** SEV-2

**First action:**
```bash
curl -s 'http://98.92.178.35:9090/api/v1/query?query=100-(node_filesystem_avail_bytes{mountpoint="/"}/node_filesystem_size_bytes{mountpoint="/"}*100)' \
  | python3 -m json.tool | grep -A3 '"result"'
```

**Triage steps:**
1. Identify which instance is affected from the Prometheus query result — note the `instance` label (private IP:9100).
2. Find the EC2 instance ID for that private IP:
   ```bash
   aws ec2 describe-instances \
     --filters "Name=network-interface.addresses.private-ip-address,Values=<private-ip>" \
     --region us-east-1 \
     --query "Reservations[0].Instances[0].InstanceId" --output text
   ```
3. SSM into that instance and check disk usage by directory:
   ```bash
   aws ssm send-command \
     --instance-ids <instance-id> \
     --document-name "AWS-RunShellScript" \
     --parameters 'commands=["df -h /","du -sh /var/lib/docker/*"]' \
     --region us-east-1
   ```
   If Docker layers are consuming space → prune unused images: `docker image prune -af`.
4. Check ECS task logs volume — old log files accumulate in `/var/log/ecs/`:
   ```bash
   aws ssm send-command --instance-ids <instance-id> \
     --document-name "AWS-RunShellScript" \
     --parameters 'commands=["du -sh /var/log/ecs/ /var/log/docker"]' \
     --region us-east-1
   ```
5. If disk is under 5% → stop non-essential containers temporarily and notify on-call; replacement EC2 may be needed.

**Resolution:** Prometheus `DiskAlmostFull` alert clears; disk free returns above 15%.
**Escalate if:** Disk is below 5% or the affected instance is hosting running ECS tasks with no room to pull images.

---

### HighMemory (Prometheus)

**What it means:** A Node Exporter target (ECS EC2 host) has less than 20% memory free for 5 consecutive minutes; the ECS agent may begin evicting tasks.
**Severity:** SEV-2

**First action:**
```bash
curl -s 'http://98.92.178.35:9090/api/v1/query?query=100*(node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes)' \
  | python3 -m json.tool | grep -A5 '"result"'
```

**Triage steps:**
1. Note which instance (by `instance` label) is under memory pressure.
2. Check ECS task count on that host:
   ```bash
   aws ecs list-tasks --cluster wordpress-ecs-ha-dev-cluster \
     --container-instance <container-instance-arn> --region us-east-1
   ```
   If more than 1 WordPress task is on this host → ECS placement is unbalanced; a redeploy with spread strategy will rebalance.
3. Check if a Node Exporter metric shows a specific process consuming memory via Grafana "Host Memory" panel at http://wordpress-ecs-ha-dev-alb-1325349632.us-east-1.elb.amazonaws.com/grafana.
4. Check ECS agent is not accumulating memory (known issue on long-running Amazon Linux instances):
   ```bash
   aws ssm send-command --instance-ids <instance-id> \
     --document-name "AWS-RunShellScript" \
     --parameters 'commands=["free -m","ps aux --sort=-%mem | head -10"]' \
     --region us-east-1
   ```
5. If memory is critically low (< 5%) and tasks are at risk → scale ECS service to reduce task density on this host:
   ```bash
   aws ecs update-service --cluster wordpress-ecs-ha-dev-cluster \
     --service wordpress-ecs-ha-dev-wordpress-svc --force-new-deployment --region us-east-1
   ```

**Resolution:** Prometheus `HighMemory` alert clears; available memory returns above 20%.
**Escalate if:** Available memory drops below 5% or ECS tasks begin stopping due to memory pressure.

---

### NodeDown (Prometheus)

**What it means:** Prometheus cannot reach Node Exporter on port 9100 for a specific ECS EC2 host for at least 1 minute; that host's metrics are missing and its health is unknown.
**Severity:** SEV-2

**First action:**
```bash
curl -s 'http://98.92.178.35:9090/api/v1/targets' \
  | python3 -m json.tool | grep -B2 '"health":"down"'
```

**Triage steps:**
1. Note the `instance` label (private IP:9100) of the down target.
2. Check whether that EC2 instance is still running:
   ```bash
   aws ec2 describe-instances \
     --filters "Name=private-ip-address,Values=<private-ip>" \
     --region us-east-1 \
     --query "Reservations[0].Instances[0].{State:State.Name,ID:InstanceId}"
   ```
   If instance state is `stopped` or `terminated` → ASG has replaced it; wait for discovery script to update targets.
3. If instance is running, check whether Node Exporter container is still up:
   ```bash
   aws ssm send-command --instance-ids <instance-id> \
     --document-name "AWS-RunShellScript" \
     --parameters 'commands=["docker ps | grep node_exporter"]' \
     --region us-east-1
   ```
   If container is not running → restart it.
4. Restart Node Exporter if stopped:
   ```bash
   aws ssm send-command --instance-ids <instance-id> \
     --document-name "AWS-RunShellScript" \
     --parameters 'commands=["docker start node_exporter || docker run -d --name node_exporter --restart always --net host --pid host -v /proc:/host/proc:ro -v /sys:/host/sys:ro -v /:/rootfs:ro quay.io/prometheus/node-exporter:v1.8.1 --path.procfs=/host/proc --path.sysfs=/host/sys --path.rootfs=/rootfs --web.listen-address=:9100"]' \
     --region us-east-1
   ```
5. Trigger the ECS node discovery script to refresh Prometheus targets:
   ```bash
   aws ssm send-command \
     --instance-ids $(aws ec2 describe-instances \
       --filters "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
       --region us-east-1 --query "Reservations[0].Instances[0].InstanceId" --output text) \
     --document-name "AWS-RunShellScript" \
     --parameters 'commands=["/opt/monitoring/scripts/discover_ecs_nodes.sh && echo done"]' \
     --region us-east-1
   ```

**Resolution:** Prometheus target returns to `health: up`; `NodeDown` alert clears.
**Escalate if:** Node Exporter cannot be restarted and the EC2 instance is running ECS tasks that are impacting availability.

---

## 4. SLO Reference

| SLO | Target | Monthly Error Budget | Covering Alarm |
|---|---|---|---|
| SLO-1: HTTP Availability | ≥ 99.5% of requests return non-5xx | 3 h 36 m of downtime | `wordpress-ecs-ha-dev-alb-5xx` (> 0.5% for 2 min) |
| SLO-2: p95 Latency | p95 response time ≤ 2.0 s for 95% of 5-min windows | 36 windows/month above threshold | No dedicated alarm — monitor via Grafana "Response Time" panel |
| SLO-3: Task Availability | ≥ 1 ECS task running 99.9% of the time | 43.8 min/month at zero tasks | `wordpress-ecs-ha-dev-service-degraded` (composite) |
| SLO-4: RDS Storage | Free storage > 5 GB at all times | Hard limit — no budget | `wordpress-ecs-ha-dev-rds-low-storage` (< 2 GB) |

---

## 5. Common Operations

```bash
# Force ECS service redeploy (recycles all containers with zero downtime)
aws ecs update-service --cluster wordpress-ecs-ha-dev-cluster \
  --service wordpress-ecs-ha-dev-wordpress-svc --force-new-deployment --region us-east-1

# Scale ECS service to 3 tasks temporarily
aws ecs update-service --cluster wordpress-ecs-ha-dev-cluster \
  --service wordpress-ecs-ha-dev-wordpress-svc --desired-count 3 --region us-east-1

# Check ECS task logs in CloudWatch (last 100 events)
aws logs filter-log-events --log-group-name /ecs/wordpress-ecs-ha/dev/wordpress \
  --start-time $(date -d '30 minutes ago' +%s000) --region us-east-1 --limit 100

# List stopped ECS tasks and their stop reason
aws ecs list-tasks --cluster wordpress-ecs-ha-dev-cluster \
  --desired-status STOPPED --region us-east-1 --query "taskArns[:5]" --output text | \
xargs aws ecs describe-tasks --cluster wordpress-ecs-ha-dev-cluster --region us-east-1 --tasks \
  --query "tasks[].{Task:taskArn,StopCode:stopCode,Reason:stoppedReason}"

# Check RDS free storage right now
aws cloudwatch get-metric-statistics --namespace AWS/RDS \
  --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value=terraform-2026052004531822060000000b \
  --start-time $(date -u -d '5 minutes ago' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
  --period 300 --statistics Minimum --region us-east-1

# Manually trigger the daily report in dry-run mode (from monitoring EC2 via SSM)
aws ssm send-command \
  --instance-ids $(aws ec2 describe-instances \
    --filters "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
    --region us-east-1 --query "Reservations[0].Instances[0].InstanceId" --output text) \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["/usr/bin/python3 /opt/monitoring/scripts/daily-reliability-report.py --cluster wordpress-ecs-ha-dev-cluster --rds-identifier terraform-2026052004531822060000000b --sns-topic-arn arn:aws:sns:us-east-1:432500708329:wordpress-ecs-ha-dev-alerts --region us-east-1 --prometheus-url http://localhost:9090 --dry-run"]' \
  --region us-east-1

# SSH into monitoring EC2 via SSM Session Manager
aws ssm start-session \
  --target $(aws ec2 describe-instances \
    --filters "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
    --region us-east-1 --query "Reservations[0].Instances[0].InstanceId" --output text) \
  --region us-east-1

# Restart Prometheus and Grafana on monitoring EC2
aws ssm send-command \
  --instance-ids $(aws ec2 describe-instances \
    --filters "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
    --region us-east-1 --query "Reservations[0].Instances[0].InstanceId" --output text) \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["cd /opt/monitoring && docker compose down && docker compose up -d && docker ps"]' \
  --region us-east-1
```

---

## 6. Escalation

| Severity | Condition | Time Limit Before Escalating | Who to Contact |
|---|---|---|---|
| **SEV-1** | Full service outage — WordPress returning 5xx or unreachable, composite alarm firing | 15 minutes | Senior engineer — page immediately |
| **SEV-2** | Partial outage or SLO at risk — one task down, high error rate, RDS degraded | 30 minutes | Team lead — notify in incident channel |
| **SEV-3** | Warning with no current user impact — high CPU/memory, disk filling, Grafana down | Next standup | Self-resolve or log a ticket |
