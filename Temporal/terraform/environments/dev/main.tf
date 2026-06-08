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
  db_password = random_password.db.result
  # Use NLB DNS name for TEMPORAL_ADDRESS. The hairpin issue (NLB dropping connections
  # where client and target are on the same EC2 host) is resolved by setting
  # TEMPORAL_BROADCAST_ADDRESS=127.0.0.1 in the temporal-server task definition,
  # which makes the server use loopback for internal Ringpop rather than the host IP.
  temporal_server_address = "${module.nlb_temporal.nlb_dns_name}:7233"
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

# ENI trunking — multiplexes many task ENIs onto one "trunk" ENI per instance, so a
# t3.large can run ~10+ awsvpc tasks instead of ~2. Required because the Temporal
# server moved to awsvpc (joining worker/mocks/prometheus/grafana), which would
# otherwise exhaust the per-instance ENI limit. Account/region-wide and idempotent.
# NOTE: a container instance only gets a trunk ENI when it REGISTERS after this is
# enabled — existing instances must be refreshed (rolled) once for it to take effect.
resource "aws_ecs_account_setting_default" "awsvpc_trunking" {
  name  = "awsvpcTrunking"
  value = "enabled"
}

# ECS Cluster — EC2 capacity with instance role, ASG, and capacity provider
module "ecs_cluster" {
  source = "../../modules/ecs-cluster"

  project_name       = local.project_name
  environment        = local.environment
  cluster_name       = "${local.project_name}-${local.environment}"
  private_subnet_ids = module.vpc.private_subnet_ids
  ecs_sg_id          = module.security_groups.ecs_instance_sg_id
  instance_type      = var.ecs_instance_type

  # Ensure trunking is enabled before instances register, so they attach a trunk ENI.
  depends_on = [module.vpc, module.security_groups, aws_ecs_account_setting_default.awsvpc_trunking]
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

# SNS topic for CloudWatch alarm notifications — all alarms route here
resource "aws_sns_topic" "alarms" {
  name = "${local.project_name}-${local.environment}-alarms"

  tags = {
    Name        = "${local.project_name}-${local.environment}-alarms"
    Environment = local.environment
  }
}

resource "aws_sns_topic_subscription" "alarms_email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ─── SERVICE DISCOVERY (Cloud Map) ───────────────────────────────────────────
# Private DNS namespace shared by the monitoring stack:
#   - worker-metrics.<ns> → MULTIVALUE A records, one per running worker task,
#     so Prometheus dns_sd_configs discovers every worker without hardcoded IPs.
#   - prometheus.<ns>     → registered inside the monitoring module so Grafana
#     resolves Prometheus across task restarts.
resource "aws_service_discovery_private_dns_namespace" "temporal" {
  name        = "${local.project_name}-${local.environment}.local"
  description = "Private DNS namespace for Prometheus service discovery of Temporal workers and Grafana → Prometheus."
  vpc         = module.vpc.vpc_id

  tags = {
    Name        = "${local.project_name}-${local.environment}-cloudmap-ns"
    Environment = local.environment
  }
}

# MULTIVALUE returns all registered worker task IPs at once. The Temporal worker
# ECS service registers each task here; Prometheus scrapes worker-metrics.<ns>:9090.
resource "aws_service_discovery_service" "worker_metrics" {
  name = "worker-metrics"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.temporal.id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = {
    Name        = "${local.project_name}-${local.environment}-worker-metrics-sd"
    Environment = local.environment
  }
}

# Cloud Map service for Temporal Server metrics (port 8001) — awsvpc task registration
resource "aws_service_discovery_service" "server_metrics" {
  name = "server-metrics"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.temporal.id
    routing_policy = "WEIGHTED"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = {
    Name        = "${local.project_name}-${local.environment}-server-metrics-sd"
    Environment = local.environment
  }
}

# ALB for Temporal UI and API — Separate from Week 3's WordPress ALB
module "alb_temporal" {
  source = "../../modules/alb-temporal"

  project_name        = local.project_name
  environment         = local.environment
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids
  alb_sg_id           = module.security_groups.alb_sg_id
  alarm_sns_topic_arn = aws_sns_topic.alarms.arn
}

# RDS PostgreSQL for Temporal — Separate database instance
module "rds_temporal" {
  source = "../../modules/rds-temporal"

  project_name        = local.project_name
  environment         = local.environment
  private_subnet_ids  = module.vpc.private_subnet_ids
  rds_sg_id           = module.security_groups.rds_sg_id
  db_username         = var.db_username
  db_password         = local.db_password
  alarm_sns_topic_arn = aws_sns_topic.alarms.arn
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

  # Cloud Map — worker (awsvpc) registers each task for Prometheus dns_sd discovery
  worker_service_registry_arn = aws_service_discovery_service.worker_metrics.arn

  # Cloud Map — server (awsvpc) registers for Prometheus dns_sd discovery on port 8001
  server_service_registry_arn = aws_service_discovery_service.server_metrics.arn

  # Dependency service URLs (fraud/inventory/payment/shipping/notification) → worker env
  worker_service_urls = module.mock_services.service_urls

  # Container Configuration
  temporal_server_address    = local.temporal_server_address
  api_container_port         = var.api_container_port
  temporal_ui_container_port = var.temporal_ui_container_port
  temporal_grpc_port         = var.temporal_grpc_port
  desired_api_count          = var.desired_api_count
  desired_worker_count       = var.desired_worker_count
  worker_min_capacity        = var.worker_min_capacity
  worker_max_capacity        = var.worker_max_capacity

  # DB bootstrap → temporal-server has its `temporal` DB before it starts.
  # Image build/push → api & worker tasks have images to pull.
  depends_on = [module.secrets, module.iam, null_resource.db_bootstrap, null_resource.image_build_push]
}

# Dependency mock services (fraud/inventory/payment/shipping/notification) the worker
# calls from its activities — separate awsvpc ECS services discovered via Cloud Map.
module "mock_services" {
  source = "../../modules/mock-services"

  project_name = local.project_name
  environment  = local.environment
  aws_region   = var.aws_region

  cluster_id         = module.ecs_cluster.cluster_id
  cluster_arn        = module.ecs_cluster.cluster_arn
  private_subnet_ids = module.vpc.private_subnet_ids
  services_sg_id     = module.security_groups.services_sg_id
  execution_role_arn = module.iam.ecs_execution_role_arn

  services_ecr_repository_url = module.ecr.services_repository_url

  cloudmap_namespace_id   = aws_service_discovery_private_dns_namespace.temporal.id
  cloudmap_namespace_name = aws_service_discovery_private_dns_namespace.temporal.name

  # Image build/push → mock-service tasks have images to pull.
  depends_on = [module.ecs_cluster, module.iam, null_resource.image_build_push]
}

# ─── PHASE 3: CENTRALIZED OBSERVABILITY ──────────────────────────────────────

# Grafana admin password — generated, no special chars to keep the URL/login simple.
resource "random_password" "grafana_admin" {
  length  = 20
  special = false
}

# Monitoring stack — Prometheus + AlertManager + SNS bridge, Node Exporter daemon,
# Grafana (PostgreSQL backend). Scrapes worker (Cloud Map), server (:8001), nodes (:9100).
module "monitoring" {
  source = "../../modules/monitoring"

  project_name = local.project_name
  environment  = local.environment
  aws_region   = var.aws_region

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  cluster_id   = module.ecs_cluster.cluster_id
  cluster_arn  = module.ecs_cluster.cluster_arn
  cluster_name = module.ecs_cluster.cluster_name

  monitoring_sg_id = module.security_groups.monitoring_sg_id
  efs_sg_id        = module.security_groups.efs_sg_id

  kms_key_arn        = module.secrets.kms_key_arn
  execution_role_arn = module.iam.ecs_execution_role_arn
  db_secret_arn      = module.secrets.secret_arn
  db_username        = var.db_username
  rds_endpoint       = module.rds_temporal.rds_endpoint

  cloudmap_namespace_id   = aws_service_discovery_private_dns_namespace.temporal.id
  cloudmap_namespace_name = aws_service_discovery_private_dns_namespace.temporal.name
  worker_metrics_dns_name = "worker-metrics.${aws_service_discovery_private_dns_namespace.temporal.name}"

  sns_topic_arn            = aws_sns_topic.alarms.arn
  grafana_target_group_arn = module.alb_temporal.grafana_target_group_arn
  grafana_admin_password   = random_password.grafana_admin.result

  # DB bootstrap → Grafana has its `grafana` DB before it starts.
  depends_on = [module.ecs_services, module.alb_temporal, null_resource.db_bootstrap]
}
