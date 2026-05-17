output "alb_sg_id" {
  description = "ID of the ALB security group."
  value       = aws_security_group.alb.id
}

output "ecs_instance_sg_id" {
  description = "ID of the ECS instance security group."
  value       = aws_security_group.ecs_instance.id
}

output "temporal_sg_id" {
  description = "ID of the Temporal Server security group."
  value       = aws_security_group.temporal.id
}

output "api_sg_id" {
  description = "ID of the API security group."
  value       = aws_security_group.api.id
}

output "worker_sg_id" {
  description = "ID of the Worker security group."
  value       = aws_security_group.worker.id
}

output "rds_sg_id" {
  description = "ID of the RDS security group."
  value       = aws_security_group.rds.id
}
