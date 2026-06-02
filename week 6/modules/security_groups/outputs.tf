output "alb_sg_id" {
  description = "ALB security group ID — passed to the ALB module and used as the source for ECS and monitoring ingress rules."
  value       = aws_security_group.alb.id
}

output "ecs_sg_id" {
  description = "ECS security group ID — attached to EC2 instances and awsvpc tasks in the ECS cluster."
  value       = aws_security_group.ecs.id
}

output "rds_sg_id" {
  description = "RDS security group ID — restricts database access to ECS tasks only."
  value       = aws_security_group.rds.id
}

output "efs_sg_id" {
  description = "EFS security group ID — attached to EFS mount targets, allows NFS from ECS and monitoring tasks."
  value       = aws_security_group.efs.id
}

output "monitoring_sg_id" {
  description = "Monitoring security group ID — attached to Prometheus and Grafana ECS tasks (awsvpc)."
  value       = aws_security_group.monitoring.id
}
