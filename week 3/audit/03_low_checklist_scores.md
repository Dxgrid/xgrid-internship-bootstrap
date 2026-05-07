# PRODUCTION-READINESS AUDIT — LOW/INFO + CHECKLISTS + SCORES
## Project: WordPress ECS HA | Auditor: Senior SRE | Date: 2026-05-06

---

## CATEGORY 4 — LOW / INFO ISSUES

---

### L-01 | Tags Duplicated in All Module Resources (Not Using default_tags)
- **SEVERITY:** LOW
- **FILE:** All module `main.tf` files — every resource block
- **ISSUE:** Every single resource in every module manually sets `Project` and
  `Environment` tags, even though the provider in `environments/dev/provider.tf`
  already sets `default_tags` with `Project`, `Environment`, `ManagedBy`, and `Owner`.
- **WHY:** `default_tags` in the provider automatically applies tags to all
  resources. The manual tags in each resource block create duplicate keys, which
  is redundant and adds noise. If the tag key name changes, it must be updated in
  50+ places instead of one.
- **FIX:** Remove redundant `Project` and `Environment` tag entries from all
  resource blocks in all modules. Keep only resource-specific tags like `Name`
  and `Tier`:
```hcl
# BEFORE (modules/vpc/main.tf)
tags = {
  Name        = "${var.project_name}-${var.environment}-vpc"
  Project     = var.project_name       # REMOVE — already in default_tags
  Environment = var.environment        # REMOVE — already in default_tags
}

# AFTER
tags = {
  Name = "${var.project_name}-${var.environment}-vpc"
}
```

---

### L-02 | ASG Uses $Latest Launch Template Version
- **SEVERITY:** LOW
- **FILE:** `modules/ecs/main.tf` line 330
- **ISSUE:** `version = "$Latest"` means any update to the launch template
  immediately affects the ASG, even before instance refresh runs.
- **WHY:** If a bad launch template is applied, `$Latest` means new instances
  immediately use the bad config. Pinning to a specific version or using
  `$Default` allows controlled promotion.
- **FIX:**
```hcl
launch_template {
  id      = aws_launch_template.ecs_instance.id
  version = aws_launch_template.ecs_instance.latest_version  # Terraform-managed
}
```
This references the Terraform-known version, not always the AWS-latest.

---

### L-03 | No ManagedBy Tag in Module-Level Tags
- **SEVERITY:** LOW
- **FILE:** All module `main.tf` files
- **ISSUE:** The provider `default_tags` sets `ManagedBy = "Terraform"`, but some
  resources inside modules set their own `tags` block which — due to Terraform's
  merging behavior — the `ManagedBy` tag from `default_tags` IS still applied.
  However the `Owner` tag from `default_tags` (`var.owner_name`) is never set
  in the modules since they have no `owner_name` variable. Default tags cover this
  but only when called from the dev environment — if modules are called from
  a different root without default_tags, they lose owner tracking.
- **FIX:** INFO only — current setup is correct. Document this in module README.

---

### L-04 | README.md is Nearly Empty
- **SEVERITY:** LOW
- **FILE:** `week 3/README.md` — 1 line: `# Week 3 Terraform Project`
- **ISSUE:** No documentation exists for: architecture overview, prerequisites,
  how to initialize Terraform, how to deploy, how to destroy, module descriptions,
  input/output table, or troubleshooting guide.
- **WHY:** Onboarding a new engineer to this codebase would require reading all
  Terraform files from scratch. This is a maintainability failure.
- **FIX:** Minimum README should include:
```markdown
# WordPress ECS HA — Terraform Infrastructure

## Architecture
[Brief description of VPC, ECS, RDS, EFS, ALB, Monitoring setup]

## Prerequisites
- Terraform >= 1.5.0
- AWS CLI configured with appropriate permissions
- S3 bucket for remote state (see backend.tf)

## Quick Start
cd environments/dev
terraform init -backend-config=backend.hcl
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars

## Module Descriptions
| Module           | Purpose                                      |
|------------------|----------------------------------------------|
| vpc              | VPC, subnets, NAT Gateway, route tables       |
| security_groups  | SGs for ALB, ECS, RDS, EFS                   |
| secrets          | KMS CMK, Secrets Manager, random password     |
| efs              | EFS filesystem, access point, mount targets   |
| rds              | RDS MySQL 8.0, parameter group, monitoring    |
| alb              | Application Load Balancer, target group       |
| ecs              | ECS cluster, ASG, task definition, service    |
| monitoring       | CloudWatch alarms, SNS, dashboard             |

## Inputs
[Table of all root-level variables]

## Outputs
[Table of all outputs]

## Destroying
terraform destroy -var-file=terraform.tfvars
# NOTE: RDS deletion_protection must be false before destroy
```

---

### L-05 | EFS Access Point posix_user Not Set
- **SEVERITY:** LOW
- **FILE:** `modules/efs/main.tf` lines 18–36
- **ISSUE:** `aws_efs_access_point.wordpress` sets `root_directory` with
  `owner_uid = 33` and `owner_gid = 33` (www-data), but does not set a
  `posix_user` block.
- **WHY:** Without `posix_user`, the container's default user (root, uid=0 in
  the WordPress Docker image) is used for all EFS operations. Setting `posix_user`
  to uid/gid 33 enforces that all writes use www-data identity regardless of what
  the container runs as — this is a defense-in-depth measure.
- **FIX:**
```hcl
resource "aws_efs_access_point" "wordpress" {
  file_system_id = aws_efs_file_system.wordpress.id

  posix_user {
    uid = 33  # www-data
    gid = 33
  }

  root_directory {
    path = "/wordpress"
    creation_info {
      owner_gid   = 33
      owner_uid   = 33
      permissions = "755"
    }
  }
  # ... tags
}
```

---

### L-06 | No EFS Backup Policy
- **SEVERITY:** LOW
- **FILE:** `modules/efs/main.tf` (missing)
- **ISSUE:** No `aws_efs_backup_policy` resource exists. EFS Backup is disabled
  by default.
- **WHY:** WordPress media files (uploaded images, themes, plugins) live on EFS.
  Without backups, a filesystem corruption or accidental deletion is unrecoverable.
  AWS Backup for EFS costs $0.05/GB/month — very cheap insurance.
- **FIX:**
```hcl
resource "aws_efs_backup_policy" "wordpress" {
  file_system_id = aws_efs_file_system.wordpress.id

  backup_policy {
    status = "ENABLED"
  }
}
```

---

### L-07 | No S3 Lifecycle Policy on Terraform State Bucket
- **SEVERITY:** LOW
- **FILE:** `environments/dev/backend.tf` — references S3 bucket (bucket not managed by Terraform here)
- **ISSUE:** The state S3 bucket `wordpress-ecs-tfstate-xgrid-1777960641` presumably
  has versioning enabled (required for `use_lockfile`), but no lifecycle policy to
  expire old state versions. Every `terraform apply` creates a new state version.
- **WHY:** Old state versions accumulate indefinitely at S3 storage cost. More
  importantly, old state versions may contain historical secrets (DB passwords
  before rotation). Retaining them longer than necessary increases the blast radius
  of a bucket compromise.
- **FIX:** Apply a lifecycle rule to the state bucket (via console or separate
  Terraform bootstrap):
```hcl
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
```

---

### L-08 | ECS ASG Health Check Type is EC2, Not ELB
- **SEVERITY:** LOW
- **FILE:** `modules/ecs/main.tf` line 325
- **ISSUE:** `health_check_type = "EC2"` means the ASG only replaces instances
  that AWS considers terminated/stopped at the EC2 level. An instance running
  ECS tasks that are all unhealthy (ALB health checks failing) but the EC2 itself
  is "running" will NOT be replaced by the ASG.
- **WHY:** With `EC2` health checks, a hung EC2 instance that passes EC2-level
  checks but has failing ECS tasks will remain in the ASG forever. The ECS service
  will keep trying to replace tasks but the bad instance stays.
- **FIX:**
```hcl
health_check_type         = "ELB"   # Use ALB health checks to drive ASG replacement
health_check_grace_period = 300
```
Note: Requires ALB to be attached. For ECS with EC2 launch type, EC2 is
acceptable if ECS managed termination protection is handling task protection.

---

### L-09 | RDS Storage Alarm evaluation_periods = 1 (Noisy)
- **SEVERITY:** LOW
- **FILE:** `modules/rds/main.tf` line 212
- **ISSUE:** `evaluation_periods = 1` on the `rds_storage` alarm means a single
  5-minute period below 2GB free triggers the alarm.
- **WHY:** A single transient data point below threshold (e.g., during a large
  write operation) will fire the alarm. `evaluation_periods = 2` or `3` is safer
  to confirm the trend.
- **FIX:**
```hcl
resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  evaluation_periods = 2  # Require 2 consecutive periods (10 minutes)
  # ...
}
```

---

### L-10 | No VPC Flow Logs
- **SEVERITY:** LOW (INFO for dev, MEDIUM for prod)
- **FILE:** `modules/vpc/main.tf` (missing)
- **ISSUE:** No `aws_flow_log` resource for the VPC. All network traffic is
  unlogged.
- **WHY:** VPC Flow Logs are the only way to detect: port scanning, unexpected
  outbound connections (malware C2), failed connection attempts to RDS (brute
  force), and anomalous data exfiltration patterns.
- **FIX:**
```hcl
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/vpc/${var.project_name}-${var.environment}/flow-logs"
  retention_in_days = 30
}

resource "aws_iam_role" "flow_logs" {
  name_prefix = "${var.project_name}-${var.environment}-flow-logs-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_flow_log" "vpc" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
}
```

---

## CATEGORY 5 — MISSING PRODUCTION SAFEGUARDS (INFO)

These are expected gaps for a dev environment but MUST be resolved before
production promotion.

| # | Item | Status |
|---|------|--------|
| P-01 | HTTPS listener on ALB (port 443) | ❌ Missing — HTTP only |
| P-02 | ACM certificate provisioned | ❌ Missing |
| P-03 | Route53 hosted zone + DNS alias record | ❌ Missing |
| P-04 | WAF attached to ALB | ❌ Missing |
| P-05 | CloudFront distribution | ❌ Missing |
| P-06 | RDS Multi-AZ enabled | ❌ Disabled (dev acceptable) |
| P-07 | RDS Read Replica | ❌ Missing |
| P-08 | Cross-region RDS backup | ❌ Missing |
| P-09 | EFS Backup Policy enabled | ❌ Missing |
| P-10 | AWS Config rules for compliance | ❌ Missing |
| P-11 | AWS GuardDuty enabled | ❌ Missing |
| P-12 | AWS CloudTrail enabled | ❌ Missing |
| P-13 | S3 access logging on state bucket | ❌ Missing |
| P-14 | VPC Flow Logs | ❌ Missing |
| P-15 | SNS subscription confirmed | ⚠️ Must be done manually after apply |
| P-16 | Dead letter queue on SNS topic | ❌ Missing |
| P-17 | RDS deletion_protection = true | ❌ Must be set for prod |
| P-18 | ALB deletion_protection = true | ❌ Must be set for prod |
| P-19 | skip_final_snapshot = false (RDS) | ❌ Must be set for prod |
| P-20 | Per-AZ NAT Gateways | ❌ Single NAT (AZ SPOF) |
| P-21 | VPC endpoints for Secrets Manager/ECR | ❌ Missing |
| P-22 | RDS max_allocated_storage > 20 | ❌ Autoscaling disabled |
| P-23 | terraform.tfvars.example file | ❌ Missing |
| P-24 | Full README with deployment docs | ❌ Only 1-line placeholder |
| P-25 | Image pinned to digest (not mutable tag) | ❌ wordpress:6.5-apache is mutable |

---

## PRODUCTION PROMOTION CHECKLIST

### Security (Complete ALL before prod)
- [ ] Fix KMS key policy — replace `Principal: "*"` with account-scoped principal (C-01)
- [ ] Add VPC endpoints for Secrets Manager, ECR, S3, KMS, CloudWatch Logs (C-02)
- [ ] Wire SNS topic ARN into RDS and ALB alarm_actions (C-03)
- [ ] Rotate any credentials exposed in committed tfplan files (C-05)
- [ ] Add HTTPS listener on ALB with ACM certificate (P-01, P-02)
- [ ] Attach WAF to ALB (P-04)
- [ ] Pin Docker image to immutable digest or use ECR (H-08)
- [ ] Encrypt SNS topic with CMK (H-09)
- [ ] Enable RDS deletion_protection = true (M-08)
- [ ] Enable ALB enable_deletion_protection = true (M-09)
- [ ] Enable GuardDuty (P-11)
- [ ] Enable CloudTrail (P-12)

### Reliability (Complete ALL before prod)
- [ ] Add second NAT Gateway for AZ redundancy, or add VPC endpoints to replace NAT (H-01)
- [ ] Set RDS multi_az = true (P-06)
- [ ] Set skip_final_snapshot = false with final_snapshot_identifier (P-19)
- [ ] Increase max_allocated_storage to 100+ (H-07)
- [ ] Switch storage_type to gp3 (M-03)
- [ ] Enable EFS backup policy (L-06, P-09)
- [ ] Configure Route53 DNS and ACM cert (P-03)

### Terraform Quality (Complete before prod)
- [ ] Add environment validation blocks to all modules (H-06)
- [ ] Move CIDR blocks to variables (H-03)
- [ ] Remove hardcoded region from dashboard JSON (H-04)
- [ ] Remove tfplan, tfpan, *.log from repo and gitignore them (C-05)
- [ ] Create terraform.tfvars.example (C-04)
- [ ] Fix recovery_window_in_days to 7 for prod (H-05)
- [ ] Consolidate to single secret version (M-10)
- [ ] Add sensitive = true to secret_arn, rds_endpoint outputs (M-11)
- [ ] Write full README (L-04)
- [ ] Add RDS CloudWatch log group resources with retention (M-13)
- [ ] Add S3 lifecycle policy to state bucket (L-07)
- [ ] Add VPC Flow Logs (L-10)
- [ ] Add EFS posix_user block (L-05)

### Observability (Complete before prod)
- [ ] Confirm SNS email subscription (P-15)
- [ ] Add ALB access logs S3 bucket (M-06)
- [ ] Separate SNS topics per severity (critical vs warning)
- [ ] Add Dead Letter Queue to SNS topic (P-16)
- [ ] Verify composite alarm triggers correctly

---

## OVERALL SCORES

| Category | Score | Notes |
|----------|-------|-------|
| **Security** | **4/10** | KMS policy wildcard principal (C-01) and no VPC endpoints (C-02) are serious flaws. Silent alarms (C-03) mean outages go unnoticed. Good: IAM roles are split correctly, EFS uses TLS, secrets injected properly. |
| **Reliability** | **6/10** | Good: Circuit breaker, deployment spread, health check grace period, EFS mount targets in 2 AZs. Bad: Single NAT Gateway AZ SPOF, no RDS Multi-AZ, autoscaling storage disabled, no EFS backups. |
| **Terraform Quality** | **6/10** | Good: Modules are clean, lifecycle blocks present, SSM for AMI. Bad: Hardcoded values (CIDRs, region, instance type), no variable validation, duplicate tags everywhere, count vs for_each, two conflicting secret versions. |
| **Cost Awareness** | **5/10** | Good: EFS elastic throughput, log retention set (7 days), max_size=2 on ASG. Bad: No VPC endpoints (NAT bills), log groups for RDS never created (infinite retention), no S3 lifecycle on state bucket, single NAT is actually a cost SAVING (tradeoff acknowledged). |
| **Overall** | **5/10** | Solid foundation for a learning exercise. The module decomposition, IAM role separation, EFS TLS enforcement, and Secrets Manager integration show good understanding. The KMS wildcard principal and silent alarms are the blockers. With the fixes in this audit applied, this becomes a respectable 8/10. |

---

## QUICK-WIN PRIORITY ORDER

If the intern fixes things in this order, they get maximum impact per hour:

1. **Fix KMS wildcard principal** (C-01) — 15 min, eliminates worst security hole
2. **Wire SNS to RDS/ALB alarms** (C-03) — 30 min, all alarms become actionable
3. **Delete tfplan/log files, update .gitignore** (C-05) — 10 min, stop secret leakage
4. **Add environment validation** (H-06) — 20 min, prevents wrong-env accidents
5. **Move CIDRs to variables** (H-03) — 20 min, enables multi-environment use
6. **Fix recovery_window_in_days** (H-05) — 5 min, prevents accidental data loss
7. **Remove hardcoded region from dashboard** (H-04) — 15 min, makes code portable
8. **Add EFS backup policy** (L-06) — 5 min, protects WordPress media files
9. **Add posix_user to EFS access point** (L-05) — 5 min, security hardening
10. **Write README** (L-04) — 45 min, enables team collaboration
