variable "project_name" {
  description = "Project name used for resource naming and tagging."
  type        = string
}

variable "environment" {
  description = "Deployment environment name (dev, staging, prod)."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the monitoring EC2 will be deployed."
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs. The monitoring EC2 is placed in the first subnet."
  type        = list(string)
}

variable "monitoring_sg_id" {
  description = "Security group ID for the monitoring EC2 (from security_groups module)."
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name used in the Node Exporter discovery script and Prometheus labels."
  type        = string
}

variable "cluster_arn" {
  description = "ECS cluster ARN used for IAM policy scoping."
  type        = string
}

variable "grafana_target_group_arn" {
  description = "ARN of the Grafana ALB target group to register this EC2 instance against."
  type        = string
}

variable "grafana_admin_password" {
  description = "Admin password for the Grafana web UI."
  type        = string
  sensitive   = true
}

variable "aws_region" {
  description = "AWS region for CloudWatch datasource and API calls."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type for the monitoring server."
  type        = string
  default     = "t2.micro"
}

variable "rds_identifier" {
  description = "RDS instance identifier used in the daily reliability report cron command."
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix used in the daily reliability report cron command."
  type        = string
}

variable "tg_arn_suffix" {
  description = "Target group ARN suffix used in the daily reliability report cron command."
  type        = string
}

variable "sns_topic_arn" {
  description = "SNS topic ARN for publishing daily reliability reports."
  type        = string
}
