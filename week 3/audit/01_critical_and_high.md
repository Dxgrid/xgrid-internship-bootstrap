# PRODUCTION-READINESS AUDIT — CRITICAL & HIGH SEVERITY
## Project: WordPress ECS HA | Auditor: Senior SRE | Date: 2026-05-06

---

## EXECUTIVE SUMMARY

The codebase demonstrates solid foundational intent — IAM roles are split correctly,
EFS uses TLS enforcement, secrets are injected via Secrets Manager, and the module
structure is clean. However, **five critical security flaws** make this codebase
unsafe for any production use today. The most dangerous is an overly-broad KMS key
policy that grants `kms:*` to any AWS principal via the root account while also
granting crypto operations to `Principal: "*"` on EFS/Secrets Manager statements —
combined with the absence of VPC endpoints, this means KMS traffic travels over the
public internet through a NAT Gateway. Secondary concerns include hardcoded values
across multiple files, silent CloudWatch alarms in the RDS/ALB modules, a single
NAT Gateway creating an AZ-level SPOF, and a nearly empty README. Overall the code
is good for a learning exercise but requires significant hardening before production.

---

## CATEGORY 1 — CRITICAL ISSUES

---

### C-01 | KMS Key Policy: Principal "*" on Crypto Operations
- **SEVERITY:** CRITICAL
- **FILE:** `modules/secrets/main.tf` lines 30–70
- **ISSUE:** Both the `AllowEFSEncryption` and `AllowSecretsManagerEncryption`
  statements use `Principal: { AWS: "*" }`. This means ANY AWS principal in ANY
  account can call `kms:Encrypt`, `kms:Decrypt`, etc. on your CMK, as long as they
  can pass the `kms:ViaService` condition. The condition only validates the service
  name, not the caller's identity.
- **WHY:** An attacker who compromises any AWS account (even free-tier) could
  potentially decrypt your database credentials and EFS data by routing requests
  through the correct AWS service endpoint. This is a textbook privilege escalation
  path in shared environments.
- **FIX:**
```hcl
# modules/secrets/main.tf — replace both AWS: "*" statements

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_kms_key" "secrets" {
  description             = "CMK for ${var.project_name}-${var.environment}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootAccountFullAdmin"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowEFSEncryption"
        Effect = "Allow"
        Principal = {
          # Scope to account — NOT "*"
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
          "kms:GenerateDataKey*", "kms:CreateGrant", "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService"    = "elasticfilesystem.${data.aws_region.current.name}.amazonaws.com"
            "kms:CallerAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AllowSecretsManagerEncryption"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
          "kms:GenerateDataKey*", "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService"    = "secretsmanager.${data.aws_region.current.name}.amazonaws.com"
            "kms:CallerAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}
```

---

### C-02 | No VPC Endpoints for Secrets Manager or ECR
- **SEVERITY:** CRITICAL
- **FILE:** `modules/vpc/main.tf` (missing resources)
- **ISSUE:** There are no `aws_vpc_endpoint` resources for `secretsmanager`,
  `ecr.api`, `ecr.dkr`, `s3`, `logs`, or `kms`. All traffic from private subnets
  to these services exits via the single NAT Gateway over the public internet.
- **WHY (Security):** Secrets Manager traffic (containing DB passwords) and ECR
  image pulls travel over the public internet. A network-level attacker or
  misconfigured route could intercept this traffic.
- **WHY (Cost):** Each GB through NAT Gateway costs $0.045. ECR image pulls for
  `wordpress:6.5-apache` (~150MB) on every task start/replacement, multiplied by
  ECS scaling events, generates non-trivial NAT costs that VPC endpoints eliminate.
- **FIX:** Add to `modules/vpc/main.tf`:
```hcl
# Interface endpoint for Secrets Manager
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [var.vpc_endpoint_sg_id]
  private_dns_enabled = true

  tags = { Name = "${var.project_name}-${var.environment}-secretsmanager-ep" }
}

# Interface endpoint for ECR API
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [var.vpc_endpoint_sg_id]
  private_dns_enabled = true

  tags = { Name = "${var.project_name}-${var.environment}-ecr-api-ep" }
}

# Interface endpoint for ECR Docker registry
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [var.vpc_endpoint_sg_id]
  private_dns_enabled = true

  tags = { Name = "${var.project_name}-${var.environment}-ecr-dkr-ep" }
}

# Gateway endpoint for S3 (ECR layers are stored in S3 — free)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.project_name}-${var.environment}-s3-ep" }
}

# Interface endpoint for CloudWatch Logs
resource "aws_vpc_endpoint" "logs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [var.vpc_endpoint_sg_id]
  private_dns_enabled = true

  tags = { Name = "${var.project_name}-${var.environment}-logs-ep" }
}

# Interface endpoint for KMS
resource "aws_vpc_endpoint" "kms" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.kms"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [var.vpc_endpoint_sg_id]
  private_dns_enabled = true

  tags = { Name = "${var.project_name}-${var.environment}-kms-ep" }
}
```
Also add a security group for VPC endpoints (allow HTTPS 443 from VPC CIDR).

---

### C-03 | RDS & ALB CloudWatch Alarms Have Empty alarm_actions
- **SEVERITY:** CRITICAL
- **FILE:** `modules/rds/main.tf` lines 198, 224, 250 | `modules/alb/main.tf` lines 140, 165
- **ISSUE:** All RDS alarms (`rds_cpu`, `rds_storage`, `rds_connections`) and ALB
  alarms (`alb_5xx`, `alb_unhealthy_hosts`) have `alarm_actions = []`. They are
  completely silent. RDS running out of disk (20GB max) would not alert anyone.
- **WHY:** Silent alarms are worse than no alarms — they create a false sense of
  security. A full RDS disk causes all writes to fail, taking WordPress down.
- **FIX:** Pass the SNS topic ARN from the monitoring module into both rds and alb
  modules. In `environments/dev/main.tf`:
```hcl
# The monitoring module must be created first, or use a separate SNS module.
# Better architecture: create SNS topic in a shared/monitoring module and
# pass its ARN to rds and alb modules.

module "rds" {
  source           = "../../modules/rds"
  # ... existing vars ...
  sns_topic_arn    = module.monitoring.sns_topic_arn  # ADD THIS
}

module "alb" {
  source        = "../../modules/alb"
  # ... existing vars ...
  sns_topic_arn = module.monitoring.sns_topic_arn  # ADD THIS
}
```
In `modules/rds/variables.tf` add:
```hcl
variable "sns_topic_arn" {
  type        = string
  description = "SNS topic ARN for CloudWatch alarm notifications."
  default     = ""
}
```
In `modules/rds/main.tf` replace `alarm_actions = []` with:
```hcl
alarm_actions             = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
insufficient_data_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
```
Apply same pattern to `modules/alb/main.tf`.

---

### C-04 | terraform.tfvars Gitignored but Contains Alert Email
- **SEVERITY:** CRITICAL (repo hygiene / secret exposure risk)
- **FILE:** `.gitignore` line 3 | `environments/dev/terraform.tfvars`
- **ISSUE:** `.gitignore` has `*.tfvars` which means `terraform.tfvars` is not
  committed — but `terraform.tfvars` contains the `alert_email` which is not a
  secret. More dangerously, the current `.gitignore` pattern `*.tfvars` would also
  gitignore `terraform.tfvars.example`, preventing the example file from being
  tracked. No `terraform.tfvars.example` file exists at all.
- **WHY:** Without a committed example file, new team members have no idea what
  values to provide. If someone adds a real secret (DB password) to tfvars, the
  blanket `*.tfvars` rule provides safety — but the lack of example is a gap.
- **FIX:**
```gitignore
# .gitignore — replace *.tfvars with targeted rule
*.tfstate
*.tfstate.backup
*.tfvars
!*.tfvars.example   # allow example files to be committed
.terraform/
crash.log
tfplan
tfpan
*.log
```
Create `environments/dev/terraform.tfvars.example`:
```hcl
aws_region   = "us-east-1"
environment  = "dev"
project_name = "wordpress-ecs-ha"
owner_name   = "your-name"
alert_email  = "your-email@example.com"
```

---

### C-05 | tfplan and Log Files Committed / Not Gitignored
- **SEVERITY:** CRITICAL (secret exposure)
- **FILE:** `environments/dev/` — `tfplan`, `tfpan`, `rds_apply_output.log`, `rds_deploy.log`
- **ISSUE:** Binary tfplan files (80KB, 65KB) and log files are present in the
  repo directory and not gitignored. Terraform plan files contain the **full
  plaintext state** of resources including secrets, passwords, and ARNs.
- **WHY:** Anyone with read access to the repository gets all secret values that
  were known at plan time. This is a critical secret leak vector.
- **FIX:** Add to `.gitignore`:
```
tfplan
tfpan
*.tfplan
*.log
.terraform/
```
Then immediately rotate any credentials that appeared in those plan files.

---

## CATEGORY 2 — HIGH SEVERITY ISSUES

---

### H-01 | Single NAT Gateway — AZ-Level SPOF
- **SEVERITY:** HIGH
- **FILE:** `modules/vpc/main.tf` lines 52–73
- **ISSUE:** Only one `aws_eip.nat` and one `aws_nat_gateway.main` are created,
  pinned to `aws_subnet.public[0]`. All private subnet traffic (both AZs) routes
  through this single NAT Gateway in AZ-1.
- **WHY:** If AZ-1 fails (AWS AZ outage), the NAT Gateway is unavailable. ECS tasks
  in AZ-2 lose internet connectivity — they cannot pull from ECR, reach Secrets
  Manager, or send CloudWatch logs. This defeats the entire purpose of multi-AZ.
- **FIX:**
```hcl
# modules/vpc/main.tf — replace single NAT with one per AZ

resource "aws_eip" "nat" {
  count  = length(var.public_subnet_cidrs)
  domain = "vpc"

  tags = {
    Name        = "${var.project_name}-${var.environment}-nat-eip-${count.index + 1}"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_nat_gateway" "main" {
  count         = length(var.public_subnet_cidrs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name        = "${var.project_name}-${var.environment}-nat-${count.index + 1}"
    Project     = var.project_name
    Environment = var.environment
  }

  depends_on = [aws_internet_gateway.main]
}

# One private route table per AZ pointing to its own NAT Gateway
resource "aws_route_table" "private" {
  count  = length(var.private_subnet_cidrs)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-private-rt-${count.index + 1}"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
```
> **Note for dev:** Single NAT is acceptable for dev to save cost (~$32/month per NAT).
> Flag this explicitly with a variable `single_nat_gateway = true` for dev, false for prod.

---

### H-02 | Hardcoded Instance Type in Launch Template
- **SEVERITY:** HIGH
- **FILE:** `modules/ecs/main.tf` line 261
- **ISSUE:** `instance_type = "t2.micro"` is hardcoded. t2.micro is also not the
  recommended type — t3.micro is the current-gen equivalent with better networking.
- **WHY:** Hardcoded instance types cannot be overridden per environment. Prod needs
  a larger instance. Also t2 uses credit-based CPU bursting with a smaller baseline
  than t3, risking CPU throttling under WordPress load.
- **FIX:**
```hcl
# modules/ecs/variables.tf — add:
variable "instance_type" {
  type        = string
  description = "EC2 instance type for ECS container instances."
  default     = "t3.micro"
  validation {
    condition     = contains(["t3.micro", "t3.small", "t3.medium", "t3.large", "m5.large"], var.instance_type)
    error_message = "instance_type must be one of: t3.micro, t3.small, t3.medium, t3.large, m5.large."
  }
}

# modules/ecs/main.tf line 261 — replace:
instance_type = var.instance_type
```

---

### H-03 | Hardcoded CIDR Blocks in Main — DRY Violation
- **SEVERITY:** HIGH
- **FILE:** `environments/dev/main.tf` lines 16–18
- **ISSUE:** `vpc_cidr = "10.0.0.0/16"`, `public_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]`,
  `private_subnet_cidrs = ["10.0.3.0/24", "10.0.4.0/24"]` are hardcoded literals
  in main.tf rather than driven by variables or locals.
- **WHY:** If you need to deploy a second environment (staging) with a different
  CIDR to avoid VPC peering conflicts, you must edit main.tf — you cannot simply
  change tfvars. This breaks environment parity.
- **FIX:** Add to `environments/dev/variables.tf`:
```hcl
variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC."
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for public subnets."
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for private subnets."
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}
```
Then in `main.tf` reference `var.vpc_cidr`, `var.public_subnet_cidrs`, etc.

---

### H-04 | Hardcoded Region String in CloudWatch Dashboard
- **SEVERITY:** HIGH
- **FILE:** `modules/monitoring/main.tf` lines 143, 159, 175, 193, 209, 225, 242, 258, 274
- **ISSUE:** `region = "us-east-1"` is hardcoded 9 times inside the dashboard JSON.
  Also hardcoded in `modules/monitoring/outputs.tf` line 8.
- **WHY:** If the stack is ever deployed to eu-west-1 or any other region, all 9
  dashboard widgets will silently query the wrong region — they will appear empty
  without any error.
- **FIX:**
```hcl
# modules/monitoring/variables.tf — add:
variable "aws_region" {
  type        = string
  description = "AWS region for CloudWatch dashboard widget references."
}

# modules/monitoring/main.tf — in locals block add:
locals {
  region = var.aws_region
}
# Replace all "us-east-1" strings with local.region

# modules/monitoring/outputs.tf line 8 — replace:
value = "https://console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.wordpress.dashboard_name}"

# environments/dev/main.tf — pass region:
module "monitoring" {
  source     = "../../modules/monitoring"
  aws_region = var.aws_region
  # ... rest of vars
}
```

---

### H-05 | recovery_window_in_days = 0 on Secrets Manager Secret
- **SEVERITY:** HIGH
- **FILE:** `modules/secrets/main.tf` line 89
- **ISSUE:** `recovery_window_in_days = 0` means the secret is **immediately and
  permanently deleted** with no recovery window. This is the `--force-delete-without-recovery` equivalent.
- **WHY:** If `terraform destroy` is run by accident (or a junior engineer runs it
  in the wrong environment), the DB credentials are gone instantly with no 7–30 day
  recovery window. RDS is also deleted (skip_final_snapshot=true), making this a
  complete unrecoverable data loss scenario.
- **FIX:**
```hcl
resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.project_name}/${var.environment}/db-credentials"
  description             = "WordPress database credentials"
  kms_key_id              = aws_kms_key.secrets.id
  recovery_window_in_days = 7  # 7-day safety window; use 0 only for dev automation

  tags = { ... }
}
```
If fast teardown is needed in dev, make it a variable:
```hcl
variable "secret_recovery_window" {
  type    = number
  default = 7
  description = "Days to retain deleted secret. Use 0 for dev fast-teardown only."
}
```

---

### H-06 | No validation on environment Variable
- **SEVERITY:** HIGH
- **FILE:** `environments/dev/variables.tf` line 7–11 | all module `variables.tf` files
- **ISSUE:** `variable "environment"` has no `validation` block in any file. A typo
  like `"prod "` (trailing space) or `"production"` would silently create resources
  with wrong names in wrong environments.
- **WHY:** If environment="prod" is accidentally used in dev configuration, resources
  get tagged as prod and may bypass protection policies, or prod resources may be
  confused with dev ones in billing and monitoring.
- **FIX:** Add to `environments/dev/variables.tf` AND all module `variables.tf`:
```hcl
variable "environment" {
  type        = string
  description = "Deployment environment. Must be dev, staging, or prod."
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}
```

---

### H-07 | RDS max_allocated_storage = 20 Disables Autoscaling
- **SEVERITY:** HIGH
- **FILE:** `modules/rds/main.tf` line 134
- **ISSUE:** `max_allocated_storage = 20` is identical to `allocated_storage = 20`.
  When both are the same value, RDS autoscaling is effectively disabled — storage
  can never grow.
- **WHY:** WordPress media uploads accumulate over time. A 20GB disk will fill up.
  When RDS storage is full, ALL database writes fail — WordPress cannot save posts,
  update options, or handle sessions. The `rds_storage` alarm fires at 2GB free,
  which gives some warning, but if left unattended it causes a full outage.
- **FIX:**
```hcl
allocated_storage     = 20
max_allocated_storage = 100  # Allow autoscaling up to 100GB
storage_type          = "gp3" # Also upgrade from gp2 to gp3 — same cost, better performance
```

---

### H-08 | WordPress Docker Image Tag Not Pinned to Digest
- **SEVERITY:** HIGH
- **FILE:** `modules/ecs/main.tf` line 416
- **ISSUE:** `image = "wordpress:6.5-apache"` uses a mutable tag. Docker Hub can
  push a new image to the `6.5-apache` tag at any time without changing the tag name.
- **WHY:** If Docker Hub pushes a broken or compromised image to `6.5-apache`, your
  next ECS task replacement silently pulls and runs the bad image. No Terraform
  change is required for this to happen — it occurs on any ECS task restart.
- **FIX:** Pin to an immutable digest:
```hcl
# Get digest with: docker inspect --format='{{index .RepoDigests 0}}' wordpress:6.5-apache
image = "wordpress:6.5-apache@sha256:DIGEST_HERE"

# Better: Push to your own ECR and reference that:
image = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com/wordpress:6.5-apache"
```

---

### H-09 | SNS Topic Not Encrypted with CMK
- **SEVERITY:** HIGH
- **FILE:** `modules/monitoring/main.tf` lines 10–18
- **ISSUE:** `aws_sns_topic.wordpress_alerts` has no `kms_master_key_id`. SNS
  messages are stored unencrypted at rest.
- **WHY:** SNS notifications contain alarm details including metric values and
  resource identifiers. Encrypting them is a compliance requirement (PCI-DSS,
  HIPAA) and a security best practice.
- **FIX:**
```hcl
resource "aws_sns_topic" "wordpress_alerts" {
  name              = "${var.project_name}-${var.environment}-alerts"
  kms_master_key_id = var.kms_key_arn  # pass CMK ARN from secrets module

  tags = {
    Name        = "${var.project_name}-${var.environment}-alerts"
    Project     = var.project_name
    Environment = var.environment
  }
}
```
