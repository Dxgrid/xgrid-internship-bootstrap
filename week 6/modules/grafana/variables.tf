variable "project_name" {
  description = "Project name used for resource naming and tagging."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, or prod)."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the Grafana ECS service."
  type        = list(string)
}

variable "monitoring_sg_id" {
  description = "Security group ID attached to the Grafana ECS task."
  type        = string
}

variable "cluster_arn" {
  description = "ECS cluster ARN."
  type        = string
}

variable "grafana_target_group_arn" {
  description = "ALB target group ARN (target_type=ip) for Grafana."
  type        = string
}

variable "grafana_admin_password" {
  description = "Grafana admin UI password. Set in terraform.tfvars — never commit to git."
  type        = string
  sensitive   = true
}

variable "rds_endpoint" {
  description = "RDS instance hostname (address only, no port). Used as GF_DATABASE_HOST."
  type        = string
}

variable "db_master_username" {
  description = "RDS master username — used once by the db_init provisioner to create the grafana user."
  type        = string
}

variable "db_master_password" {
  description = "RDS master password — used once by the db_init provisioner to create the grafana user."
  type        = string
  sensitive   = true
}

variable "aws_region" {
  description = "AWS region for CloudWatch log group and SSM commands."
  type        = string
  default     = "us-east-1"
}

variable "cloudmap_namespace_name" {
  description = "Cloud Map namespace DNS name (e.g. flask-sre-ecs-dev) — used to build the Prometheus FQDN: http://prometheus.<namespace>:9090."
  type        = string
}

variable "grafana_tg_arn_suffix" {
  description = "Grafana ALB target group ARN suffix for CloudWatch alarm dimensions."
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix for CloudWatch alarm dimensions."
  type        = string
}

variable "sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarm notifications. Pass empty string to disable."
  type        = string
  default     = ""
}
