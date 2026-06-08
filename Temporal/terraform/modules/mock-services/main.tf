# Dependency mock services the Temporal worker calls over HTTP from its activities
# (fraud, inventory, payment, shipping, notification). Each is an identical FastAPI
# app on :8000, deployed as its own awsvpc ECS service and registered in Cloud Map
# so the worker resolves <name>.<namespace>:8000.
#
# Deployed as separate services (not worker sidecars) per Temporal KB guidance:
# co-locating other apps with workers couples their release cycle and contends for
# worker resources. See community.temporal.io/t/2635.

locals {
  default_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  # service short name → activity env var that must point at it
  services = {
    fraud        = "FRAUD_SERVICE_URL"
    inventory    = "INVENTORY_SERVICE_URL"
    payment      = "PAYMENT_SERVICE_URL"
    shipping     = "SHIPPING_SERVICE_URL"
    notification = "NOTIFICATION_SERVICE_URL"
  }
}

resource "aws_cloudwatch_log_group" "service" {
  for_each = local.services

  name              = "/ecs/${var.project_name}/${var.environment}/${each.key}"
  retention_in_days = 7
  tags              = local.default_tags
}

resource "aws_ecs_task_definition" "service" {
  for_each = local.services

  family                   = "${var.project_name}-${var.environment}-${each.key}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = var.execution_role_arn

  container_definitions = jsonencode([{
    name      = each.key
    image     = "${var.services_ecr_repository_url}:${each.key}"
    memory    = 128
    cpu       = 64
    essential = true

    portMappings = [{
      containerPort = var.container_port
      protocol      = "tcp"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.service[each.key].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-${each.key}-task"
  })
}

# Cloud Map A record per service: <name>.<namespace> resolves to the task IP(s).
resource "aws_service_discovery_service" "service" {
  for_each = local.services

  name = each.key

  dns_config {
    namespace_id   = var.cloudmap_namespace_id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-${each.key}-sd"
  })
}

resource "aws_ecs_service" "service" {
  for_each = local.services

  name            = "${var.project_name}-${var.environment}-${each.key}"
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.service[each.key].arn
  desired_count   = 1
  launch_type     = "EC2"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.services_sg_id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.service[each.key].arn
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-${each.key}"
  })
}
