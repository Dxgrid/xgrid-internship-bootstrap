data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  project_name       = var.project_name
  environment        = var.environment
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "vpc" {
  source = "../../modules/vpc"

  project_name         = local.project_name
  environment          = local.environment
  vpc_cidr             = "10.0.0.0/16"
  public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs = ["10.0.3.0/24", "10.0.4.0/24"]
  availability_zones   = local.availability_zones
}

module "security_groups" {
  source = "../../modules/security_groups"

  project_name = local.project_name
  environment  = local.environment
  vpc_id       = module.vpc.vpc_id
}

module "secrets" {
  source = "../../modules/secrets"

  project_name           = local.project_name
  environment            = local.environment
  db_host                = module.rds.rds_endpoint
  secret_recovery_window = 0 # dev only — allows destroy+apply cycles without 7-day block
}

module "efs" {
  source = "../../modules/efs"

  project_name       = local.project_name
  environment        = local.environment
  private_subnet_ids = module.vpc.private_subnet_ids
  efs_sg_id          = module.security_groups.efs_sg_id
  kms_key_arn        = module.secrets.kms_key_arn
  ecs_task_role_arn  = module.ecs.ecs_task_role_arn # NEW: for EFS resource policy ALLOW
}

module "rds" {
  source = "../../modules/rds"

  project_name        = local.project_name
  environment         = local.environment
  private_subnet_ids  = module.vpc.private_subnet_ids
  rds_sg_id           = module.security_groups.rds_sg_id
  db_name             = module.secrets.db_name
  db_username         = module.secrets.db_username
  db_password         = module.secrets.db_password
  kms_key_arn         = module.secrets.kms_key_arn
  sns_topic_arn       = module.monitoring.sns_topic_arn
  deletion_protection = false # dev only — set true for staging/prod
}

module "alb" {
  source = "../../modules/alb"

  project_name         = local.project_name
  environment          = local.environment
  vpc_id               = module.vpc.vpc_id
  public_subnet_ids    = module.vpc.public_subnet_ids
  alb_sg_id            = module.security_groups.alb_sg_id
  sns_topic_arn        = module.monitoring.sns_topic_arn
  health_check_path    = var.health_check_path
  health_check_matcher = var.health_check_matcher
  idle_timeout         = var.idle_timeout
}

module "ecs" {
  source = "../../modules/ecs"

  project_name                    = local.project_name
  environment                     = local.environment
  vpc_id                          = module.vpc.vpc_id
  private_subnet_ids              = module.vpc.private_subnet_ids
  ecs_sg_id                       = module.security_groups.ecs_sg_id
  secret_arn                      = module.secrets.secret_arn
  kms_key_arn                     = module.secrets.kms_key_arn
  efs_id                          = module.efs.efs_id
  access_point_id                 = module.efs.access_point_id
  efs_arn                         = module.efs.efs_arn          # NEW: for scoped task role IAM policy
  access_point_arn                = module.efs.access_point_arn # NEW: for IAM condition
  target_group_arn                = module.alb.target_group_arn
  desired_count                   = var.desired_count
  min_instances                   = var.min_instances
  max_instances                   = var.max_instances
  managed_scaling_target_capacity = var.managed_scaling_target_capacity

  depends_on = [module.secrets]
}

module "monitoring" {
  source = "../../modules/monitoring"

  project_name                   = local.project_name
  environment                    = local.environment
  alert_email                    = var.alert_email
  manage_email_subscription      = var.manage_email_subscription
  cluster_name                   = module.ecs.cluster_name
  service_name                   = module.ecs.service_name
  rds_identifier                 = module.rds.rds_identifier
  alb_arn_suffix                 = module.alb.alb_arn_suffix
  tg_arn_suffix                  = module.alb.target_group_arn_suffix
  alb_unhealthy_hosts_alarm_name = module.alb.unhealthy_hosts_alarm_name
  aws_region                     = var.aws_region
}

module "prometheus" {
  source = "../../modules/prometheus"

  project_name             = local.project_name
  environment              = local.environment
  vpc_id                   = module.vpc.vpc_id
  public_subnet_ids        = module.vpc.public_subnet_ids
  monitoring_sg_id         = module.security_groups.monitoring_ec2_sg_id
  cluster_name             = module.ecs.cluster_name
  cluster_arn              = module.ecs.cluster_arn
  grafana_target_group_arn = module.alb.grafana_target_group_arn
  grafana_admin_password   = var.grafana_admin_password
  aws_region               = var.aws_region
  rds_identifier           = module.rds.rds_identifier
  alb_arn_suffix           = module.alb.alb_arn_suffix
  tg_arn_suffix            = module.alb.target_group_arn_suffix
  sns_topic_arn            = module.monitoring.sns_topic_arn

  depends_on = [module.ecs, module.alb]
}

module "grafana" {
  source = "../../modules/grafana"

  project_name          = local.project_name
  environment           = local.environment
  grafana_tg_arn_suffix = module.alb.grafana_tg_arn_suffix
  alb_arn_suffix        = module.alb.alb_arn_suffix
  sns_topic_arn         = module.monitoring.sns_topic_arn
  aws_region            = var.aws_region
}

