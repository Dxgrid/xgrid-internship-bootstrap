# ECS Task Definitions and Services for Temporal Order Management
# 1. Temporal Server — Workflow engine backed by PostgreSQL
# 2. Temporal UI — Web console for workflow monitoring
# 3. API — FastAPI Order Management service
# 4. Worker — Temporal Worker for executing workflow code

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ─── CLOUDWATCH LOG GROUPS ────────────────────────────────────────────────────
# Explicit log groups with retention — must exist before tasks start

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

# ─── TEMPORAL SERVER TASK DEFINITION ─────────────────────────────────────────
# TEMPORAL_BROADCAST_ADDRESS must be set dynamically so Temporal Server
# can advertise its own EC2 host IP to clients (API and Worker).
# awsvpc network mode: the task gets its own ENI and binds 7233/8001 directly on it.
# This avoids the bridge-mode published-port path (DNAT + host FORWARD chain), which
# was unreachable off-host here (FORWARD policy DROP) and made the NLB health check
# fail -> the server flapped. The NLB target group is target_type=ip -> the task ENI.

resource "aws_ecs_task_definition" "temporal_server" {
  family                   = "${var.project_name}-temporal-server"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name      = "temporal-server"
    # auto-setup image: does schema setup + namespace registration + server start in ONE
    # container with known-good defaults. Bring-up pivot (see plan) after the bare `server`
    # image crash-looped exit 1. Schema/migrations are idempotent against the existing RDS.
    image     = "temporalio/auto-setup:1.25.2"
    # auto-setup runs all 4 Temporal roles in one process — 1024 MB gives headroom
    # so it can't OOM-kill (exit 137) under load. Cluster RAM is ~87% free.
    memory    = 1024
    cpu       = 512
    essential = true

    # awsvpc: containerPort only (no hostPort). Both ports bind on the task ENI.
    portMappings = [
      { containerPort = var.temporal_grpc_port, protocol = "tcp" },
      # Server Prometheus metrics (PROMETHEUS_ENDPOINT=0.0.0.0:8001), on the task ENI.
      { containerPort = 8001, protocol = "tcp" }
    ]

    environment = [
      { name = "DB",                                     value = "postgres12" },
      { name = "DB_PORT",                                value = "5432" },
      { name = "POSTGRES_USER",                          value = var.db_username },
      { name = "POSTGRES_SEEDS",                         value = var.rds_endpoint },
      { name = "BIND_ON_IP",                             value = "0.0.0.0" },
      # No TEMPORAL_BROADCAST_ADDRESS under awsvpc — the server auto-detects its own
      # ENI IP for Ringpop. (127.0.0.1 was a bridge-mode hack and is wrong here.)
      { name = "SERVICES",                               value = "history,matching,frontend,worker" },
      # auto-setup: register the app's namespace inline (matches worker/API TEMPORAL_NAMESPACE).
      { name = "DEFAULT_NAMESPACE",                      value = "temporal-dev" },
      { name = "DEFAULT_NAMESPACE_RETENTION",            value = "720h" },
      # We register our own OrderStatus search attribute (see temporal_namespace_setup);
      # skip auto-setup's demo attributes.
      { name = "SKIP_ADD_CUSTOM_SEARCH_ATTRIBUTES",      value = "true" },
      # POSTGRES_TLS_* — used by the bootstrap/migration phase (temporal-sql-tool)
      { name = "POSTGRES_TLS_ENABLED",                   value = "true" },
      { name = "POSTGRES_TLS_DISABLE_HOST_VERIFICATION", value = "true" },
      # SQL_TLS_* — used by the server runtime after startup. These are a separate
      # config set that also applies to PostgreSQL despite the name suggesting MySQL only.
      # Without these, the server starts but immediately fails with:
      # "sql schema version compatibility check failed: no usable database connection found"
      { name = "SQL_TLS_ENABLED",                        value = "true" },
      { name = "SQL_HOST_VERIFICATION",                  value = "false" },
      # Port 8001 avoids collision with the API service on 8000 (both in bridge mode on same host)
      { name = "PROMETHEUS_ENDPOINT",                    value = "0.0.0.0:8001" }
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

  # The server needs ~60s to run its schema check and start serving gRPC on 7233.
  # Without a grace period ECS evaluates the NLB health check immediately, marks the
  # still-booting task unhealthy, and replaces it — an endless flap. 180s covers a
  # cold start comfortably.
  health_check_grace_period_seconds = 180

  # awsvpc: the task runs on its own ENI in the private subnets, guarded by the
  # temporal SG (allows 7233 from the VPC for NLB health checks + clients, 8001 from
  # monitoring). distinctInstance is gone — it only existed for the 127.0.0.1 hack.
  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.temporal_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.temporal_grpc_target_group_arn
    container_name   = "temporal-server"
    container_port   = var.temporal_grpc_port
  }

  # Register server metrics endpoint in Cloud Map so Prometheus can discover via DNS SD
  service_registries {
    registry_arn = var.server_service_registry_arn
  }

  tags = {
    Name        = "${var.project_name}-temporal-server"
    Environment = var.environment
  }

  # auto-setup handles schema migration inline before the server starts — no external
  # bootstrap dependency. The DB must exist (RDS) which it does via the rds module.
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
    # Pinned to the UI release paired with Server 1.25.2 (avoid floating :latest).
    image     = "temporalio/ui:2.32.0"
    memory    = 256
    cpu       = 128
    essential = true

    portMappings = [{
      containerPort = var.temporal_ui_container_port
      hostPort      = 0
      protocol      = "tcp"
    }]

    environment = [
      # Connect via the NLB DNS. localhost does NOT work in bridge mode (the UI
      # container's loopback is itself, not the host where the server port is mapped).
      # The NLB hairpin is resolved by preserve_client_ip=false on the gRPC target group.
      { name = "TEMPORAL_ADDRESS",         value = var.temporal_server_address },
      { name = "TEMPORAL_UI_PORT",         value = tostring(var.temporal_ui_container_port) },
      { name = "TEMPORAL_OPENAPI_ENABLED", value = "true" },
      # Must match the namespace used by API and Worker — otherwise UI shows empty workflow list
      { name = "TEMPORAL_DEFAULT_NAMESPACE", value = "temporal-dev" }
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
      { name = "TEMPORAL_NAMESPACE",  value = "temporal-dev" },
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
  # awsvpc gives each worker task its own ENI/IP so Prometheus can scrape the SDK
  # metrics endpoint (:9090) via Cloud Map dns_sd — bridge mode cannot expose a
  # fixed metrics port for more than one worker per host.
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name      = "worker"
    image     = "${var.worker_ecr_repository_url}:latest"
    memory    = 512
    cpu       = 256
    essential = true

    # SDK Prometheus metrics (worker.py binds 0.0.0.0:9090). Under awsvpc the
    # container port is reachable directly on the task ENI.
    portMappings = [{
      containerPort = 9090
      protocol      = "tcp"
    }]

    # Static Temporal config + the dependency service URLs (FRAUD_SERVICE_URL, etc.)
    # resolved from Cloud Map. Without these the activities fall back to localhost
    # and fail with ConnectError.
    environment = concat(
      [
        { name = "TEMPORAL_ADDRESS",    value = var.temporal_server_address },
        { name = "TEMPORAL_NAMESPACE",  value = "temporal-dev" },
        { name = "TEMPORAL_TASK_QUEUE", value = "order-task-queue" }
      ],
      [for k, v in var.worker_service_urls : { name = k, value = v }]
    )

    healthCheck = {
      # The worker image (python:3.12-slim) has no curl — use Python's urllib like the
      # API health check does. curl-based check failed with "not found" -> UNHEALTHY ->
      # ECS kill loop, even though the worker connected and the :8081 server was serving.
      command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8081/health')\" || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 15
    }

    # 30s matches graceful_shutdown_timeout in worker.py — gives activities time to finish
    stopTimeout = 30

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

  # awsvpc networking: each task gets its own ENI in the private subnets, guarded
  # by the worker SG (egress-all; ingress :9090 only from the monitoring SG).
  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.worker_sg_id]
    assign_public_ip = false
  }

  # Register every worker task IP in Cloud Map (worker-metrics.<ns>) so Prometheus
  # discovers all scrape targets dynamically as the service scales.
  service_registries {
    registry_arn = var.worker_service_registry_arn
  }

  # Prevent Terraform from resetting desired_count on every apply — ECS Application
  # Auto Scaling manages the count at runtime; Terraform only sets the initial value.
  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = {
    Name        = "${var.project_name}-worker"
    Environment = var.environment
  }

  depends_on = [aws_ecs_service.temporal_server]
}

# ─── WORKER AUTO SCALING (TEMPORARILY DISABLED) ──────────────────────────────
# Commented out due to IAM permission issue: application-autoscaling:RegisterScalableTarget
# TODO: Re-enable after adding IAM permissions for autoscaling.
# Target 25% CPU rather than the typical 70% because Temporal Workers are
# I/O-bound (waiting on fraud/payment/shipping HTTP calls). CPU stays low even
# when all activity slots are occupied, so a low target fires before saturation.

# resource "aws_appautoscaling_target" "worker" {
#   max_capacity       = var.worker_max_capacity
#   min_capacity       = var.worker_min_capacity
#   resource_id        = "service/${var.ecs_cluster_name}/${aws_ecs_service.worker.name}"
#   scalable_dimension = "ecs:service:DesiredCount"
#   service_namespace  = "ecs"
# }

# resource "aws_appautoscaling_policy" "worker_cpu" {
#   name               = "${var.project_name}-${var.environment}-worker-cpu"
#   policy_type        = "TargetTrackingScaling"
#   resource_id        = aws_appautoscaling_target.worker.resource_id
#   scalable_dimension = aws_appautoscaling_target.worker.scalable_dimension
#   service_namespace  = aws_appautoscaling_target.worker.service_namespace

#   target_tracking_scaling_policy_configuration {
#     target_value = 25

#     predefined_metric_specification {
#       predefined_metric_type = "ECSServiceAverageCPUUtilization"
#     }

#     # Scale out fast to respond to bursts; scale in slowly to avoid thrashing
#     scale_out_cooldown = 60
#     scale_in_cooldown  = 300
#   }
# }

# ─── SEARCH ATTRIBUTE SETUP ──────────────────────────────────────────────────
# The temporal-dev namespace is created by the auto-setup server (DEFAULT_NAMESPACE).
# This only registers the OrderStatus search attribute — required because the workflow
# calls upsert_search_attributes(OrderStatus) and an unregistered attribute fails the
# workflow task. Runs once after the server is healthy — idempotent (|| true).

resource "null_resource" "temporal_namespace_setup" {
  triggers = {
    server_task_def = aws_ecs_task_definition.temporal_server.arn
  }

  # Runs inside the VPC via SSM on an active ECS container instance, talking to the
  # Temporal frontend over the NLB DNS. Robustness lessons baked in:
  #   - on_failure = continue: registration is idempotent and best-effort. A slow image
  #     pull or a transient NLB blip must NEVER fail `terraform apply` — it did before,
  #     hanging ~10m then erroring. If this step is skipped/slow, the apply still
  #     succeeds; register OrderStatus manually if ever missing:
  #       temporal --address <nlb-dns>:7233 operator search-attribute create \
  #         --namespace temporal-dev --name OrderStatus --type Keyword
  #   - Uses the PUBLIC temporalio/auto-setup image (the same one the server runs, so it
  #     is already cached on server instances) via --entrypoint temporal. No ECR login.
  provisioner "local-exec" {
    on_failure = continue
    command    = <<-EOT
      set -e
      REGION="us-east-1"
      CLUSTER="${var.ecs_cluster_id}"
      IMAGE="temporalio/auto-setup:1.25.2"
      ADDRESS="${var.temporal_server_address}"

      echo "Finding an active ECS container instance to run setup from..."
      CI="None"
      i=0
      until [ "$CI" != "None" ] && [ -n "$CI" ]; do
        i=$((i+1))
        if [ "$i" -gt 40 ]; then
          echo "Timed out waiting for an ACTIVE container instance (~10m)." >&2
          exit 1
        fi
        CI=$(aws ecs list-container-instances \
          --cluster "$CLUSTER" --status ACTIVE --region "$REGION" \
          --query 'containerInstanceArns[0]' --output text 2>/dev/null || echo "None")
        [ "$CI" = "None" ] && { echo "  no active container instance yet, waiting 15s..."; sleep 15; }
      done

      INSTANCE_ID=$(aws ecs describe-container-instances \
        --cluster "$CLUSTER" --container-instances "$CI" \
        --region "$REGION" \
        --query 'containerInstances[0].ec2InstanceId' --output text 2>/dev/null || echo "None")

      # Fail clearly instead of letting send-command throw a cryptic InvalidInstanceId.
      case "$INSTANCE_ID" in
        i-*) ;;
        *) echo "Could not resolve a container-instance EC2 id (got '$INSTANCE_ID'); re-run apply." >&2; exit 1 ;;
      esac

      echo "Running namespace setup from $INSTANCE_ID via SSM (server at NLB $ADDRESS)..."
      CMD_ID=$(aws ssm send-command \
        --document-name "AWS-RunShellScript" \
        --instance-ids "$INSTANCE_ID" \
        --parameters "{\"commands\":[
          \"docker pull $IMAGE > /dev/null 2>&1 || true\",
          \"n=0; until docker run --rm --network host --entrypoint temporal $IMAGE --address $ADDRESS operator cluster health > /dev/null 2>&1; do n=\$((n+1)); [ \$n -gt 24 ] && break; echo waiting-for-server; sleep 5; done\",
          \"docker run --rm --network host --entrypoint temporal $IMAGE --address $ADDRESS operator search-attribute create --namespace temporal-dev --name OrderStatus --type Keyword || true\",
          \"echo search-attribute-setup-done\"
        ]}" \
        --region "$REGION" \
        --query 'Command.CommandId' --output text)

      # Poll for completion ourselves — `aws ssm wait command-executed` only polls
      # ~100s, but the command waits inside SSM for the freshly-booted server to be
      # SERVING (schema check + ~60s + first-time admin-tools image pull on a new
      # instance), which routinely exceeds 100s. Wait up to ~10m.
      echo "Waiting for SSM command $CMD_ID to finish..."
      j=0
      while true; do
        j=$((j+1))
        # get-command-invocation can briefly 404 right after send-command; treat as Pending.
        STATUS=$(aws ssm get-command-invocation \
          --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
          --region "$REGION" --query 'Status' --output text 2>/dev/null || echo "Pending")
        case "$STATUS" in
          Success)
            echo "Namespace setup complete."
            break
            ;;
          Failed|Cancelled|TimedOut|DeliveryTimedOut)
            echo "SSM command $STATUS:" >&2
            aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
              --region "$REGION" --query 'StandardErrorContent' --output text >&2 || true
            exit 1
            ;;
        esac
        if [ "$j" -gt 30 ]; then
          echo "SSM search-attribute command still running after ~5m (non-fatal)." >&2
          exit 1
        fi
        sleep 10
      done
    EOT
  }

  depends_on = [aws_ecs_service.temporal_server]
}
