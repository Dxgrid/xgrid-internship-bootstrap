variable "project_name" {
  type        = string
  description = "Project name — used for resource naming and tagging."
}

variable "environment" {
  type        = string
  description = "Environment — dev, staging, prod. Used for naming and tagging."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where ECS will be deployed (from module.vpc.vpc_id)."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for EC2 instances and ECS tasks (from module.vpc.private_subnet_ids)."
}

variable "ecs_sg_id" {
  type        = string
  description = "Security group ID for ECS — allows port 80 from ALB only (from module.security_groups.ecs_sg_id)."
}

variable "secret_arn" {
  type        = string
  description = "ARN of Secrets Manager secret containing DB credentials (from module.secrets.secret_arn). Used by task execution role to inject environment variables."
}

variable "kms_key_arn" {
  type        = string
  description = "ARN of KMS CMK for Secrets Manager decryption (from module.secrets.kms_key_arn). Task execution role uses this to decrypt the secret."
}

variable "efs_id" {
  type        = string
  description = "EFS file system ID for WordPress content (from module.efs.efs_id)."
}

variable "access_point_id" {
  type        = string
  description = "EFS access point ID (from module.efs.access_point_id). Tasks mount EFS through this access point for isolation."
}

variable "efs_arn" {
  type        = string
  description = "EFS file system ARN (from module.efs.efs_arn). Used to scope task role IAM policy for EFS access."
}

variable "access_point_arn" {
  type        = string
  description = "EFS access point ARN (from module.efs.access_point_arn). Used in IAM condition to restrict ECS task role to this access point only."
}

variable "target_group_arn" {
  type        = string
  default     = ""
  description = "ALB target group ARN — wired after Phase 7 ALB is deployed. Empty string means no ALB (service still deploys)."
}

variable "desired_count" {
  type        = number
  description = "Number of tasks to run in the ECS service."
  default     = 2
}

variable "min_instances" {
  type        = number
  description = "Minimum number of EC2 instances in the ASG."
  default     = 1
}

variable "max_instances" {
  type        = number
  description = "Maximum number of EC2 instances in the ASG."
  default     = 2
}

variable "managed_scaling_target_capacity" {
  type        = number
  description = "The target capacity utilization for managed scaling (1-100)."
  default     = 85
}
