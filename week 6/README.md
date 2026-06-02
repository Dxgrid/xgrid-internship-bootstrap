# Flask SRE Platform — Week 6

An SRE observability platform built on AWS ECS (EC2 launch type). A Flask demo application serves HTTP traffic while Prometheus scrapes metrics, Grafana visualises them across three purpose-built dashboards, and CloudWatch alarms notify on-call via SNS email.

---

## Architecture

```
Internet
    │
    ▼
ALB  ──── /        ──► ECS: demo-app  (2 tasks, AZ-1 + AZ-2)
    │                        │
    └──── /grafana ──► ECS: grafana   (1 task)  ──► RDS MySQL
                             │
                   ECS: prometheus (1 task)  ──► EFS (TSDB)
                             │
                    ┌────────┴────────┐
                 scrape            scrape
                    │                │
              node_exporter      demo-app /metrics
             (EC2 host, :9100)    (:80)
                             │
                       CloudWatch API
                             │
                     SNS ──► Email
```

**Service discovery** — Prometheus discovers demo-app task IPs via AWS Cloud Map (MULTIVALUE DNS). Grafana reaches Prometheus via Cloud Map private DNS (`prometheus.flask-sre-ecs-dev:9090`). No hardcoded IPs anywhere.

---

## Module Structure

```
week 6/
├── app/                        Flask demo app + Dockerfile
├── dashboards/
│   ├── oncall.json             On-Call view (App Status, Error Rate, p95, Running Tasks)
│   ├── resources.json          Resource Usage (CPU, Memory, Disk, ECS metrics)
│   └── slo.json                SLO Status (Availability, Error Budget, Burn Rate)
├── docs/
│   └── runbook.md              Alert response playbooks
├── environments/
│   └── dev/
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       ├── backend.tf
│       └── terraform.tfvars.example
├── modules/
│   ├── alb/                    ALB, target groups, CloudWatch alarms
│   ├── ecs/                    Cluster, ASG, demo-app service, Cloud Map namespace
│   ├── efs/                    Encrypted EFS for Prometheus TSDB
│   ├── grafana/                Grafana ECS service, RDS DB init, IAM
│   ├── monitoring/             SNS topic, CloudWatch alarms, dashboard
│   ├── prometheus/             Prometheus ECS service, recording + alert rules, IAM
│   ├── rds/                    MySQL 8.0, backups, CloudWatch alarms
│   ├── secrets/                KMS CMK, Secrets Manager (DB credentials)
│   ├── security_groups/        All SG definitions and inter-group rules
│   └── vpc/                    VPC, subnets, NAT gateway, route tables
└── scripts/
    └── daily-reliability-report.py
```

---

## Prerequisites

- Terraform ≥ 1.10, AWS provider 5.x
- AWS CLI configured for account `432500708329`
- Docker (to build and push the demo-app image before first apply)
- Python 3.8+ with `boto3` and `requests` (for the daily report)
- S3 bucket `flask-sre-tfstate-xgrid` must exist before `terraform init`

---

## Quick Start

```bash
cd "week 6/environments/dev"

# 1. Copy and fill in required variables
cp terraform.tfvars.example terraform.tfvars
# Set: grafana_admin_password, alert_email

# 2. Init and apply
terraform init
terraform apply

# 3. Push the demo-app image (required before ECS tasks start)
ECR_URI=$(terraform output -raw ecr_repository_url)
docker build -t $ECR_URI:latest ../../app
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR_URI
docker push $ECR_URI:latest

# 4. Force ECS to pull the new image
aws ecs update-service \
  --cluster flask-sre-ecs-dev-cluster \
  --service flask-sre-ecs-dev-demo-app-svc \
  --force-new-deployment \
  --region us-east-1
```

---

## Access

| Resource | URL |
|----------|-----|
| Demo App | `http://<alb_dns_name>` |
| Grafana | `http://<alb_dns_name>/grafana` — `admin` / value from `grafana_admin_password` |
| Prometheus | Internal only — query via Grafana datasource proxy |

Get the ALB DNS name: `terraform output alb_dns_name`

---

## SLOs

| SLO | SLI | Target | Error Budget |
|-----|-----|--------|--------------|
| SLO-1 HTTP Availability | Successful requests / total requests | ≥ 99.5% | 3h 36m / month |
| SLO-2 p95 Latency | 95th percentile response time | ≤ 2.0s | — |

Error budget policy:
- **> 50% consumed** — deployments require approval
- **> 75% consumed** — freeze non-emergency deployments
- **100% consumed** — mandatory post-mortem within 48 hours

---

## Observability Stack

### Prometheus (ECS service)

- **Scrape interval:** 15s
- **Retention:** 15 days on EFS
- **Jobs:** `demo_app` (Cloud Map DNS), `node_exporter` (port 9100 on ECS EC2 hosts), `prometheus` (self)
- **Recording rules** (7 pre-computed metrics evaluated every 15s):

| Rule | Description |
|------|-------------|
| `instance:node_cpu_utilisation:rate5m` | Per-host CPU % |
| `instance:node_memory_utilisation:ratio` | Per-host memory ratio |
| `instance:node_filesystem_utilisation:ratio` | Per-host disk ratio |
| `job:app_requests_success:ratio_rate5m` | App availability SLI |
| `job:app_request_errors:ratio_rate5m` | Error rate ratio |
| `job:app_requests:rate5m` | Request throughput |
| `job:app_request_latency_seconds:p95rate5m` | p95 latency (histogram) |

- **Alert rules:** `NodeDown`, `HighCPU` (>80% for 3m), `HighMemory` (>80% for 5m), `DiskAlmostFull` (>85% for 5m), `AppDown`, `HighErrorRate` (>5% for 2m)

### Grafana (ECS service, RDS-backed)

Three dashboards, each with a single audience in mind:

| Dashboard | Purpose | Panels |
|-----------|---------|--------|
| **On-Call** | "Is anything broken right now?" | App Status, Running Tasks, Error Rate, p95 Latency, Request Rate |
| **Resources** | "How loaded is the infrastructure?" | Host CPU/Memory/Disk, ECS Service CPU/Memory |
| **SLO Status** | "Are we keeping our promises?" | Availability, Error Budget, Burn Rate, p95 Trend, Request Volume + Error Rate |

Datasource UIDs are fixed: Prometheus `PBFA97CFB590B2093`, CloudWatch `P034F075C744B399F`.

### CloudWatch Alarms

| Alarm | Condition | `treat_missing_data` |
|-------|-----------|----------------------|
| `ecs-high-cpu` | ECS CPU > 70% for 10 min | breaching |
| `ecs-high-memory` | ECS Memory > 75% for 10 min | breaching |
| `ecs-low-task-count` | Running tasks < 2 for 2 min | breaching |
| `ecs-service-degraded` *(composite)* | low-task-count AND unhealthy-hosts both firing | — |
| `alb-5xx` | 5xx errors > 10 in 5 min | notBreaching |
| `alb-unhealthy-hosts` | Unhealthy targets ≥ 1 for 2 min | notBreaching |
| `alb-traffic-drop` | Requests < 5/min for 10 min | notBreaching |
| `rds-high-cpu` | RDS CPU > 70% for 15 min | breaching |
| `rds-low-storage` | Free storage < 2 GB for 10 min | breaching |
| `rds-high-connections` | Connections > 60 for 10 min | breaching |
| `grafana-unhealthy` | Grafana ALB target unhealthy for 2 min | breaching |

All alarms publish to SNS topic `flask-sre-ecs-dev-alerts` → `daniyal.tufail@xgrid.co`.

---

## Daily Reliability Report

Runs daily at 06:00 UTC (11:00 AM PKT). Collects SLI values from Prometheus, ECS service health, RDS metrics, ALB traffic, alarm states, and app log errors — then publishes a structured report to SNS.

```bash
# Dry run (print to stdout)
python3 scripts/daily-reliability-report.py --dry-run

# Publish to SNS
python3 scripts/daily-reliability-report.py
```

---

## Security

- **Credentials** — DB password is auto-generated and stored in Secrets Manager; injected into ECS tasks at runtime. Never in plaintext or committed to git.
- **KMS** — Customer-managed CMK with automatic rotation encrypts EFS, RDS, and Secrets Manager. `kms:ViaService` conditions restrict usage to those services only.
- **Network** — RDS and ECS tasks are in private subnets with no public IPs. Only the ALB exposes port 80 to the internet.
- **ECS exec** — `enable_execute_command = false` on all services.
- **SSH** — No SSH keys on any EC2. Access via SSM Session Manager only.

---

## Teardown

```bash
# Take a manual RDS snapshot first
aws rds create-db-snapshot \
  --db-instance-identifier <rds_identifier from terraform output> \
  --db-snapshot-identifier flask-sre-manual-$(date +%Y%m%d) \
  --region us-east-1

# Destroy all infrastructure
terraform destroy
```

> `deletion_protection = false` is intentional for dev. Set to `true` before any staging or production deployment.
