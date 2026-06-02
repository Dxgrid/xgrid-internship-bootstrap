data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  default_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  # Use caller-supplied image if provided; otherwise default to the ECR repo
  # created by this module so the task definition is always valid after the
  # repo exists. The image must be pushed before ECS can start tasks.
  app_image = var.app_image != "" ? var.app_image : "${aws_ecr_repository.demo_app.repository_url}:latest"
}

# ── CloudWatch log groups ─────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "demo_app" {
  name              = "/ecs/${var.project_name}/${var.environment}/demo-app"
  retention_in_days = 7

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-demo-app-logs"
  })
}

# Separate log group for the Node Exporter Daemon Service so its output
# does not pollute the application log stream.
resource "aws_cloudwatch_log_group" "node_exporter" {
  name              = "/ecs/${var.project_name}/${var.environment}/node-exporter"
  retention_in_days = 7

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-node-exporter-logs"
  })
}

# ── ECR repository ────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "demo_app" {
  name                 = "${var.project_name}-${var.environment}-demo-app"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-demo-app"
  })
}

# Keep only the 5 most recent images to avoid unbounded storage growth on a
# dev repository where images are pushed frequently.
resource "aws_ecr_lifecycle_policy" "demo_app" {
  repository = aws_ecr_repository.demo_app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Retain 5 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# ── IAM — EC2 instance role ───────────────────────────────────────────────────
# Assumed by the EC2 host itself (not the container) for ECS agent registration.

resource "aws_iam_role" "ecs_instance_role" {
  name_prefix = "${var.project_name}-${var.environment}-ecs-instance-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEC2AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-ecs-instance-role"
  })
}

resource "aws_iam_role_policy_attachment" "ecs_instance_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "ecs_instance_ssm_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  name_prefix = "${var.project_name}-${var.environment}-ecs-instance-"
  role        = aws_iam_role.ecs_instance_role.name

  lifecycle {
    create_before_destroy = true
  }
}

# ── IAM — task execution role ─────────────────────────────────────────────────
# Used by the ECS agent before container start to pull images and push logs.
# AmazonECSTaskExecutionRolePolicy already covers ECR pull and CloudWatch Logs.

resource "aws_iam_role" "ecs_task_execution" {
  name_prefix = "${var.project_name}-${var.environment}-ecs-exec-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowECSTaskExecution"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-ecs-exec-role"
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ── IAM — task role ───────────────────────────────────────────────────────────
# Assumed by the demo-app container at runtime. The app makes no AWS API calls,
# so no policies are attached — this role exists as a least-privilege placeholder
# that can have permissions added without changing the task definition.

resource "aws_iam_role" "ecs_task_role" {
  name_prefix = "${var.project_name}-${var.environment}-ecs-task-"
  description = "Runtime role for the demo-app container. No AWS permissions required."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowECSTaskAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-ecs-task-role"
  })
}

# ── ECS cluster ───────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-${var.environment}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-cluster"
  })
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.ec2.name]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 1
    capacity_provider = aws_ecs_capacity_provider.ec2.name
  }

  depends_on = [aws_ecs_capacity_provider.ec2]
}

# ── EC2 launch template ───────────────────────────────────────────────────────
# Node Exporter has been removed from user_data — it now runs as an ECS
# Daemon Service so ECS manages its lifecycle (health checks, restarts,
# log routing) rather than an unmonitored docker run call.

resource "aws_launch_template" "ecs_instance" {
  name_prefix   = "${var.project_name}-${var.environment}-ecs-lt-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = "t3.small"

  iam_instance_profile {
    arn = aws_iam_instance_profile.ecs_instance.arn
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    # --no-block prevents systemctl from stalling cloud-init on first boot.
    mkdir -p /etc/ecs
    echo ECS_CLUSTER=${aws_ecs_cluster.main.name} > /etc/ecs/ecs.config
    echo ECS_ENABLE_TASK_IAM_ROLE=true >> /etc/ecs/ecs.config
    echo ECS_ENABLE_AWSLOGS_EXECUTIONROLE_OVERRIDE=true >> /etc/ecs/ecs.config
    systemctl restart ecs --no-block
    EOF
  )

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [var.ecs_sg_id]
    delete_on_termination       = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.default_tags, {
      Name = "${var.project_name}-${var.environment}-ecs-instance"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Auto Scaling Group ────────────────────────────────────────────────────────

resource "aws_autoscaling_group" "ecs" {
  name_prefix = "${var.project_name}-${var.environment}-ecs-asg-"

  min_size            = var.min_instances
  max_size            = var.max_instances
  desired_capacity    = var.desired_count
  vpc_zone_identifier = var.private_subnet_ids

  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.ecs_instance.id
    version = "$Latest"
  }

  protect_from_scale_in = true

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = var.project_name
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }

  tag {
    key                 = "ManagedBy"
    value               = "Terraform"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── ECS capacity provider ─────────────────────────────────────────────────────

resource "aws_ecs_capacity_provider" "ec2" {
  name = "${var.project_name}-${var.environment}-ec2-cp"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs.arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = var.managed_scaling_target_capacity
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 2
    }
  }
}

# ── Demo app task definition ──────────────────────────────────────────────────
# Single container serving HTTP on :80 (homepage, /health, /metrics).
# No EFS volume and no Secrets Manager injection — the app is stateless.

resource "aws_ecs_task_definition" "demo_app" {
  family                   = "${var.project_name}-${var.environment}-demo-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([
    {
      name      = "demo-app"
      image     = local.app_image
      essential = true
      cpu       = 256
      memory    = 512

      portMappings = [
        {
          containerPort = 80
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "ENVIRONMENT"
          value = var.environment
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.demo_app.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "demo-app"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-demo-app-task"
  })

  depends_on = [
    aws_iam_role_policy_attachment.ecs_task_execution_policy,
    aws_cloudwatch_log_group.demo_app,
  ]
}

# ── Demo app ECS service ──────────────────────────────────────────────────────

resource "aws_ecs_service" "demo_app" {
  name            = "${var.project_name}-${var.environment}-demo-app-svc"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.demo_app.arn
  desired_count   = var.desired_count

  health_check_grace_period_seconds = 60

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2.name
    weight            = 1
    base              = 1
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_sg_id]
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = var.target_group_arn != "" ? [1] : []
    content {
      target_group_arn = var.target_group_arn
      container_name   = "demo-app"
      container_port   = 80
    }
  }

  # Registers every task's private IP as an A record under demo-app-metrics.<namespace>.
  # With MULTIVALUE routing, Prometheus dns_sd_configs gets all task IPs at once.
  service_registries {
    registry_arn = aws_service_discovery_service.demo_app_metrics.arn
  }

  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  enable_execute_command = false

  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_ecs_cluster_capacity_providers.main,
    aws_iam_role_policy_attachment.ecs_task_execution_policy,
    aws_cloudwatch_log_group.demo_app,
  ]

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-demo-app-svc"
  })
}

# ── Node Exporter task definition (Daemon) ────────────────────────────────────
# host + pid namespace required so node_exporter sees the EC2's /proc, /sys,
# and filesystem rather than the container's isolated view.
# No task role: node_exporter makes no AWS API calls.

resource "aws_ecs_task_definition" "node_exporter" {
  family                   = "${var.project_name}-${var.environment}-node-exporter"
  requires_compatibilities = ["EC2"]
  network_mode             = "host"
  pid_mode                 = "host"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  volume {
    name      = "proc"
    host_path = "/proc"
  }

  volume {
    name      = "sys"
    host_path = "/sys"
  }

  volume {
    name      = "rootfs"
    host_path = "/"
  }

  container_definitions = jsonencode([
    {
      name      = "node-exporter"
      image     = "quay.io/prometheus/node-exporter:v1.8.1"
      essential = true
      cpu       = 128
      memory    = 128

      portMappings = [
        {
          hostPort      = 9100
          containerPort = 9100
          protocol      = "tcp"
        }
      ]

      mountPoints = [
        { sourceVolume = "proc",   containerPath = "/host/proc",  readOnly = true },
        { sourceVolume = "sys",    containerPath = "/host/sys",   readOnly = true },
        { sourceVolume = "rootfs", containerPath = "/rootfs",     readOnly = true }
      ]

      command = [
        "--path.procfs=/host/proc",
        "--path.sysfs=/host/sys",
        "--path.rootfs=/rootfs",
        "--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/docker/.+)($|/)",
        "--web.listen-address=:9100"
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.node_exporter.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "node-exporter"
        }
      }
    }
  ])

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-node-exporter-task"
  })

  depends_on = [aws_cloudwatch_log_group.node_exporter]
}

# ── Cloud Map private DNS namespace ──────────────────────────────────────────
# Shared by:
#   1. Service Connect (Prometheus server + Grafana client) — stable hostname
#   2. MULTIVALUE service registry (demo-app) — all task IPs returned at once

resource "aws_service_discovery_private_dns_namespace" "cluster" {
  name        = "${var.project_name}-${var.environment}"
  description = "Private DNS namespace for ECS Service Connect and Prometheus service discovery."
  vpc         = var.vpc_id

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-cloudmap-ns"
  })
}

# MULTIVALUE routing returns ALL registered task A records simultaneously.
# Prometheus dns_sd_configs queries this name and gets one scrape target per
# running demo-app task — no manual IP tracking, no static_configs to update.
resource "aws_service_discovery_service" "demo_app_metrics" {
  name = "demo-app-metrics"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.cluster.id
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
    Name = "${var.project_name}-${var.environment}-demo-app-metrics-sd"
  })
}

# ── Node Exporter Daemon Service ──────────────────────────────────────────────
# DAEMON scheduling places exactly one task per active EC2 instance in the
# cluster — including any new instance added by the ASG. ECS manages the full
# lifecycle (start, stop, health checks, log routing) instead of a bare
# docker run in user_data.
# deployment_minimum_healthy_percent = 0 is required: ECS must stop the running
# daemon task before starting the replacement (only one task fits per host).

resource "aws_ecs_service" "node_exporter" {
  name                               = "${var.project_name}-${var.environment}-node-exporter-svc"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.node_exporter.arn
  scheduling_strategy                = "DAEMON"
  launch_type                        = "EC2"
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_ecs_cluster_capacity_providers.main]

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-node-exporter-svc"
  })
}
