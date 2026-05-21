# WordPress ECS HA — SRE Observability Platform

## 1. Project Overview

WordPress ECS HA is a production-pattern WordPress deployment on Amazon ECS (EC2 launch type) built as the Week 3–5 SRE internship project. The Week 3 foundation provides high-availability WordPress across two Availability Zones with an Application Load Balancer, RDS MySQL on private subnets, EFS-backed shared storage, and an Auto Scaling Group. Week 5 adds a complete SRE observability layer: Prometheus and Grafana for real-time host and application metrics, ten CloudWatch alarms with SNS email notification, a daily automated reliability report that evaluates four SLOs, and a documented runbook covering all fourteen alert conditions.

The monitoring stack runs on a dedicated EC2 instance that is architecturally separate from the ECS cluster it monitors. If ECS degrades or tasks crash, Prometheus and Grafana remain operational and provide the signal needed to diagnose the failure without depending on the system under observation.

---

## 2. Architecture

```
Internet → ALB (port 80)
               │
    ┌──────────┼──────────────── /grafana ──────────────┐
    ▼          ▼                                        ▼
ECS Task    ECS Task                         Monitoring EC2 (public subnet)
(AZ-1)      (AZ-2)                           ├── Prometheus :9090
    │            │                            ├── Grafana :3000
    └── Node Exporter :9100 ◄─── scrape ─────┘
         │                                   │
    RDS MySQL                        CloudWatch API
    EFS /var/www/html                daily-reliability-report.py (06:00 UTC)
```

- **vpc** — VPC (10.0.0.0/16), 2 public and 2 private subnets across 2 AZs, NAT gateway, internet gateway, and route tables.
- **security_groups** — All security group definitions and inter-group ingress rules for the ALB, ECS tasks, RDS, EFS, and monitoring EC2.
- **secrets** — KMS CMK with automatic key rotation and a Secrets Manager secret containing auto-generated DB credentials; credentials are injected into ECS tasks at runtime via the `secrets:` block.
- **efs** — Encrypted EFS file system with a dedicated access point for WordPress `/var/www/html` uploads shared across ECS tasks for persistent media storage.
- **rds** — MySQL 8.0 on `db.t3.micro` with encrypted gp3 storage, slow query logging, 7-day automated backups, and CloudWatch alarms for CPU utilization, free storage, and connection count.
- **alb** — Public Application Load Balancer with WordPress and Grafana target groups; a path-based listener rule routes `/grafana*` traffic to the monitoring EC2 at priority 10; CloudWatch alarms for 5xx rate, unhealthy hosts, and traffic drop.
- **ecs** — EC2 launch template with Node Exporter user data (port 9100), Auto Scaling Group (1–2 instances), ECS cluster with Container Insights enabled, WordPress task definition, and an ECS service with session stickiness.
- **monitoring** — SNS alerts topic, CloudWatch alarms for ECS CPU/memory/task count, a composite alarm combining task count and ALB health checks, and a CloudWatch dashboard.
- **prometheus** — Dedicated `t2.micro` EC2 running Prometheus and Grafana via Docker Compose; S3 bucket for monitoring assets downloaded at boot; IAM role with CloudWatch and ECS read permissions; cron jobs for ECS node discovery and the daily reliability report.
- **grafana** — CloudWatch alarm that fires when the Grafana ALB target group reports unhealthy hosts; CloudWatch log group for Grafana container logs (7-day retention).

---

## 3. Prerequisites

1. Terraform >= 1.10.0
2. AWS CLI configured with account `432500708329` access
3. AWS provider 5.x
4. An S3 bucket for state: `wordpress-ecs-tfstate-xgrid-1779080592` (must exist before init)
5. Python 3.8+ with `boto3` and `requests` (for daily report)
6. A Gmail app password if SMTP email sending is needed (optional — SNS is used by default)

---

## 4. Quick Start

```bash
# Clone and navigate
cd "week 5/environments/dev"

# Copy example vars and fill in required values
cp terraform.tfvars.example terraform.tfvars
# Required: set grafana_admin_password and owner_name

# Initialize Terraform
terraform init

# Preview changes
terraform plan -out=tfplan -var 'grafana_admin_password=YOUR_PASSWORD'

# Apply
terraform apply tfplan

# Verify outputs
terraform output
```

---

## 5. Accessing the Stack

| Resource | URL | Notes |
|---|---|---|
| WordPress | `http://<alb_dns_name from terraform output>` | Takes 2-3 min after apply for ECS tasks to start |
| Grafana | `http://wordpress-ecs-ha-dev-alb-1325349632.us-east-1.elb.amazonaws.com/grafana` | Login: `admin` / `grafana_admin_password` from tfvars |
| Prometheus | `http://98.92.178.35:9090` | Dev access only — not behind ALB |
| Daily Report | `/var/log/daily-report.log` on monitoring EC2 | Runs 06:00 UTC (11:00 AM PKT) via cron |

---

## 6. Module Structure

```
week 5/
├── dashboards/
│   └── wordpress-overview.json
├── docs/
│   └── runbook.md
├── environments/
│   └── dev/
│       ├── backend.tf
│       ├── main.tf
│       ├── outputs.tf
│       ├── provider.tf
│       ├── terraform.tfvars.example
│       └── variables.tf
├── modules/
│   ├── alb/
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   └── variables.tf
│   ├── ecs/
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   └── variables.tf
│   ├── efs/
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   └── variables.tf
│   ├── grafana/
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   └── variables.tf
│   ├── monitoring/
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   └── variables.tf
│   ├── prometheus/
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── user_data.sh.tpl
│   │   └── variables.tf
│   ├── rds/
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   └── variables.tf
│   ├── secrets/
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   └── variables.tf
│   ├── security_groups/
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   └── variables.tf
│   └── vpc/
│       ├── main.tf
│       ├── outputs.tf
│       └── variables.tf
├── scripts/
│   ├── create-remote-state.sh
│   └── daily-reliability-report.py
├── .gitignore
└── README.md
```

---

## 7. SLOs

| SLO | Target | Error Budget | Alarm |
|---|---|---|---|
| SLO-1: HTTP Availability | ≥ 99.5% per rolling 30 days | 216 min/month | `alb-5xx` > 0.5% for 2 min |
| SLO-2: p95 Latency | ≤ 2.0s at the 95th percentile | 36 windows/month above threshold | Report check only |
| SLO-3: Running Tasks | ≥ 1 task running at all times | 43.8 min/month below 1 task | `ecs-low-task-count` < 2 for 1 min |
| SLO-4: RDS Free Storage | > 5.0 GB at all times | N/A (hard limit) | `rds-low-storage` < 2 GB |

- 0–50% consumed → no restrictions
- 50–75% consumed → deployments require approval
- 75–100% consumed → freeze non-emergency deployments
- 100% consumed → mandatory post-mortem within 48 hours

---

## 8. Observability Stack

### Prometheus

- Scrapes Node Exporter on each ECS EC2 host via `file_sd_configs`; target list written to `/etc/prometheus/targets/ecs_nodes.json` by a cron job that calls `aws ec2 describe-instances --filters Name=tag:AmazonECSManaged,Values=true` every 5 minutes
- Scrape interval: 15s
- Retention: 15 days (`--storage.tsdb.retention.time=15d`)
- Alert rules (Prometheus-native):
  - `DiskAlmostFull` — `node_filesystem_avail_bytes / node_filesystem_size_bytes{mountpoint="/"} < 0.15` for 5 min (disk > 85% full)
  - `HighMemory` — `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.20` for 5 min (memory < 20% free)
  - `NodeDown` — `up{job="node_exporter"} == 0` for 1 min (Node Exporter target unreachable)

### Grafana

- Dashboard: **WordPress ECS HA — SRE Overview**, 19 panels across 5 sections: ECS Cluster, ALB, Host Metrics, RDS Database, SLO Status
- Datasources: Prometheus (`PBFA97CFB590B2093`) and CloudWatch (`P034F075C744B399F`)
- Access: `http://wordpress-ecs-ha-dev-alb-1325349632.us-east-1.elb.amazonaws.com/grafana` — login `admin` / `grafana_admin_password`
- Dashboard is provisioned automatically: `user_data.sh.tpl` downloads `wordpress-overview.json` from S3 to `/opt/monitoring/grafana/dashboards/` at EC2 boot; Grafana reloads the file every 30 seconds with no container restart required

### CloudWatch

- `wordpress-ecs-ha-dev-ecs-high-cpu` — ECS CPU > 70% for 10 min (2 × 5-min periods)
- `wordpress-ecs-ha-dev-ecs-high-memory` — ECS Memory > 75% for 10 min (2 × 5-min periods)
- `wordpress-ecs-ha-dev-ecs-low-task-count` — Running tasks < 2 for 1 min
- `wordpress-ecs-ha-dev-alb-5xx` — 5xx error rate > 0.5% for 2 min (metric math: `e1/r1*100`)
- `wordpress-ecs-ha-dev-alb-unhealthy-hosts` — Unhealthy ALB targets ≥ 1 for 2 min
- `wordpress-ecs-ha-dev-alb-traffic-drop` — Request count < 5/min for 3 consecutive minutes
- `wordpress-ecs-ha-dev-rds-high-cpu` — RDS CPU > 70% for 15 min (3 × 5-min periods)
- `wordpress-ecs-ha-dev-rds-low-storage` — RDS free storage < 2 GB
- `wordpress-ecs-ha-dev-rds-high-connections` — DB connections > 60 for 10 min (70% of max_connections)
- `wordpress-ecs-ha-dev-grafana-unhealthy` — Grafana ALB target unhealthy ≥ 1 for 2 min
- Composite alarm: `wordpress-ecs-ha-dev-service-degraded` — fires when `ALARM(ecs-low-task-count) AND ALARM(alb-unhealthy-hosts)` are both true simultaneously
- SNS topic: `wordpress-ecs-ha-dev-alerts`; subscriber: `daniyal.tufail@xgrid.co`

---

## 9. Daily Reliability Report

- Collects: ECS running task count and cluster state, EC2 CPU/memory/disk usage via Prometheus, ALB request rate and 5xx/4xx error counts, RDS CPU/connections/free storage, CloudWatch alarm history, CloudWatch Logs error patterns (`?ERROR ?Fatal ?error`) from `/ecs/wordpress-ecs-ha/dev/wordpress`
- SLO checks: SLO-1 (HTTP Availability ≥ 99.5%), SLO-2 (p95 Latency ≤ 2.0s), SLO-3 (Running Tasks ≥ 1), SLO-4 (RDS Storage > 5.0 GB)
- Schedule: daily at 06:00 UTC (11:00 AM PKT) via cron on the monitoring EC2
- Manual dry-run:

```bash
python3 /opt/monitoring/scripts/daily-reliability-report.py \
  --cluster wordpress-ecs-ha-dev-cluster \
  --service wordpress-ecs-ha-dev-wordpress-svc \
  --rds-identifier terraform-2026052004531822060000000b \
  --alb-arn-suffix app/wordpress-ecs-ha-dev-alb/355411d356f09837 \
  --prometheus-url http://localhost:9090 \
  --region us-east-1 \
  --dry-run
```

---

## 10. Alerting

All ten CloudWatch alarms publish to a single SNS topic. Email delivery occurs within 2–3 minutes of the alarm evaluation window completing; alarms evaluate on their own schedule independent of Grafana's dashboard refresh.

```
CloudWatch Alarm fires
        ↓
SNS Topic: wordpress-ecs-ha-dev-alerts
        ↓
Email: daniyal.tufail@xgrid.co
```

Note: CloudWatch metrics have a 2–3 minute ingestion delay. Alarms are the detection mechanism; Grafana is for investigation after an alarm fires.

---

## 11. Security Notes

- DB credentials stored in Secrets Manager (`wordpress-ecs-ha/dev/db-credentials`) — not in environment variables or task definition plaintext; ECS retrieves them at container start via the `secrets:` block in the task definition
- KMS CMK (`alias/wordpress-ecs-ha-dev-secrets`) with automatic key rotation encrypts EFS, RDS storage, and Secrets Manager; `kms:ViaService` conditions restrict key usage to those two services only
- ECS exec command disabled: `enable_execute_command = false` in the ECS service definition
- No SSH keys on any EC2; all access is via SSM Session Manager using the `AmazonSSMManagedInstanceCore` managed policy
- `terraform.tfvars` is listed in `.gitignore` and is never committed; it contains `grafana_admin_password`
- RDS `deletion_protection = false` (dev only — set `true` for staging and production); `skip_final_snapshot = false` (a final snapshot named `wordpress-ecs-ha-dev-final` is created automatically on `terraform destroy`)

---

## 12. Known Limitations

- CloudWatch metric ingestion delay is 2–3 minutes. Grafana dashboards reflect data that is already 2–3 minutes old. Do not rely on Grafana for real-time incident detection — alarms are the detection mechanism.
- The monitoring EC2 has a public IP address for direct Prometheus access on port 9090. This is acceptable for dev and internship use; in production, Prometheus should sit behind a VPN or a more restrictive security group.
- The SNS email subscription must be manually confirmed after `terraform apply` by clicking the link in the AWS confirmation email. Terraform cannot automate this step due to AWS provider 5.x issue #32072.
- `t2.micro` instances are used for both ECS EC2 hosts and the monitoring EC2. These are suitable for dev and internship load testing; not appropriate for production traffic levels.
- A single NAT Gateway is provisioned in one AZ to minimize cost. This creates an AZ dependency: if that AZ degrades, ECS tasks in the other AZ lose outbound internet access. Use two NAT Gateways in production.

---

## 13. Teardown

```bash
# WARNING: This destroys all infrastructure including RDS data
# Ensure you have a manual RDS snapshot before running

# Take RDS snapshot first
aws rds create-db-snapshot \
  --db-instance-identifier terraform-2026052004531822060000000b \
  --db-snapshot-identifier week5-manual-snapshot-$(date +%Y%m%d) \
  --region us-east-1

# Then destroy
terraform destroy -var 'grafana_admin_password=YOUR_PASSWORD'
```

---

## 14. Documentation

- [docs/runbook.md](docs/runbook.md) — Alert playbooks for all 14 alarms
- [docs/slo-definitions.md](docs/slo-definitions.md) — SLO targets and error budget policy
- [docs/escalation-flow.md](docs/escalation-flow.md) — Severity definitions and escalation matrix
- [docs/incident-template.md](docs/incident-template.md) — Post-mortem template
- [dashboards/wordpress-overview.json](dashboards/wordpress-overview.json) — Grafana dashboard (auto-provisioned)
