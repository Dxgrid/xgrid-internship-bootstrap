output "alb_sg_id" {
  description = "ALB security group ID."
  value       = aws_security_group.alb.id
}

output "ecs_sg_id" {
  description = "ECS security group ID."
  value       = aws_security_group.ecs.id
}

output "rds_sg_id" {
  description = "RDS security group ID."
  value       = aws_security_group.rds.id
}

output "efs_sg_id" {
  description = "EFS security group ID."
  value       = aws_security_group.efs.id
}
