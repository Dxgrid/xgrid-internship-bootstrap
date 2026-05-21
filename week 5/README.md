![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.5.0-purple) ![AWS](https://img.shields.io/badge/AWS-us--east--1-orange) ![Status](https://img.shields.io/badge/Status-Production--Ready-green)
Module: SRE-102 | Author: SRE Intern Week 5

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [What's New in Week 5](#2-whats-new-in-week-5)
3. [Module Reference](#3-module-reference)
4. [SLI / SLO Definitions](#4-sli--slo-definitions)
5. [Prerequisites & Setup](#5-prerequisites--setup)
6. [Deployment](#6-deployment)
7. [Monitoring Stack Access](#7-monitoring-stack-access)
8. [Daily Reliability Report](#8-daily-reliability-report)
9. [Failure Injection Tests](#9-failure-injection-tests)
10. [Troubleshooting](#10-troubleshooting)
11. [Cost Analysis](#11-cost-analysis)
12. [Teardown](#12-teardown)

---

## 1. Architecture Overview

```
Internet ──► IGW ──► ALB (Port 80)
                       │
         ┌─────────────┼──────── /grafana ────────────────────────┐
         ▼             ▼                                           ▼
   ECS Task (AZ-1)  ECS Task (AZ-2)                  Monitoring EC2 (t2.micro)
   Private Subnet   Private Subnet                    Public Subnet
         │                 │                                       │
         ├─ Node Exporter  ├─ Node Exporter ◄─── Prometheus (:9090)
         │     :9100       │       :9100               │
         └────────┬────────┘               Grafana (:3000) ◄── ALB /grafana
                  │                                  │
             RDS MySQL                    CloudWatch (IAM role)
             EFS Volume                              │
                                         Daily Report Script (Python)
                                                     │
                                              Email (SMTP)
```

**Key principle:** The monitoring stack (Prometheus + Grafana) runs on a *separate* EC2 from the WordPress workload. If the ECS cluster degrades, the monitoring system stays up and tells you why. This is a foundational SRE separation-of-concerns principle.

---

## 2. What's New in Week 5

Built on the Week 3 WordPress-on-ECS foundation, Week 5 adds a complete observability layer:

| Component | Description |
|-----------|-------------|
| **Node Exporter** | Docker container on each ECS EC2 host (host network, port 9100). Exports CPU, memory, disk, and network metrics for Prometheus scraping. |
| **Prometheus** | Docker container on a dedicated monitoring EC2 (`prom/prometheus:v2.52.0`). Scrapes Node Exporter via file-based service discovery — auto-discovers ECS EC2 private IPs every 5 minutes via `aws ec2 describe-instances`. |
| **Grafana** | Docker container on the same monitoring EC2 (`grafana/grafana:10.4.2`). Pre-provisioned with Prometheus + CloudWatch datasources. Dashboard combines host metrics and AWS service metrics. Exposed via ALB at `/grafana`. |
| **Daily Reliability Report** | Python script (`scripts/daily-reliability-report.py`) — collects metrics from ECS, EC2, ALB, RDS, and Prometheus, evaluates 4 SLOs, generates a structured plain-text report, and sends via SMTP email. Runs as a daily cron job on the monitoring EC2. |
| **SLI/SLO Definitions** | 4 SLOs with measurable SLIs, alert thresholds, and an error budget policy (see section 4). |
| **SRE Documentation** | Runbook (`docs/runbook.md`), escalation flow (`docs/escalation-flow.md`), and incident post-mortem template (`docs/incident-template.md`). |
| **Grafana Dashboard JSON** | `dashboards/wordpress-overview.json` — importable/provisionable dashboard with ECS, ALB, RDS, Node Exporter, and SLO status panels. |

**Bug fixes applied from the Week 3 audit:**

| Fix | File | Change |
|-----|------|--------|
| RDS storage autoscaling disabled | `modules/rds/main.tf` | `max_allocated_storage`: 20 → 100; `storage_type`: gp2 → gp3 |
| ECS Terraform fights autoscaler | `modules/ecs/main.tf` | Added `lifecycle { ignore_changes = [desired_count, task_definition] }` |
| EFS has no backup | `modules/efs/main.tf` | Added `aws_efs_backup_policy` with `status = "ENABLED"` |
| Secret instantly deleted | `modules/secrets/main.tf` | `recovery_window_in_days = 0` → parameterised (default 7) |
| Monitoring region hardcoded | `modules/monitoring/main.tf` | All `"us-east-1"` replaced with `var.aws_region` |
| CPU/memory alarms silent when ECS down | `modules/monitoring/main.tf` | Added `treat_missing_data = "notBreaching"` |
| Lock file excluded from git | `.gitignore` | Removed `.terraform.lock.hcl` line |

---

## 3. Module Reference

| Module | AWS Resources | New in Week 5? |
|--------|--------------|----------------|
| `vpc` | VPC, subnets, NAT Gateway, IGW, route tables | No |
| `security_groups` | 5 SGs + `aws_security_group_rule.ecs_allow_node_exporter` | Extended |
| `secrets` | KMS CMK, Secrets Manager secret | Bug fixes only |
| `efs` | EFS file system, access point, mount targets, backup policy | Bug fix (backup) |
| `rds` | RDS MySQL 8.0, parameter group, CloudWatch alarms | Bug fixes only |
| `ecs` | ECS cluster, launch template, ASG, task definition, service | Extended (Node Exporter in user_data) |
| `alb` | ALB, 2 target groups (WordPress + Grafana), HTTP listener + listener rule | Extended |
| `monitoring` | SNS topic, 4 CloudWatch alarms, composite alarm, dashboard | Extended (region fix) |
| `prometheus` | EC2 instance, IAM role/policy, instance profile, ALB TG attachment | **NEW** |
| `grafana` | CloudWatch log group, Grafana health alarm | **NEW** |

---

## 4. SLI / SLO Definitions

| SLO | SLI | Target | Monthly Error Budget | Alert Threshold |
|-----|-----|--------|---------------------|-----------------|
| **SLO-1: HTTP Availability** | `(requests - 5xx) / requests` over 30-min rolling window | ≥ 99.5% | 3h 36m downtime | < 99.9% for 10 min |
| **SLO-2: p95 Latency** | ALB `TargetResponseTime` p95 per 5-min window | ≤ 2.0s for 95% of windows | 36 windows/month above threshold | p95 > 3.0s for 2 periods |
| **SLO-3: Task Availability** | `RunningTaskCount / 2` | ≥ 1 task running 99.9% of time | 43.8 min/month at < 1 task | Existing composite alarm |
| **SLO-4: RDS Storage** | `FreeStorageSpace` minimum in 24h window | > 5 GB at all times | N/A (hard limit) | < 2 GB (existing alarm) |

**Error Budget Policy:**

| Budget Consumed | Action |
|----------------|--------|
| 0–50% | No deployment restrictions |
| 50–75% | Deployments require explicit approval |
| 75–100% | Freeze non-emergency deployments |
| 100% breached | Mandatory post-mortem within 48 hours |

---

## 5. Prerequisites & Setup

| Tool | Version | Purpose |
|------|---------|---------|
| Terraform | ≥ 1.5.0 | Infrastructure provisioning |
| AWS CLI | v2 | Resource inspection and debugging |
| Python 3 | ≥ 3.8 | Daily reliability report script |
| boto3 | latest | `pip3 install boto3 requests` |

```bash
aws configure
```

Initialize the remote state S3 backend:
```bash
chmod +x scripts/create-remote-state.sh
./scripts/create-remote-state.sh
```

Create your `terraform.tfvars`:
```bash
cp environments/dev/terraform.tfvars.example environments/dev/terraform.tfvars
```

Edit `environments/dev/terraform.tfvars`:
```hcl
aws_region             = "us-east-1"
environment            = "dev"
project_name           = "wordpress-ecs-ha"
owner_name             = "your-name"
alert_email            = "you@example.com"
grafana_admin_password = "your-secure-password"
manage_email_subscription = true
```

> `terraform.tfvars` is excluded from git. Never commit it — it contains your Grafana admin password.

---

## 6. Deployment

```bash
cd environments/dev
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

| Resource | Estimated Time |
|----------|---------------|
| VPC Networking | 30s |
| RDS MySQL | 12m |
| ECS Cluster + ASG | 5m |
| ALB | 3m |
| Monitoring EC2 (bootstrap) | 5-8m (Docker Compose starts after EC2 is up) |
| **Total** | **~25m** |

Key outputs to note:
```bash
terraform output alb_dns_name          # WordPress: http://<dns>/
terraform output grafana_url           # Grafana:   http://<dns>/grafana
terraform output prometheus_direct_url # Prometheus: http://<ip>:9090 (dev debug)
terraform output monitoring_ec2_public_ip
```

> **SNS Confirmation:** Check your email inbox for the AWS Subscription Confirmation link and click it to enable CloudWatch alarm notifications.

---

## 7. Monitoring Stack Access

### Grafana
1. Open `terraform output grafana_url` in a browser.
2. Login: username `admin`, password = `grafana_admin_password` from tfvars.
3. Navigate to **Dashboards → WordPress ECS HA — SRE Overview**.
4. All panels auto-populate — no manual datasource setup needed.

### Prometheus
```bash
# Direct access (dev only — port 9090 is not behind ALB)
open $(terraform output -raw prometheus_direct_url)

# Verify ECS EC2s are being scraped as Node Exporter targets
curl "$(terraform output -raw prometheus_direct_url)/api/v1/targets" | jq '.data.activeTargets[].labels'
```

### Node Exporter (on ECS EC2 hosts)
```bash
# Discover ECS EC2 IPs
aws ec2 describe-instances \
  --filters "Name=tag:AmazonECSManaged,Values=true" "Name=instance-state-name,Values=running" \
  --region us-east-1 \
  --query "Reservations[].Instances[].PrivateIpAddress"

# Test Node Exporter directly (requires VPN or SSM port forwarding)
curl http://<private-ip>:9100/metrics | grep node_cpu
```

### SSM Access to Monitoring EC2
```bash
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
  --region us-east-1 \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

aws ssm start-session --target $INSTANCE_ID --region us-east-1
```

---

## 8. Daily Reliability Report

**Dry run (stdout, no email):**
```bash
python3 scripts/daily-reliability-report.py \
  --cluster wordpress-ecs-ha-dev-cluster \
  --rds-identifier wordpress-ecs-ha-dev-mysql \
  --alb-arn-suffix "$(terraform -chdir=environments/dev output -raw alb_arn_suffix)" \
  --tg-arn-suffix "$(terraform -chdir=environments/dev output -raw target_group_arn_suffix)" \
  --region us-east-1 \
  --prometheus-url "$(terraform -chdir=environments/dev output -raw prometheus_direct_url)" \
  --dry-run
```

**Send email via Gmail SMTP:**
```bash
export SMTP_USER="yourname@gmail.com"
export SMTP_PASSWORD="xxxx-xxxx-xxxx-xxxx"  # Gmail App Password
export REPORT_TO="recipient@example.com"

python3 scripts/daily-reliability-report.py \
  --cluster wordpress-ecs-ha-dev-cluster \
  --rds-identifier wordpress-ecs-ha-dev-mysql \
  --alb-arn-suffix <suffix> \
  --tg-arn-suffix <suffix>
```

Create a Gmail App Password at [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords).

The report automatically runs at 06:00 UTC daily on the monitoring EC2 via cron. Output is logged to `/var/log/daily-report.log`.

---

## 9. Failure Injection Tests

### Test 1: Kill One ECS Task (HA Recovery)
```bash
TASK=$(aws ecs list-tasks \
  --cluster wordpress-ecs-ha-dev-cluster \
  --region us-east-1 --query "taskArns[0]" --output text)

aws ecs stop-task --cluster wordpress-ecs-ha-dev-cluster --task $TASK \
  --reason "HA Failure Injection Test" --region us-east-1

watch -n 5 "aws ecs describe-services \
  --cluster wordpress-ecs-ha-dev-cluster \
  --services wordpress-ecs-ha-dev-wordpress-svc \
  --region us-east-1 \
  --query 'services[0].{Running:runningCount,Desired:desiredCount}' --output table"
```
**Expected:** Grafana "Running Tasks" drops 2→1, ECS scheduler replaces it within ~60s, task count returns to 2. WordPress remains accessible throughout.

### Test 2: Kill Both Tasks (Service Degraded)
Stop both tasks within 30 seconds. Expected: composite alarm fires, Grafana shows 0 running tasks, WordPress returns 503.

### Test 3: Stop Monitoring EC2
```bash
aws ec2 stop-instances --instance-ids <monitoring-ec2-id> --region us-east-1
```
**Expected:** `grafana-unhealthy` alarm fires within 2 minutes. WordPress is completely unaffected — monitoring is isolated.

---

## 10. Troubleshooting

### Prometheus targets are DOWN
```bash
# SSM into monitoring EC2
aws ssm start-session --target <monitoring-ec2-id> --region us-east-1

# Check discovery output
cat /opt/monitoring/prometheus/targets/ecs_nodes.json

# Re-run discovery manually
/opt/monitoring/scripts/discover_ecs_nodes.sh

# Check Prometheus logs
docker compose -f /opt/monitoring/docker-compose.yml logs prometheus --tail 30
```

**Cause:** ECS EC2 instances may not have the `AmazonECSManaged=true` tag set yet (AL2023 may use different tags). Verify:
```bash
aws ec2 describe-instances \
  --filters "Name=tag:AmazonECSManaged,Values=true" "Name=instance-state-name,Values=running" \
  --region us-east-1 --query "Reservations[].Instances[].InstanceId"
```

### Grafana shows "No data" for CloudWatch panels
The monitoring EC2 IAM role must have CloudWatch read permissions. Verify:
```bash
aws iam list-attached-role-policies \
  --role-name wordpress-ecs-ha-dev-monitoring-<suffix> \
  --region us-east-1
```

### Docker Compose did not start (monitoring EC2 just launched)
user_data runs asynchronously after launch. Wait 5 minutes, then:
```bash
aws ssm start-session --target <instance-id> --region us-east-1
# Check:
cat /var/log/monitoring-bootstrap.log
docker ps
```

### WordPress health check failing after Week 5 apply
The ALB now has a path-pattern listener rule for `/grafana` at priority 10. The WordPress default forward remains. If health checks suddenly fail, verify the ALB listener rules:
```bash
aws elbv2 describe-rules \
  --listener-arn $(terraform -chdir=environments/dev output -raw alb_listener_arn 2>/dev/null || echo "check outputs") \
  --region us-east-1
```

---

## 11. Cost Analysis

| Service | Config | Free Tier | Monthly Cost |
|---------|--------|-----------|-------------|
| NAT Gateway | 1× Base + 1 GB data | None | $32.85 |
| ALB | 1× + 2 target groups | None | ~$22.27 |
| EC2 WordPress (×2) | t2.micro | 1 instance free | $8.47 |
| EC2 Monitoring (×1) | t2.micro | (used above) | $8.47 |
| RDS MySQL | db.t3.micro | None | $12.41 |
| EFS | 1 GB storage | 5 GB free | $0.30 |
| Secrets Manager | 1 secret | None | $0.40 |
| KMS CMK | 1 key | None | $1.00 |
| CloudWatch | Dashboard + alarms | 10 free | $5.00 |
| Prometheus + Grafana | Docker (no extra AWS service) | N/A | $0.00 |
| **TOTAL** | | | **~$91.17** |

Week 5 adds ~$8.47/month vs Week 3 for the dedicated monitoring EC2. Prometheus and Grafana run as Docker containers — zero additional AWS cost.

---

## 12. Teardown

> The NAT Gateway and ALB accrue hourly charges. Always destroy when done testing.

```bash
cd environments/dev
terraform destroy
```

Verify complete cleanup:
```bash
aws ecs list-clusters --region us-east-1
aws rds describe-db-instances --region us-east-1
aws elbv2 describe-load-balancers --region us-east-1
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value}" \
  --region us-east-1 --output table
```

Manual cleanup required:
- S3 state bucket (`wordpress-ecs-tfstate-xgrid-*`)
- CloudWatch log groups (`/ecs/...` and `/monitoring/...`)
