variable "project_name" {
  description = "Project name used in resource names and tags."
  type        = string
}

variable "environment" {
  description = "Environment name used in resource tags."
  type        = string
}

variable "aws_region" {
  description = "AWS region (used by Prometheus ec2_sd and the SNS bridge)."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for EFS mount targets."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for monitoring tasks and EFS mount targets."
  type        = list(string)
}

variable "cluster_id" {
  description = "ECS cluster ID where monitoring services run."
  type        = string
}

variable "cluster_arn" {
  description = "ECS cluster ARN."
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name."
  type        = string
}

variable "monitoring_sg_id" {
  description = "Security group ID for Prometheus and Grafana awsvpc tasks."
  type        = string
}

variable "efs_sg_id" {
  description = "Security group ID for EFS mount targets."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN used to encrypt the EFS file system."
  type        = string
}

variable "execution_role_arn" {
  description = "Shared ECS execution role ARN (ECR pull, CloudWatch Logs, Secrets Manager + KMS for the DB password)."
  type        = string
}

variable "db_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the RDS master password (reused by Grafana)."
  type        = string
}

variable "db_username" {
  description = "RDS master username Grafana uses to connect to its backend database."
  type        = string
}

variable "rds_endpoint" {
  description = "RDS endpoint (host without port) for the Grafana backend database."
  type        = string
}

variable "cloudmap_namespace_id" {
  description = "Cloud Map private DNS namespace ID (Prometheus registers itself here)."
  type        = string
}

variable "cloudmap_namespace_name" {
  description = "Cloud Map private DNS namespace name, e.g. temporal-order-dev.local (used to build the Prometheus FQDN for Grafana)."
  type        = string
}

variable "worker_metrics_dns_name" {
  description = "FQDN registered by the worker service in Cloud Map (worker-metrics.<namespace>); Prometheus scrapes :9090 here."
  type        = string
}

variable "sns_topic_arn" {
  description = "SNS topic ARN the AlertManager bridge publishes Prometheus alerts to."
  type        = string
}

variable "grafana_target_group_arn" {
  description = "ALB target group ARN Grafana registers with (port 3000)."
  type        = string
}

variable "grafana_admin_password" {
  description = "Initial Grafana admin password."
  type        = string
  sensitive   = true
}

variable "temporal_server_metrics_port" {
  description = "Host port exposing Temporal Server Prometheus metrics."
  type        = number
  default     = 8001
}

variable "worker_metrics_port" {
  description = "Container port exposing Temporal Worker SDK Prometheus metrics."
  type        = number
  default     = 9090
}
