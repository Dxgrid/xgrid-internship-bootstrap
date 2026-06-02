locals {
  default_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  datasource_yml = <<-YAML
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        uid: PBFA97CFB590B2093
        url: ${local.effective_prometheus_url}
        isDefault: true
        editable: true

      - name: CloudWatch
        type: cloudwatch
        uid: P034F075C744B399F
        jsonData:
          defaultRegion: ${var.aws_region}
          authType: default
        editable: true
  YAML

  # Prometheus registers its task IP in Cloud Map under prometheus.<namespace>.
  # The VPC private hosted zone resolves this FQDN automatically when the task
  # restarts — no hardcoded IPs, no Service Connect proxy required.
  effective_prometheus_url = "http://prometheus.${var.cloudmap_namespace_name}:9090"
  provision_cmd            = "mkdir -p /etc/grafana/provisioning/datasources && printf '%s' '${base64encode(local.datasource_yml)}' | base64 -d > /etc/grafana/provisioning/datasources/prometheus.yml && "
}

# Grafana-specific database password — no special characters so the SSM shell
# command used to CREATE USER does not require complex escaping.
resource "random_password" "grafana_db" {
  length  = 24
  special = false
}

# ── IAM: Grafana ECS task role ────────────────────────────────────────────────

resource "aws_iam_role" "grafana_task" {
  name_prefix = "${var.project_name}-${var.environment}-grafana-task-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-grafana-task-role"
  })
}

resource "aws_iam_policy" "grafana_task" {
  name_prefix = "${var.project_name}-${var.environment}-grafana-task-"
  description = "Allows Grafana ECS task to read CloudWatch metrics and ECS alarms."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarms"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:GetLogGroupFields",
          "logs:StartQuery",
          "logs:StopQuery",
          "logs:GetQueryResults",
          "logs:GetLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "grafana_task" {
  role       = aws_iam_role.grafana_task.name
  policy_arn = aws_iam_policy.grafana_task.arn
}

# ── IAM: ECS execution role (image pull + CloudWatch Logs) ───────────────────

resource "aws_iam_role" "grafana_execution" {
  name_prefix = "${var.project_name}-${var.environment}-grafana-exec-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-grafana-exec-role"
  })
}

resource "aws_iam_role_policy_attachment" "grafana_execution" {
  role       = aws_iam_role.grafana_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}


# ── CloudWatch log group ──────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "grafana" {
  name              = "/ecs/${var.project_name}/${var.environment}/grafana"
  retention_in_days = 7

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-grafana-logs"
  })
}

# ── Database initialisation ───────────────────────────────────────────────────
# Runs once via SSM on an ECS EC2 instance (which is in the same VPC as RDS).
# Creates the `grafana` database and a dedicated grafana user with full access.
# Runs automatically on first apply and re-runs only if rds_endpoint changes.

resource "null_resource" "grafana_db_init" {
  triggers = {
    rds_endpoint = var.rds_endpoint
  }

  provisioner "local-exec" {
    environment = {
      TF_REGION   = var.aws_region
      TF_PROJECT  = var.project_name
      TF_ENV      = var.environment
      TF_RDS_HOST = var.rds_endpoint
      TF_DB_USER  = var.db_master_username
      TF_DB_PASS  = var.db_master_password
      TF_GF_PASS  = random_password.grafana_db.result
    }
    command = "python3 ${path.module}/db_init.py"
  }
}

# ── ECS task definition ───────────────────────────────────────────────────────
# Grafana is fully stateless — all state lives in RDS MySQL.
# No EFS volume, no filesystem dependency, no chmod issues.

resource "aws_ecs_task_definition" "grafana" {
  family                   = "${var.project_name}-${var.environment}-grafana"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  task_role_arn            = aws_iam_role.grafana_task.arn
  execution_role_arn       = aws_iam_role.grafana_execution.arn

  container_definitions = jsonencode([
    {
      name      = "grafana"
      image     = "grafana/grafana:10.4.2"
      essential = true

      portMappings = [{ containerPort = 3000, protocol = "tcp" }]

      entryPoint = ["sh", "-c"]
      command    = ["${local.provision_cmd}/run.sh"]

      environment = [
        { name = "GF_SECURITY_ADMIN_USER",        value = "admin" },
        { name = "GF_SECURITY_ADMIN_PASSWORD",     value = var.grafana_admin_password },
        { name = "GF_SERVER_ROOT_URL",             value = "%(protocol)s://%(domain)s/grafana" },
        { name = "GF_SERVER_SERVE_FROM_SUB_PATH",  value = "true" },
        { name = "GF_USERS_ALLOW_SIGN_UP",         value = "false" },
        { name = "GF_AUTH_ANONYMOUS_ENABLED",      value = "false" },
        { name = "GF_INSTALL_PLUGINS",             value = "grafana-piechart-panel" },
        { name = "GF_DATABASE_TYPE",               value = "mysql" },
        { name = "GF_DATABASE_HOST",               value = "${var.rds_endpoint}:3306" },
        { name = "GF_DATABASE_NAME",               value = "grafana" },
        { name = "GF_DATABASE_USER",               value = "grafana" },
        { name = "GF_DATABASE_PASSWORD",           value = random_password.grafana_db.result }
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "wget -qO- http://localhost:3000/api/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }

      memory            = 256
      memoryReservation = 128

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.grafana.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "grafana"
        }
      }
    }
  ])

  depends_on = [null_resource.grafana_db_init]

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-grafana-task"
  })
}

# ── ECS Service ───────────────────────────────────────────────────────────────
# REPLICA desired_count=1. With RDS as the backend this can safely scale to
# multiple replicas in the future without any SQLite corruption risk.

resource "aws_ecs_service" "grafana" {
  name            = "${var.project_name}-${var.environment}-grafana-svc"
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.grafana.arn
  desired_count   = 1
  launch_type     = "EC2"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.monitoring_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.grafana_target_group_arn
    container_name   = "grafana"
    container_port   = 3000
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  enable_execute_command = false

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-grafana-svc"
  })
}

# ── CloudWatch alarm ──────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "grafana_unhealthy" {
  alarm_name          = "${var.project_name}-${var.environment}-grafana-unhealthy"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "Grafana ECS task is failing ALB health checks — monitoring UI unreachable."
  treat_missing_data  = "breaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.grafana_tg_arn_suffix
  }

  alarm_actions             = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  ok_actions                = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  insufficient_data_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
}
