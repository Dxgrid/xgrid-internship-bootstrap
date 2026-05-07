output "vpc_id" {
  description = "VPC ID for the dev environment."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs for the dev environment."
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs for the dev environment."
  value       = module.vpc.private_subnet_ids
}

output "rds_endpoint" {
  description = "RDS instance hostname. Used by ECS tasks to connect to database."
  value       = module.rds.rds_endpoint
}

output "rds_port" {
  description = "RDS instance port (MySQL default: 3306)."
  value       = module.rds.rds_port
}

output "rds_identifier" {
  description = "The database instance identifier used for AWS CLI and CloudWatch."
  value       = module.rds.rds_identifier
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret containing database credentials."
  value       = module.secrets.secret_arn
}

output "cluster_name" {
  description = "ECS cluster name for the dev environment."
  value       = module.ecs.cluster_name
}

output "cluster_arn" {
  description = "ECS cluster ARN for monitoring and IAM policies."
  value       = module.ecs.cluster_arn
}

output "service_name" {
  description = "ECS service name for the WordPress application."
  value       = module.ecs.service_name
}

output "task_definition_arn" {
  description = "ECS task definition ARN for WordPress tasks."
  value       = module.ecs.task_definition_arn
}

output "asg_name" {
  description = "Auto Scaling Group name for ECS instances. Used by Phase 7 ALB integration."
  value       = module.ecs.asg_name
}

output "log_group_name" {
  description = "CloudWatch log group name where WordPress container logs are written."
  value       = module.ecs.log_group_name
}

output "alb_dns_name" {
  description = "Paste this in your browser — WordPress will be live here"
  value       = module.alb.alb_dns_name
}

output "target_group_arn" {
  description = "Wire this into module.ecs target_group_arn input"
  value       = module.alb.target_group_arn
}

output "dashboard_url" {
  description = "Direct link to open the CloudWatch dashboard"
  value       = module.monitoring.dashboard_url
}

output "sns_topic_arn" {
  description = "SNS topic ARN for alarm notifications"
  value       = module.monitoring.sns_topic_arn
}
