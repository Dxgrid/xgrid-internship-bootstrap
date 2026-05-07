# Highly Available WordPress on AWS ECS (Terraform)

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.5.0-purple) ![AWS](https://img.shields.io/badge/AWS-us--east--1-orange) ![Environment](https://img.shields.io/badge/Environment-dev-blue) ![Status](https://img.shields.io/badge/Status-Live-green)

**Module:** `CL-ECS-HA | CL-08` · **Author:** SRE Intern — Week 3 · **Account:** `432500708329`

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Component Breakdown](#2-component-breakdown)
3. [Network & Security Design](#3-network--security-design)
4. [Deployment Guide](#4-deployment-guide)
5. [Post-Deploy Verification](#5-post-deploy-verification)
6. [High Availability Test](#6-high-availability-test)
7. [Troubleshooting](#7-troubleshooting)
8. [Known Limitations](#8-known-limitations)
9. [Cost Analysis](#9-cost-analysis)
10. [Module Reference](#10-module-reference)

---

## 1. Architecture Overview

This project deploys a production-style, highly available WordPress site on AWS using Terraform. WordPress runs as a containerised ECS service (EC2 launch type) spread across two Availability Zones. Shared state (uploads, plugins, themes) is stored on EFS so every container sees the same files. The database is RDS MySQL 8.0. An Application Load Balancer sits in front and routes traffic to whichever tasks are healthy.

```
Internet
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  IGW  (internet gateway)                                    │
│    │                                                         │
│    ▼                                                         │
│  ALB  (HTTP:80, sticky sessions)          PUBLIC SUBNETS    │
│   10.0.1.0/24 (us-east-1a) │ 10.0.2.0/24 (us-east-1b)     │
└───────────────┬─────────────────────────────────────────────┘
                │  ALB → ECS SG (port 80 only)
┌───────────────▼─────────────────────────────────────────────┐
│  ECS Task (AZ-a)          ECS Task (AZ-b)   PRIVATE SUBNETS │
│  10.0.3.0/24              10.0.4.0/24                        │
│       │   │                    │   │                         │
│       │   └──── EFS (NFS/2049, both AZs, TLS enforced) ─────┤
│       │                        │                             │
│       └────────┬───────────────┘                            │
│                ▼                                             │
│         RDS MySQL 8.0  (private subnet, port 3306)          │
│                                                              │
│  NAT GW (us-east-1a) ──► Secrets Manager / KMS / ECR       │
└─────────────────────────────────────────────────────────────┘

KMS CMK ──► encrypts: EFS · RDS · Secrets Manager
CloudWatch ◄── ECS Container Insights + custom alarms
SNS ──────► email alerts
S3 ────────► Terraform remote state (versioned, AES-256)
ASG ───────► wraps EC2 instances, protect_from_scale_in=true
```

---

## 2. Component Breakdown

| Component | AWS Service | Purpose | Free Tier | Notes |
|---|---|---|---|---|
| VPC | Amazon VPC | Isolated network `10.0.0.0/16` | ✅ | |
| Public Subnets | VPC Subnet | ALB placement, 2 AZs | ✅ | `10.0.1.0/24`, `10.0.2.0/24` |
| Private Subnets | VPC Subnet | ECS, RDS, EFS, 2 AZs | ✅ | `10.0.3.0/24`, `10.0.4.0/24` |
| Internet Gateway | IGW | Inbound internet to ALB | ✅ | |
| NAT Gateway | NAT GW | Outbound-only from private | ❌ | ~$32/mo — biggest cost driver |
| ALB | ALB | HTTP:80 ingress, sticky sessions | ❌ | ~$16-18/mo |
| ECS Cluster | ECS | EC2 capacity provider host | ✅ | Container Insights enabled |
| EC2 Instances | t2.micro × 2 | ECS container hosts | ✅* | *750 hrs free; 2 = 1460 hrs |
| ECS Service | ECS Service | Maintains desired 2 tasks | ✅ | Circuit breaker + auto-rollback |
| Task Definition | ECS Task | `wordpress:6.5-apache` | ✅ | Secrets injected at runtime |
| RDS MySQL | db.t3.micro | WordPress database | ✅ | 20 GB gp2, single-AZ |
| EFS | Elastic FS | Shared `/var/www/html` | ✅* | *5 GB free; elastic throughput |
| Secrets Manager | Secrets Manager | DB credentials at runtime | ❌ | ~$0.40/mo |
| KMS CMK | KMS | Encrypts EFS, RDS, Secrets | ❌ | ~$1/mo |
| CloudWatch | CloudWatch | Logs, metrics, alarms, dashboard | ✅* | *10 metrics/alarms free |
| SNS | SNS | Email alarm notifications | ✅ | Confirm subscription after deploy |
| S3 State Bucket | S3 | Terraform remote state | ✅ | Versioned, AES-256, no public access |

---

## 3. Network & Security Design

### 3-Tier Network

| Tier | Subnets | What lives here |
|---|---|---|
| Public | `10.0.1.0/24`, `10.0.2.0/24` | ALB, NAT Gateway |
| Private (app) | `10.0.3.0/24`, `10.0.4.0/24` | ECS tasks |
| Private (data) | same private subnets | RDS, EFS mount targets |

ECS tasks have no public IP. All outbound AWS API traffic flows via the NAT Gateway.

### Security Group Chain

```
Internet:any → ALB SG:80 → ECS SG:80 → RDS SG:3306
                                      → EFS SG:2049
```

No CIDR-based ingress rules. Each SG references the upstream SG as its source — a task cannot reach RDS directly without going through the ECS security group.

### 🔒 Additional Security Controls

- **KMS CMK** with `kms:ViaService` conditions — EFS and Secrets Manager can only use the key via their own service principals.
- **Secrets Manager** injects `WORDPRESS_DB_*` environment variables at task start. Credentials never appear in task definitions or source code.
- **EFS resource policy** enforces `aws:SecureTransport = true` (TLS-only NFS) and IAM authentication on the access point.
- **IAM separation:** three distinct roles — EC2 instance profile, task execution role (pull image, read secret), task role (mount EFS).

---

## 4. Deployment Guide

### 4.1 Prerequisites

| Tool | Version | Install |
|---|---|---|
| Terraform | ≥ 1.5.0 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | v2 | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Git | any | system package manager |
| jq | any | `apt install jq` / `brew install jq` |

Configure AWS credentials:

```bash
aws configure
# AWS Access Key ID: <your-key>
# AWS Secret Access Key: <your-secret>
# Default region: us-east-1
# Default output format: json
```

### 4.2 Clone the Repository

```bash
git clone <repo-url>
cd "xgrid-internship-bootstrap/week 3"
```

### 4.3 Bootstrap Remote State (one-time)

This script creates an S3 bucket with versioning, AES-256 encryption, and public access blocking. Run it once per AWS account.

```bash
chmod +x scripts/create-remote-state.sh
./scripts/create-remote-state.sh
```

The script prints the bucket name. Copy the output values into `environments/dev/backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket       = "<printed-bucket-name>"
    key          = "dev/wordpress/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
```

### 4.4 Configure Variables

```bash
cd environments/dev
cp terraform.tfvars.example terraform.tfvars   # if example exists, else edit directly
nano terraform.tfvars
```

Minimum required content:

```hcl
aws_region   = "us-east-1"
environment  = "dev"
project_name = "wordpress-ecs-ha"
owner_name   = "your-name"
alert_email  = "you@example.com"   # SNS alarm destination
```

### 4.5 Initialise, Validate, Plan

```bash
cd environments/dev

terraform init
terraform validate
terraform fmt -recursive
terraform plan -out=tfplan
# Expected: ~45 resources to create
```

Review the plan output before applying. Pay attention to any `destroy` or `replace` actions.

### 4.6 Apply

```bash
terraform apply tfplan
```

**Estimated provisioning times:**

| Resource | Time |
|---|---|
| VPC + networking | ~30 s |
| Security groups | ~10 s |
| KMS + Secrets Manager | ~15 s |
| EFS + mount targets | ~30 s |
| RDS MySQL (slowest) | ~10–12 min |
| ECS cluster + ASG | ~3–5 min |
| ALB | ~2–3 min |
| CloudWatch + SNS | ~30 s |
| **Total** | **~20–25 min** |

---

## 5. Post-Deploy Verification

```bash
# 1. Get the WordPress URL
terraform output alb_dns_name

# 2. Confirm HTTP response (expect 302 Found — WordPress setup redirect)
curl -I http://$(terraform output -raw alb_dns_name)

# 3. Verify ECS tasks are running
aws ecs describe-services \
  --cluster wordpress-ecs-ha-dev-cluster \
  --services wordpress-ecs-ha-dev-wordpress-svc \
  --region us-east-1 \
  --query "services[0].{Running:runningCount,Desired:desiredCount}" \
  --output table
# Expected: Running=2, Desired=2

# 4. Verify RDS is available
aws rds describe-db-instances \
  --db-instance-identifier $(terraform output -raw rds_identifier) \
  --region us-east-1 \
  --query "DBInstances[0].{Status:DBInstanceStatus,Endpoint:Endpoint.Address}" \
  --output table
# Expected: Status=available

# 5. Verify secret contains all 5 keys
aws secretsmanager get-secret-value \
  --secret-id wordpress-ecs-ha/dev/db-credentials \
  --region us-east-1 | jq '.SecretString | fromjson | keys'
# Expected: ["dbname","host","password","port","username"]
```

> ⚠️ **SNS Email Confirmation** — After apply, check your inbox for an email from AWS with subject "AWS Notification — Subscription Confirmation". Click the link. Without this step, no alarm notifications will be delivered.

---

## 6. Deep Troubleshooting Guide

### ❌ Issue: ECS Tasks stuck in `PROVISIONING` or `Running: 0`
**Symptoms:** `aws ecs describe-services` shows 0 running tasks, and `aws ecs list-container-instances` returns `[]`.

**Root Cause (The "Agent Race Condition"):**
The ECS Agent on the EC2 instances sometimes starts before the `user_data` script finishes writing the cluster name to `/etc/ecs/ecs.config`. The agent then defaults to a cluster named "default" and fails to join yours.

**The Fix:**
1.  **Check if instances are "lost":**
    ```bash
    aws ecs list-container-instances --cluster wordpress-ecs-ha-dev-cluster --region us-east-1
    ```
2.  **If `[]` is returned, recycle the instances:**
    Identify your instances in the EC2 console or via CLI and terminate them. The Auto Scaling Group will replace them with new instances using the latest (fixed) Launch Template.
3.  **Wait 3 minutes:** The new instances will boot, restart the ECS agent correctly, and join the cluster.

---

## 7. Scaling Simulation (Intern Task)

### How to Scale the Service
1.  Open `environments/dev/terraform.tfvars`.
2.  Add or change `desired_count = 1`.
3.  Run `terraform apply -var-file=terraform.tfvars`.

### How to check which EC2 Instance is running the Task
When you scale down to 1, use this "one-liner" to find exactly which server is hosting your WordPress:

```bash
# Get the EC2 Instance ID of the RUNNING task
aws ecs describe-container-instances \
  --cluster wordpress-ecs-ha-dev-cluster \
  --region us-east-1 \
  --container-instances $(aws ecs describe-tasks \
    --cluster wordpress-ecs-ha-dev-cluster \
    --region us-east-1 \
    --tasks $(aws ecs list-tasks \
      --cluster wordpress-ecs-ha-dev-cluster \
      --desired-status RUNNING --region us-east-1 \
      --query "taskArns[0]" --output text) \
    --query "tasks[0].containerInstanceArn" --output text) \
  --query "containerInstances[0].ec2InstanceId" --output text
```

---

## 8. Common SRE Debugging Commands

## 9. High Availability Test

Kill one ECS task and verify the site stays up and ECS self-heals within ~60 seconds.

```bash
# Get a running task ARN
TASK=$(aws ecs list-tasks \
  --cluster wordpress-ecs-ha-dev-cluster \
  --region us-east-1 \
  --query "taskArns[0]" --output text)

# Kill it
aws ecs stop-task \
  --cluster wordpress-ecs-ha-dev-cluster \
  --task $TASK \
  --reason "HA test" \
  --region us-east-1

# Watch self-heal (run every 15s)
watch -n 15 "aws ecs describe-services \
  --cluster wordpress-ecs-ha-dev-cluster \
  --services wordpress-ecs-ha-dev-wordpress-svc \
  --region us-east-1 \
  --query 'services[0].{Running:runningCount,Desired:desiredCount}' \
  --output table"
# Expected: Running: 2 → 1 → 2
```

While the task is restarting, WordPress should remain accessible via the ALB (second task is still healthy).

---

## 7. Troubleshooting

### ECS Tasks Not Starting (RunningCount = 0)

```bash
# Check service events
aws ecs describe-services \
  --cluster wordpress-ecs-ha-dev-cluster \
  --services wordpress-ecs-ha-dev-wordpress-svc \
  --region us-east-1 \
  --query "services[0].events[:5]" --output table

# Inspect last stopped task
aws ecs describe-tasks \
  --cluster wordpress-ecs-ha-dev-cluster \
  --tasks $(aws ecs list-tasks \
    --cluster wordpress-ecs-ha-dev-cluster \
    --desired-status STOPPED --region us-east-1 \
    --query "taskArns[0]" --output text) \
  --region us-east-1 \
  --query "tasks[0].{StopReason:stoppedReason,Error:containers[0].reason}" \
  --output json
```

| Error message | Root cause | Fix |
|---|---|---|
| `access denied by server while mounting` | `amazon-ecs-volume-plugin` not running | Verify `user_data` enables the plugin service |
| `CannotPullContainerError` | NAT Gateway or SG egress issue | Check route table and ECS SG egress rules |
| `ResourceInitializationError` | Secrets Manager unreachable | Verify task execution role has `secretsmanager:GetSecretValue` + `kms:Decrypt` |
| `lchown: operation not permitted` | EFS POSIX UID mismatch | Match access point UID to `www-data` (UID 33) |

### WordPress Shows "Error establishing a database connection"

```bash
# Confirm secret has the host field (empty before first RDS apply)
aws secretsmanager get-secret-value \
  --secret-id wordpress-ecs-ha/dev/db-credentials \
  --region us-east-1 | jq '.SecretString | fromjson'
```

If `host` is empty, re-run `terraform apply` — the secrets module updates the host field after RDS is provisioned.

### Terraform Apply Fails

| Error | Fix |
|---|---|
| `No configuration files` | Wrong directory — `cd environments/dev` |
| `Error acquiring state lock` | Previous apply interrupted — check S3 for `.lock` file and delete it |
| `AccessDenied` | IAM user missing permissions |
| `Resource already exists` | State drift — run `terraform import` or `terraform refresh` |

### SNS Emails Not Arriving

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn $(aws sns list-topics --region us-east-1 \
    --query "Topics[?contains(TopicArn,'wordpress-ecs-ha-dev')].TopicArn" \
    --output text) \
  --region us-east-1 \
  --query "Subscriptions[0].{Status:SubscriptionArn,Email:Endpoint}" \
  --output table
```

If status is `PendingConfirmation`, check your spam folder for the AWS confirmation email.

---

## 11. Known Limitations

| # | Limitation | Why Accepted | Production Fix |
|---|---|---|---|
| 1 | **HTTP only** — no HTTPS, browser shows "Not Secure" | No domain or ACM cert in dev scope | Register domain in Route53, provision ACM cert, add HTTPS listener, redirect 80→443 |
| 2 | **Single NAT Gateway** — us-east-1a only; if that AZ fails, private subnets in us-east-1b lose internet | Each NAT ~$32/mo — doubled cost for dev | One NAT per AZ; add `single_nat_gateway` variable |
| 3 | **No VPC Endpoints** — AWS API traffic exits via NAT | VPC interface endpoints ~$7/each × 5 = ~$35/mo | Add endpoints for `secretsmanager`, `ecr.api`, `ecr.dkr`, `logs`, `kms`; free S3 gateway endpoint |
| 4 | **RDS not Multi-AZ** — single instance; AZ failure = DB down | Multi-AZ doubles RDS cost | `multi_az = true` on `aws_db_instance` |
| 5 | **No WAF** — WordPress exposed to bot/injection attacks | AWS WAF $5/mo base + usage | Attach `aws_wafv2_web_acl` to ALB |
| 6 | **Mutable image tag** `wordpress:6.5-apache` | Fine for dev; gets minor patches automatically | Pin to immutable digest or push to private ECR |
| 7 | **RDS and ALB alarms silent** — `alarm_actions = []` | SNS topic is in a separate module | Pass `sns_topic_arn` into `rds` and `alb` modules |

---

## 12. Cost Analysis

### Dev Environment (Monthly)

| Service | Config | Cost |
|---|---|---|
| EC2 (×2 t2.micro) | 730 hrs/mo | $0 *(Free Tier — 750 hrs; 2 instances = 1460 hrs, exceeds Free Tier after month 1)* |
| RDS db.t3.micro | 730 hrs/mo | $0 *(Free Tier — 750 hrs/mo)* |
| EFS | ~1 GB elastic | ~$0.30 |
| ALB | 1 ALB, low traffic | ~$16–18 |
| NAT Gateway | 1×, ~1 GB/mo | ~$32–35 |
| Secrets Manager | 1 secret | ~$0.40 |
| KMS CMK | 1 key | ~$1.00 |
| CloudWatch | 7-day log retention | ~$1–2 |
| SNS | Email notifications | ~$0.00 |
| S3 | <1 MB state file | ~$0.00 |
| **Total** | | **~$51–57/mo** |

> 💰 **Biggest cost drivers:** NAT Gateway (~$32) → ALB (~$17) → EC2 after Free Tier (~$17). Run `terraform destroy` when not actively testing to save ~$50/mo.

### Production Projection

| Service | Change | Monthly |
|---|---|---|
| EC2 | 4× t3.medium (2 per AZ) | ~$120 |
| RDS | db.t3.medium, Multi-AZ | ~$100 |
| ALB | Higher traffic | ~$25–50 |
| NAT Gateway | 2× (one per AZ) | ~$65 |
| VPC Endpoints | 5× interface + 1× S3 gateway | ~$35 |
| WAF | Basic rule set | ~$10 |
| **Total** | | **~$355–380/mo** |

---

## 13. Module Reference

### Inputs

| Module | Variable | Type | Description |
|---|---|---|---|
| `vpc` | `vpc_cidr` | string | VPC CIDR block |
| `vpc` | `public_subnet_cidrs` | list(string) | Public subnet CIDRs |
| `vpc` | `private_subnet_cidrs` | list(string) | Private subnet CIDRs |
| `vpc` | `availability_zones` | list(string) | AZs to use |
| `security_groups` | `vpc_id` | string | VPC to attach SGs to |
| `secrets` | `db_host` | string | RDS endpoint (filled after RDS apply) |
| `efs` | `kms_key_arn` | string | CMK for encryption at rest |
| `efs` | `ecs_task_role_arn` | string | Task role allowed in EFS resource policy |
| `rds` | `db_password` | string | Sensitive — from secrets module |
| `rds` | `kms_key_arn` | string | CMK for RDS storage encryption |
| `ecs` | `secret_arn` | string | Secrets Manager ARN injected into task |
| `ecs` | `efs_id` / `access_point_id` | string | EFS mount configuration |
| `ecs` | `target_group_arn` | string | ALB target group (empty = no ALB) |
| `alb` | `public_subnet_ids` | list(string) | ALB placement subnets |
| `monitoring` | `alert_email` | string | SNS email destination |
| `monitoring` | `cluster_name` / `service_name` | string | ECS dimensions for alarms |
| `monitoring` | `alb_arn_suffix` / `tg_arn_suffix` | string | ALB/TG dimensions for alarms |

### Outputs

| Module | Output | Description |
|---|---|---|
| `vpc` | `vpc_id` | VPC ID |
| `vpc` | `public_subnet_ids` / `private_subnet_ids` | Subnet ID lists |
| `secrets` | `secret_arn` | Passed to ECS task execution role |
| `secrets` | `kms_key_arn` | Shared across EFS, RDS, ECS |
| `efs` | `efs_id` / `access_point_id` | ECS volume configuration |
| `rds` | `rds_endpoint` / `rds_identifier` | DB host + CloudWatch dimension |
| `ecs` | `cluster_name` / `service_name` | Monitoring + CLI references |
| `ecs` | `ecs_task_role_arn` | Passed to EFS resource policy |
| `alb` | `alb_dns_name` | WordPress public URL |
| `alb` | `alb_arn_suffix` / `target_group_arn_suffix` | CloudWatch alarm dimensions |

---

## 14. Teardown

🚨 Always destroy the environment when done — the NAT Gateway and ALB accrue hourly charges.

```bash
cd environments/dev
terraform destroy
# Type 'yes' when prompted
# Expected: ~15 minutes (RDS deletion is the slowest step)

# Verify cleanup
aws rds describe-db-instances --region us-east-1
aws ecs list-clusters --region us-east-1
aws elbv2 describe-load-balancers --region us-east-1
```
