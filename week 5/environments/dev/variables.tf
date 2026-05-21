variable "project_name" {
  description = "Project name used for resource tags and naming."
  type        = string
  default     = "wordpress-ecs-ha"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region for the deployment."
  type        = string
  default     = "us-east-1"
}

variable "owner_name" {
  description = "Owner tag value for resources."
  type        = string
  default     = "your-name"
}

variable "alert_email" {
  description = "Email address to receive CloudWatch alarm notifications"
  type        = string
}

variable "manage_email_subscription" {
  description = "Whether Terraform should manage the SNS email subscription. Set to false after email confirmation to prevent auto-deletion."
  type        = bool
  default     = true
}

variable "desired_count" {
  description = "Number of WordPress tasks to run (Scaling Simulation)"
  type        = number
  default     = 2
}

variable "min_instances" {
  description = "Minimum number of EC2 instances in the cluster"
  type        = number
  default     = 1
}

variable "max_instances" {
  description = "Maximum number of EC2 instances in the cluster"
  type        = number
  default     = 2
}

variable "managed_scaling_target_capacity" {
  description = "The target capacity utilization for managed scaling (1-100)."
  type        = number
  default     = 85
}

variable "health_check_path" {
  description = "The destination for health check requests."
  type        = string
  default     = "/"
}

variable "health_check_matcher" {
  description = "The HTTP codes to use when checking for a successful response from a target."
  type        = string
  default     = "200,302"
}

variable "idle_timeout" {
  description = "The time in seconds that the connection is allowed to be idle."
  type        = number
  default     = 60
}

variable "grafana_admin_password" {
  description = "Admin password for the Grafana web UI. Required — set in terraform.tfvars (not committed to git)."
  type        = string
  sensitive   = true
}
