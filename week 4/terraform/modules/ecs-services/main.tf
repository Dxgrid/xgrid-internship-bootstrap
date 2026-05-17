# ECS Task Definitions and Services for Temporal Order Management
# 1. Temporal Server — Workflow engine backed by PostgreSQL
# 2. Temporal UI — Web console for workflow monitoring
# 3. API — FastAPI Order Management service
# 4. Worker — Temporal Worker for executing workflow code

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ─── CLOUDWATCH LOG GROUPS ────────────────────────────────────────────────────
# Explicit log groups with retention — must exist before tasks start

resource "aws_cloudwatch_log_group" "schema_bootstrap" {
  name              = "/ecs/${var.project_name}/${var.environment}/schema-bootstrap"
  retention_in_days = 7
  tags = { Project = var.project_name, Environment = var.environment }
}

resource "aws_cloudwatch_log_group" "temporal_server" {
  name              = "/ecs/${var.project_name}/${var.environment}/temporal-server"
  retention_in_days = 7
  tags = { Project = var.project_name, Environment = var.environment }
}

resource "aws_cloudwatch_log_group" "temporal_ui" {
  name              = "/ecs/${var.project_name}/${var.environment}/temporal-ui"
  retention_in_days = 7
  tags = { Project = var.project_name, Environment = var.environment }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.project_name}/${var.environment}/api"
  retention_in_days = 7
  tags = { Project = var.project_name, Environment = var.environment }
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${var.project_name}/${var.environment}/worker"
  retention_in_days = 7
  tags = { Project = var.project_name, Environment = var.environment }
}

# ─── SCHEMA BOOTSTRAP TASK (one-shot, runs before temporal-server) ───────────
# Uses temporalio/admin-tools which has psql. Creates both databases via psql
# with sslmode=require — bypassing temporal-sql-tool's TLS bug for CREATE DATABASE.

resource "aws_ecs_task_definition" "schema_bootstrap" {
  family                   = "${var.project_name}-schema-bootstrap"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name      = "schema-bootstrap"
    image     = "postgres:15"
    memory    = 256
    cpu       = 128
    essential = true

    entryPoint = ["sh", "-c"]
    command    = ["echo 'Testing connection...' && PGPASSWORD=\"$POSTGRES_PWD\" psql \"host=$POSTGRES_SEEDS port=5432 user=$POSTGRES_USER dbname=postgres sslmode=require\" -c 'SELECT 1' 2>&1 && echo 'Connection OK' && PGPASSWORD=\"$POSTGRES_PWD\" psql \"host=$POSTGRES_SEEDS port=5432 user=$POSTGRES_USER dbname=postgres sslmode=require\" -c 'CREATE DATABASE temporal;' 2>&1 || true && PGPASSWORD=\"$POSTGRES_PWD\" psql \"host=$POSTGRES_SEEDS port=5432 user=$POSTGRES_USER dbname=postgres sslmode=require\" -c 'CREATE DATABASE temporal_visibility;' 2>&1 || true && echo 'Database bootstrap complete.'"]

    environment = [
      { name = "POSTGRES_USER",  value = var.db_username },
      { name = "POSTGRES_SEEDS", value = var.rds_endpoint }
    ]

    secrets = [{ name = "POSTGRES_PWD", valueFrom = "${var.db_secret_arn}:password::" }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.schema_bootstrap.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  depends_on = [aws_cloudwatch_log_group.schema_bootstrap]
}

resource "null_resource" "temporal_schema_bootstrap" {
  triggers = {
    rds_endpoint = var.rds_endpoint
    task_def_arn = aws_ecs_task_definition.schema_bootstrap.arn
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      REGION="${var.aws_region}"
      CLUSTER="${var.ecs_cluster_id}"
      TASK_DEF="${aws_ecs_task_definition.schema_bootstrap.arn}"

      echo "Waiting for ECS container instance to be available..."
      until aws ecs list-container-instances \
        --cluster "$CLUSTER" --status ACTIVE --region "$REGION" \
        --query 'containerInstanceArns' --output text | grep -q arn; do
        echo "  No instances yet, waiting 15s..."
        sleep 15
      done

      echo "Running schema bootstrap task..."
      TASK_ARN=$(aws ecs run-task \
        --cluster "$CLUSTER" \
        --task-definition "$TASK_DEF" \
        --count 1 --launch-type EC2 --region "$REGION" \
        --query 'tasks[0].taskArn' --output text)

      echo "  Task ARN: $TASK_ARN"
      aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK_ARN" --region "$REGION"

      EXIT_CODE=$(aws ecs describe-tasks \
        --cluster "$CLUSTER" --tasks "$TASK_ARN" --region "$REGION" \
        --query 'tasks[0].containers[0].exitCode' --output text)

      if [ "$EXIT_CODE" = "0" ] || [ "$EXIT_CODE" = "None" ]; then
        echo "Schema bootstrap completed successfully."
      else
        echo "Schema bootstrap FAILED with exit code: $EXIT_CODE"
        exit 1
      fi
    EOT
  }

  depends_on = [aws_ecs_task_definition.schema_bootstrap]
}

# ─── TEMPORAL SERVER TASK DEFINITION ─────────────────────────────────────────
# TEMPORAL_BROADCAST_ADDRESS must be set dynamically so Temporal Server
# can advertise its own EC2 host IP to clients (API and Worker).
# hostPort is FIXED at 7233 — required for NLB instance target type.

resource "aws_ecs_task_definition" "temporal_server" {
  family                   = "${var.project_name}-temporal-server"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name      = "temporal-server"
    image     = "temporalio/auto-setup:latest"
    memory    = 512
    cpu       = 256
    essential = true

    portMappings = [
      {
        containerPort = var.temporal_grpc_port
        hostPort      = var.temporal_grpc_port
        protocol      = "tcp"
      }
    ]

    environment = [
      { name = "DB",                                          value = "postgres12" },
      { name = "DB_PORT",                                     value = "5432" },
      { name = "POSTGRES_USER",                               value = var.db_username },
      { name = "POSTGRES_SEEDS",                              value = var.rds_endpoint },
      { name = "SKIP_DB_CREATE",                              value = "true" },
      { name = "BIND_ON_IP",                                  value = "0.0.0.0" },
      { name = "TEMPORAL_BROADCAST_ADDRESS",                  value = "127.0.0.1" },
      { name = "TEMPORAL_METRICS_PROMETHEUS_FRAMEWORK_VALUE", value = "1" },
      { name = "POSTGRES_TLS_ENABLED",                        value = "true" },
      { name = "POSTGRES_TLS_DISABLE_HOST_VERIFICATION",      value = "true" },
      { name = "SQL_TLS_ENABLED",                             value = "true" },
      { name = "SQL_HOST_VERIFICATION",                       value = "false" }
    ]

    secrets = [
      {
        name      = "POSTGRES_PWD"
        valueFrom = "${var.db_secret_arn}:password::"
      }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.temporal_server.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = {
    Name        = "${var.project_name}-temporal-server-taskdef"
    Environment = var.environment
  }

  depends_on = [aws_cloudwatch_log_group.temporal_server]
}

resource "aws_ecs_service" "temporal_server" {
  name            = "${var.project_name}-temporal-server"
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.temporal_server.arn
  desired_count   = 1
  launch_type     = "EC2"

  load_balancer {
    target_group_arn = var.temporal_grpc_target_group_arn
    container_name   = "temporal-server"
    container_port   = var.temporal_grpc_port
  }

  tags = {
    Name        = "${var.project_name}-temporal-server"
    Environment = var.environment
  }

  depends_on = [null_resource.temporal_schema_bootstrap]
}

# ─── TEMPORAL UI TASK DEFINITION ──────────────────────────────────────────────
# hostPort = 0 (dynamic) — ALB instance target type handles port mapping

resource "aws_ecs_task_definition" "temporal_ui" {
  family                   = "${var.project_name}-temporal-ui"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name      = "temporal-ui"
    image     = "temporalio/ui:latest"
    memory    = 256
    cpu       = 128
    essential = true

    portMappings = [{
      containerPort = var.temporal_ui_container_port
      hostPort      = 0
      protocol      = "tcp"
    }]

    environment = [
      { name = "TEMPORAL_ADDRESS",         value = var.temporal_server_address },
      { name = "TEMPORAL_UI_PORT",         value = tostring(var.temporal_ui_container_port) },
      { name = "TEMPORAL_OPENAPI_ENABLED", value = "true" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.temporal_ui.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = {
    Name        = "${var.project_name}-temporal-ui-taskdef"
    Environment = var.environment
  }

  depends_on = [aws_cloudwatch_log_group.temporal_ui]
}

resource "aws_ecs_service" "temporal_ui" {
  name            = "${var.project_name}-temporal-ui"
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.temporal_ui.arn
  desired_count   = 1
  launch_type     = "EC2"

  load_balancer {
    target_group_arn = var.temporal_ui_target_group_arn
    container_name   = "temporal-ui"
    container_port   = var.temporal_ui_container_port
  }

  tags = {
    Name        = "${var.project_name}-temporal-ui"
    Environment = var.environment
  }

  depends_on = [aws_ecs_service.temporal_server]
}

# ─── API TASK DEFINITION ─────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.project_name}-api"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name      = "api"
    image     = "${var.api_ecr_repository_url}:latest"
    memory    = 256
    cpu       = 256
    essential = true

    portMappings = [{
      containerPort = var.api_container_port
      hostPort      = 0
      protocol      = "tcp"
    }]

    environment = [
      { name = "TEMPORAL_ADDRESS",    value = var.temporal_server_address },
      { name = "TEMPORAL_NAMESPACE",  value = "default" },
      { name = "TEMPORAL_TASK_QUEUE", value = "order-task-queue" },
      { name = "PORT",                value = tostring(var.api_container_port) }
    ]

    healthCheck = {
      command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:${var.api_container_port}/health')\" || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 15
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.api.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = {
    Name        = "${var.project_name}-api-taskdef"
    Environment = var.environment
  }

  depends_on = [aws_cloudwatch_log_group.api]
}

resource "aws_ecs_service" "api" {
  name            = "${var.project_name}-api"
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.desired_api_count
  launch_type     = "EC2"

  load_balancer {
    target_group_arn = var.api_target_group_arn
    container_name   = "api"
    container_port   = var.api_container_port
  }

  tags = {
    Name        = "${var.project_name}-api"
    Environment = var.environment
  }

  depends_on = [aws_ecs_service.temporal_server]
}

# ─── WORKER TASK DEFINITION ───────────────────────────────────────────────────

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.project_name}-worker"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name      = "worker"
    image     = "${var.worker_ecr_repository_url}:latest"
    memory    = 512
    cpu       = 256
    essential = true

    environment = [
      { name = "TEMPORAL_ADDRESS",    value = var.temporal_server_address },
      { name = "TEMPORAL_NAMESPACE",  value = "default" },
      { name = "TEMPORAL_TASK_QUEUE", value = "order-task-queue" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.worker.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = {
    Name        = "${var.project_name}-worker-taskdef"
    Environment = var.environment
  }

  depends_on = [aws_cloudwatch_log_group.worker]
}

resource "aws_ecs_service" "worker" {
  name            = "${var.project_name}-worker"
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.desired_worker_count
  launch_type     = "EC2"

  tags = {
    Name        = "${var.project_name}-worker"
    Environment = var.environment
  }

  depends_on = [aws_ecs_service.temporal_server]
}
