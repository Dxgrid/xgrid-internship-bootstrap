variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, prod, etc.)"
  type        = string
}

variable "alert_email" {
  description = "Email address to receive CloudWatch alarm notifications"
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name"
  type        = string
}

variable "service_name" {
  description = "ECS service name"
  type        = string
}

variable "rds_identifier" {
  description = "RDS instance identifier"
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix for CloudWatch dimensions"
  type        = string
}

variable "tg_arn_suffix" {
  description = "Target Group ARN suffix for CloudWatch dimensions"
  type        = string
}

variable "alb_unhealthy_hosts_alarm_name" {
  description = "Name of the unhealthy hosts alarm from the ALB module"
  type        = string
}

variable "manage_email_subscription" {
  description = "Whether Terraform should manage the SNS email subscription. Once confirmed, set to false to prevent re-creation on re-applies."
  type        = bool
  default     = true
}

variable "aws_region" {
  description = "AWS region for CloudWatch dashboard links and metric configuration."
  type        = string
  default     = "us-east-1"
}
