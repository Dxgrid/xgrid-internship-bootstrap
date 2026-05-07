# PRODUCTION-READINESS AUDIT — MEDIUM SEVERITY
## Project: WordPress ECS HA | Auditor: Senior SRE | Date: 2026-05-06

---

## CATEGORY 3 — MEDIUM SEVERITY ISSUES

---

### M-01 | Backend S3 Bucket Name Hardcoded in backend.tf
- **SEVERITY:** MEDIUM
- **FILE:** `environments/dev/backend.tf` lines 4–6
- **ISSUE:** `bucket = "wordpress-ecs-tfstate-xgrid-1777960641"` and
  `region = "us-east-1"` are hardcoded literals. The key path
  `"dev/wordpress/terraform.tfstate"` hardcodes both environment and project name.
- **WHY:** Terraform backend blocks cannot use variables (Terraform limitation),
  but the values should at minimum be documented and consistent with the naming
  convention used elsewhere. The account-ID suffix in the bucket name is good
  practice, but the region string should be consistent with the provider region.
  If someone copies this to staging and forgets to update the key, both environments
  share the same state file — catastrophic.
- **FIX:** Use a `backend.hcl` partial config file and pass it with `-backend-config`:
```hcl
# environments/dev/backend.hcl (committed, no secrets)
bucket       = "wordpress-ecs-tfstate-xgrid-1777960641"
key          = "dev/wordpress/terraform.tfstate"
region       = "us-east-1"
use_lockfile = true
encrypt      = true

# environments/dev/backend.tf — keep minimal:
terraform {
  backend "s3" {}
}
```
Run: `terraform init -backend-config=backend.hcl`
Each environment has its own `backend.hcl` with a unique key.

---

### M-02 | Root-Level .terraform.lock.hcl is Empty
- **SEVERITY:** 
- **FILE:** `week 3/.terraform.lock.hcl` (0 bytes)
- **ISSUE:** The root-level lock file is empty. The real lock file is at
  `environments/dev/.terraform.lock.hcl` (2483 bytes). An empty lock file at root
  is confusing — it was likely created by accident.
- **WHY:** The lock file must be committed so all team members and CI/CD use
  identical provider versions. The empty root file may cause confusion about which
  lock file is authoritative.
- **FIX:**
  - Delete the empty root-level `.terraform.lock.hcl`
  - Ensure `environments/dev/.terraform.lock.hcl` is NOT gitignored (it currently
    isn't — good). Add a comment to README explaining this.
  - Update `.gitignore` to only ignore `.terraform/` directories, not lock files.

---

### M-03 | gp2 Storage Type on RDS (Legacy)
- **SEVERITY:** MEDIUM
- **FILE:** `modules/rds/main.tf` line 135
- **ISSUE:** `storage_type = "gp2"` — gp2 is the previous-generation EBS storage type.
- **WHY:** gp3 provides the same cost at the base tier with 3000 IOPS and 125 MB/s
  throughput included (vs gp2's 100 IOPS baseline for 20GB). For a WordPress DB
  with frequent small reads/writes, this is a meaningful performance improvement at
  zero extra cost.
- **FIX:**
```hcl
storage_type = "gp3"
# Optional — explicitly set IOPS (default 3000 is already better than gp2)
# iops = 3000
```

---

### M-04 | No lifecycle ignore_changes on ECS Task Definition
- **SEVERITY:** MEDIUM
- **FILE:** `modules/ecs/main.tf` — `aws_ecs_task_definition.wordpress`
- **ISSUE:** If the ECS service is updated through the AWS Console or a CI/CD
  pipeline (blue/green deploy), Terraform on the next apply will see a task
  definition drift and want to replace the task definition, overwriting the
  pipeline-deployed version.
- **WHY:** This creates conflicts between Terraform and CI/CD pipelines. Common
  pattern is for pipeline to deploy new task def revisions; Terraform should manage
  the base definition but not fight with the pipeline.
- **FIX:**
```hcl
resource "aws_ecs_service" "wordpress" {
  # ... existing config ...

  lifecycle {
    ignore_changes = [
      task_definition,   # Allow CI/CD to update task definition
      desired_count      # Allow autoscaler to manage count
    ]
  }
}
```

---

### M-05 | No termination_policies on ASG
- **SEVERITY:** MEDIUM
- **FILE:** `modules/ecs/main.tf` — `aws_autoscaling_group.ecs` (around line 317)
- **ISSUE:** The ASG has no `termination_policies` defined. AWS defaults to
  `["Default"]` which uses a complex algorithm that may not make the most
  appropriate choice for ECS workloads.
- **WHY:** Without explicit termination policies, scale-in events might terminate
  the newer instance (with a fresh ECS agent and running tasks) over an older idle
  one. ECS managed termination protection (`protect_from_scale_in = true`) helps,
  but explicit policies make intent clear.
- **FIX:**
```hcl
resource "aws_autoscaling_group" "ecs" {
  # ... existing config ...
  termination_policies = ["OldestLaunchTemplate", "Default"]
}
```

---

### M-06 | No ALB Access Logs
- **SEVERITY:** MEDIUM
- **FILE:** `modules/alb/main.tf` lines 19–22
- **ISSUE:** `access_logs { bucket = "" enabled = false }` — access logging is
  explicitly disabled and the bucket is an empty string.
- **WHY:** ALB access logs are the primary forensic record for security incidents.
  Without them, you cannot answer: "Which IP launched that attack?", "When did
  that spike in 5xx errors start?", or "Was this a DDoS?". Logs are also required
  for PCI-DSS and SOC2 compliance.
- **FIX:**
```hcl
# Create a log bucket (add to modules/alb/main.tf or a dedicated logging module)
resource "aws_s3_bucket" "alb_logs" {
  bucket = "${var.project_name}-${var.environment}-alb-logs"
  force_destroy = var.environment != "prod"
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    expiration { days = 90 }
  }
}

# ALB requires a specific bucket policy to write logs
resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::127311923021:root" }  # us-east-1 ELB account
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/*"
    }]
  })
}

resource "aws_lb" "wordpress" {
  # ... existing config ...
  access_logs {
    bucket  = aws_s3_bucket.alb_logs.bucket
    prefix  = "alb"
    enabled = true
  }
}
```

---

### M-07 | ECS Container Uses count Instead of for_each for Subnets
- **SEVERITY:** MEDIUM
- **FILE:** `modules/vpc/main.tf` lines 23–50, `modules/efs/main.tf` line 39
- **ISSUE:** `aws_subnet.public`, `aws_subnet.private`, and
  `aws_efs_mount_target.wordpress` all use `count`. If a subnet CIDR changes in the
  middle of the list (e.g., you insert a new AZ), Terraform will destroy and
  recreate all subsequent resources.
- **WHY:** With `count`, resources are addressed by index (`aws_subnet.private[0]`).
  Removing index 0 causes index 1 to become index 0, triggering a destroy/replace
  of a live subnet with running tasks. `for_each` addresses by key, making
  insertions/deletions safe.
- **FIX:**
```hcl
# modules/vpc/main.tf — convert subnets to for_each
locals {
  public_subnets = {
    for i, cidr in var.public_subnet_cidrs :
    var.availability_zones[i] => {
      cidr = cidr
      az   = var.availability_zones[i]
    }
  }
}

resource "aws_subnet" "public" {
  for_each                = local.public_subnets
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.project_name}-${var.environment}-public-${each.key}"
    Tier        = "public"
    Project     = var.project_name
    Environment = var.environment
  }
}
```

---

### M-08 | No RDS Deletion Protection
- **SEVERITY:** MEDIUM
- **FILE:** `modules/rds/main.tf` line 164
- **ISSUE:** `deletion_protection = false` — correctly commented as dev-only, but
  there is no mechanism to enforce this changes to `true` for prod.
- **WHY:** Without deletion protection, a `terraform destroy` or accidental
  `aws rds delete-db-instance` command permanently deletes your database. With
  `skip_final_snapshot = true` also set, data is gone with no recovery path.
- **FIX:** Make it a variable:
```hcl
# modules/rds/variables.tf
variable "deletion_protection" {
  type        = bool
  description = "Enable deletion protection on RDS instance. Must be true for prod."
  default     = false
}

variable "skip_final_snapshot" {
  type        = bool
  description = "Skip final snapshot on destroy. Set to false for prod."
  default     = true
}

# modules/rds/main.tf
deletion_protection = var.deletion_protection
skip_final_snapshot = var.skip_final_snapshot
final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.project_name}-${var.environment}-final-snapshot"
```
In `environments/dev/terraform.tfvars`:
```hcl
# deletion_protection = false  (default, safe for dev)
```
For prod, set `deletion_protection = true` and `skip_final_snapshot = false`.

---

### M-09 | No ALB Deletion Protection
- **SEVERITY:** MEDIUM
- **FILE:** `modules/alb/main.tf` line 14
- **ISSUE:** `enable_deletion_protection = false` — same issue as RDS, no mechanism
  to enforce this for prod.
- **FIX:** Identical pattern — make it a variable:
```hcl
variable "enable_deletion_protection" {
  type    = bool
  default = false
  description = "Enable ALB deletion protection. Set to true for prod."
}
```

---

### M-10 | Two Duplicate Secret Versions Created (State Conflict Risk)
- **SEVERITY:** MEDIUM
- **FILE:** `modules/secrets/main.tf` lines 100–137
- **ISSUE:** Two `aws_secretsmanager_secret_version` resources exist for the same
  secret: `db` (without host) and `db_with_host` (with host). Both write to the
  same secret ID. On second apply, both versions exist in state but AWS only shows
  the latest — the `db` version without host becomes the AWSCURRENT shadow and
  Terraform state diverges from AWS reality.
- **WHY:** ECS reads `AWSCURRENT` from the secret. If Terraform applies `db` version
  last (due to resource ordering), the host field is empty and WordPress cannot
  connect to the database. This is also a Terraform anti-pattern — two resources
  managing the same AWS object.
- **FIX:** Use a single secret version that always includes all fields:
```hcl
resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    dbname   = var.db_name
    host     = var.db_host   # empty on first apply, populated on second
    port     = "3306"
  })

  lifecycle {
    # Prevent password rotation from causing a replacement
    ignore_changes = [secret_string]
  }
}
```
Remove the `aws_secretsmanager_secret_version.db` resource entirely.

---

### M-11 | Missing sensitive = true on secret_arn Output
- **SEVERITY:** MEDIUM
- **FILE:** `environments/dev/outputs.tf` lines 26–29
- **ISSUE:** `output "secret_arn"` exposes the full ARN of the Secrets Manager
  secret without `sensitive = true`. The ARN embeds the secret name (which includes
  environment and project name) and is logged in CI/CD output.
- **WHY:** While the ARN itself isn't the secret value, exposing it in CI logs
  allows attackers to know exactly which secret to target for an IAM privilege
  escalation attack.
- **FIX:**
```hcl
output "secret_arn" {
  description = "ARN of the Secrets Manager secret containing database credentials."
  value       = module.secrets.secret_arn
  sensitive   = true
}
```
Also add `sensitive = true` to `output "rds_endpoint"` — the DB hostname is
sensitive as it reveals internal network topology.

---

### M-12 | ECS Task Health Check Uses wp-login.php
- **SEVERITY:** MEDIUM
- **FILE:** `modules/ecs/main.tf` line 481
- **ISSUE:** `healthCheck.command = ["CMD-SHELL", "curl -f http://localhost/wp-login.php || exit 1"]`
  — `wp-login.php` is also the primary target for WordPress brute-force attacks.
  Using it as a health check endpoint means it's always accessible from within the
  container network.
- **WHY:** This is a minor exposure — `wp-login.php` should be rate-limited or
  replaced by a custom health endpoint. Also, the health check runs `curl` which
  may not be available in all WordPress Docker image variants.
- **FIX:** Use a lightweight custom health endpoint or the root path:
```hcl
healthCheck = {
  command     = ["CMD-SHELL", "curl -sf http://localhost/ -o /dev/null -w '%{http_code}' | grep -qE '(200|301|302)' || exit 1"]
  interval    = 30
  timeout     = 5
  retries     = 3
  startPeriod = 120
}
```

---

### M-13 | No Retention Policy on CloudWatch Log Group (RDS Logs)
- **SEVERITY:** MEDIUM
- **FILE:** `modules/rds/main.tf` — RDS CloudWatch log exports
- **ISSUE:** `enabled_cloudwatch_logs_exports = ["error", "slowquery"]` sends RDS
  logs to CloudWatch, but no `aws_cloudwatch_log_group` resource is created for
  these log groups, meaning they get AWS default retention (forever — infinite cost).
- **WHY:** RDS slowquery logs can be very verbose. With no retention, they accumulate
  indefinitely at $0.50/GB/month. For a busy WordPress site generating slowquery
  logs, this can become significant.
- **FIX:** Add to `modules/rds/main.tf`:
```hcl
locals {
  rds_log_groups = [
    "/aws/rds/instance/${var.project_name}-${var.environment}-mysql/error",
    "/aws/rds/instance/${var.project_name}-${var.environment}-mysql/slowquery"
  ]
}

resource "aws_cloudwatch_log_group" "rds" {
  count             = length(local.rds_log_groups)
  name              = local.rds_log_groups[count.index]
  retention_in_days = 30
  kms_key_id        = var.kms_key_arn

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}
```
