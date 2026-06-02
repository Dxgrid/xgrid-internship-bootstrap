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

variable "vpc_id" {
  description = "VPC ID — reserved for future use (e.g. service discovery or security group lookups)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the Prometheus ECS service. Must not be public-facing."
  type        = list(string)
}

variable "monitoring_sg_id" {
  description = "Security group ID attached to the Prometheus ECS task (from security_groups module)."
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name — embedded in Prometheus external_labels and used as an ECS SD filter."
  type        = string
}

variable "cluster_arn" {
  description = "ECS cluster ARN — used as the cluster target for the Prometheus ECS service."
  type        = string
}

variable "aws_region" {
  description = "AWS region for ec2_sd_configs, ecs_sd_configs, and CloudWatch log groups."
  type        = string
  default     = "us-east-1"
}

variable "sns_topic_arn" {
  description = "SNS topic ARN the SNS bridge publishes AlertManager alerts to."
  type        = string
}

variable "cloudmap_namespace_arn" {
  description = "Cloud Map private DNS namespace ARN — used for Prometheus Cloud Map service registration."
  type        = string
}

variable "cloudmap_namespace_name" {
  description = "Cloud Map namespace DNS name (e.g. flask-sre-ecs-dev) — used to build the Prometheus Cloud Map service DNS name."
  type        = string
}

variable "demo_app_dns_name" {
  description = "Cloud Map MULTIVALUE DNS name for demo-app tasks (e.g. demo-app-metrics.flask-sre-ecs-dev). Prometheus resolves this to all running task IPs."
  type        = string
}

variable "efs_id" {
  description = "EFS file system ID for the Prometheus TSDB data volume."
  type        = string
}

variable "prometheus_access_point_id" {
  description = "EFS access point ID scoped to /prometheus (UID 65534) for TSDB persistence."
  type        = string
}

