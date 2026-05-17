# Week 4 Temporal Order Management — Main Terraform
# Reuses Week 3 modules via relative paths + adds Temporal-specific resources

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  project_name       = var.project_name
  environment        = var.environment
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)
}

# Generate strong database password for use across RDS and Secrets Manager
resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

locals {
  db_password             = random_password.db.result
  # Direct EC2 IP bypasses the NLB hairpin issue: AWS NLBs (instance target type)
  # drop connections where client and target land on the same EC2 host. Worker and
  # UI containers run on the same instance as temporal-server, so the NLB hostname
  # causes i/o timeout. Using the private IP of the temporal-server EC2 directly.
  # NOTE: update this IP if temporal-server is rescheduled to a different EC2 host.
  temporal_server_address = "10.0.4.200:7233"
}
# ─── REUSE WEEK 3 MODULES VIA RELATIVE PATHS ─────────────────────────────

# VPC — Exact same as Week 3, just call the module
module "vpc" {
  source = "../../../../week 3/modules/vpc"

  project_name         = local.project_name
  environment          = local.environment
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = local.availability_zones
}

# ECS Cluster — EC2 capacity with instance role, ASG, and capacity provider
module "ecs_cluster" {
  source = "../../modules/ecs-cluster"

  project_name       = local.project_name
  environment        = local.environment
  cluster_name       = "${local.project_name}-${local.environment}"
  private_subnet_ids = module.vpc.private_subnet_ids
  ecs_sg_id          = module.security_groups.ecs_instance_sg_id

  depends_on = [module.vpc, module.security_groups]
}

# ─── NEW WEEK 4 MODULES ─────────────────────────────────────────────────────

# Security Groups — Extended to include Temporal, API, and Worker security groups
module "security_groups" {
  source = "../../modules/security-groups"

  project_name = local.project_name
  environment  = local.environment
  vpc_id    = module.vpc.vpc_id
  vpc_cidr  = var.vpc_cidr
}

# Internal NLB for Temporal gRPC — Layer 4 TCP passthrough avoids ALB 60s idle timeout
module "nlb_temporal" {
  source = "../../modules/nlb-temporal"

  project_name       = local.project_name
  environment        = local.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  depends_on = [module.vpc]
}

# ALB for Temporal UI and API — Separate from Week 3's WordPress ALB
module "alb_temporal" {
  source = "../../modules/alb-temporal"

  project_name      = local.project_name
  environment       = local.environment
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  alb_sg_id         = module.security_groups.alb_sg_id
}

# RDS PostgreSQL for Temporal — Separate database instance
module "rds_temporal" {
  source = "../../modules/rds-temporal"

  project_name       = local.project_name
  environment        = local.environment
  private_subnet_ids = module.vpc.private_subnet_ids
  rds_sg_id          = module.security_groups.rds_sg_id
  db_username        = var.db_username
  db_password        = local.db_password
}

# Secrets Manager — Store DB credentials securely (created after RDS endpoint known)
module "secrets" {
  source = "../../modules/secrets"

  project_name = local.project_name
  environment  = local.environment
  db_username  = var.db_username
  db_password  = local.db_password
  rds_endpoint = module.rds_temporal.rds_endpoint

  depends_on = [module.rds_temporal]
}
# ECR Repositories — For pushing API and Worker container images
module "ecr" {
  source = "../../modules/ecr"

  project_name       = local.project_name
  environment        = local.environment
  image_scan_enabled = var.ecr_image_scan
}

# IAM Roles — ECS execution and task roles
module "iam" {
  source = "../../modules/iam"

  db_secret_arn = module.secrets.secret_arn
  kms_key_arn   = module.secrets.kms_key_arn

  depends_on = [module.secrets]
  project_name = local.project_name
  environment  = local.environment
}

# ECS Services — Temporal Server, Temporal UI, API, and Worker task definitions
module "ecs_services" {
  source = "../../modules/ecs-services"

  project_name         = local.project_name
  environment          = local.environment
  ecs_cluster_id       = module.ecs_cluster.cluster_id
  ecs_cluster_name     = module.ecs_cluster.cluster_name
  vpc_id               = module.vpc.vpc_id
  private_subnet_ids   = module.vpc.private_subnet_ids
  aws_region           = var.aws_region

  # ECR Image URLs
  api_ecr_repository_url    = module.ecr.api_repository_url
  worker_ecr_repository_url = module.ecr.worker_repository_url

  # RDS Temporal Database
  rds_endpoint = module.rds_temporal.rds_endpoint
  db_username  = var.db_username
  db_secret_arn = module.secrets.secret_arn

  # ALB Target Groups
  api_target_group_arn       = module.alb_temporal.api_target_group_arn
  temporal_ui_target_group_arn = module.alb_temporal.temporal_ui_target_group_arn

  # Security Groups
  temporal_sg_id = module.security_groups.temporal_sg_id
  api_sg_id      = module.security_groups.api_sg_id
  worker_sg_id   = module.security_groups.worker_sg_id

  # IAM Roles
  execution_role_arn = module.iam.ecs_execution_role_arn
  task_role_arn      = module.iam.ecs_task_role_arn

  # NLB — Temporal gRPC target group (temporal server registers here)
  temporal_grpc_target_group_arn = module.nlb_temporal.temporal_grpc_target_group_arn

  # Container Configuration
  temporal_server_address    = local.temporal_server_address
  api_container_port         = var.api_container_port
  temporal_ui_container_port = var.temporal_ui_container_port
  temporal_grpc_port         = var.temporal_grpc_port
  desired_api_count          = var.desired_api_count
  desired_worker_count       = var.desired_worker_count

  depends_on = [module.secrets, module.iam]
}
