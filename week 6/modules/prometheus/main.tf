locals {
  default_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  prometheus_yml = <<-YAML
    global:
      scrape_interval: 15s
      evaluation_interval: 15s
      external_labels:
        cluster: '${var.cluster_name}'
        environment: '${var.environment}'

    alerting:
      alertmanagers:
        - static_configs:
            - targets: ['localhost:9093']

    rule_files:
      - /etc/prometheus/alert_rules.yml

    scrape_configs:
      - job_name: prometheus
        static_configs:
          - targets: ['localhost:9090']

      - job_name: node_exporter
        ec2_sd_configs:
          - region: '${var.aws_region}'
            port: 9100
            filters:
              - name: tag:AmazonECSManaged
                values: ['true']
              - name: instance-state-name
                values: ['running']
        relabel_configs:
          - source_labels: [__meta_ec2_private_ip]
            target_label: instance
          - source_labels: [__meta_ec2_tag_Name]
            target_label: name

      - job_name: demo_app
        dns_sd_configs:
          - names:
              - '${var.demo_app_dns_name}'
            type: A
            port: 80
            refresh_interval: 30s
        metrics_path: /metrics
        relabel_configs:
          - source_labels: [__address__]
            target_label: instance
  YAML

  alert_rules_yml = <<-YAML
    groups:
      - name: recording_rules
        interval: 15s
        rules:
          - record: instance:node_cpu_utilisation:rate5m
            expr: |
              100 - (
                avg by(instance) (
                  irate(node_cpu_seconds_total{mode="idle"}[5m])
                ) * 100
              )
          - record: instance:node_memory_utilisation:ratio
            expr: |
              1 - (
                node_memory_MemAvailable_bytes
                / node_memory_MemTotal_bytes
              )
          - record: instance:node_filesystem_utilisation:ratio
            expr: |
              1 - (
                node_filesystem_avail_bytes{mountpoint="/",fstype!="tmpfs",fstype!="overlay"}
                / node_filesystem_size_bytes{mountpoint="/",fstype!="tmpfs",fstype!="overlay"}
              )
          - record: job:app_requests_success:ratio_rate5m
            expr: |
              sum(rate(app_requests_total{status!~"5.."}[5m]))
              / sum(rate(app_requests_total[5m]))
          - record: job:app_request_errors:ratio_rate5m
            expr: |
              (sum(rate(app_requests_total{status=~"5.."}[5m])) or vector(0))
              / sum(rate(app_requests_total[5m]))
          - record: job:app_requests:rate5m
            expr: sum(rate(app_requests_total[5m]))
          - record: job:app_request_latency_seconds:p95rate5m
            expr: |
              histogram_quantile(
                0.95,
                sum by(le) (rate(app_request_latency_seconds_bucket[5m]))
              )

      - name: host_alerts
        rules:
          - alert: NodeDown
            expr: up{job="node_exporter"} == 0
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "Node Exporter unreachable: {{ $labels.instance }}"
              description: "Cannot scrape host metrics. Instance may be down."
          - alert: HighCPU
            expr: instance:node_cpu_utilisation:rate5m > 80
            for: 3m
            labels:
              severity: warning
            annotations:
              summary: "High CPU on {{ $labels.instance }}: {{ $value | printf \"%.1f\" }}%"
              description: "CPU has been above 80% for 3 minutes."
          - alert: HighMemory
            expr: instance:node_memory_utilisation:ratio > 0.80
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "High memory on {{ $labels.instance }}: {{ $value | humanizePercentage }}"
              description: "Memory usage above 80% for 5 minutes."
          - alert: DiskAlmostFull
            expr: instance:node_filesystem_utilisation:ratio > 0.85
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Disk almost full on {{ $labels.instance }}: {{ $value | humanizePercentage }}"
              description: "Root filesystem above 85% for 5 minutes."

      - name: app_alerts
        rules:
          - alert: AppDown
            expr: up{job="demo_app"} == 0
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "Demo app unreachable: {{ $labels.instance }}"
              description: "Prometheus cannot scrape /metrics. App may be down."
          - alert: HighErrorRate
            expr: job:app_request_errors:ratio_rate5m > 0.05
            for: 2m
            labels:
              severity: warning
            annotations:
              summary: "High error rate: {{ $value | humanizePercentage }}"
              description: "More than 5% of requests returning 5xx errors for 2 minutes."
  YAML

  alertmanager_yml = <<-YAML
    global:
      resolve_timeout: 5m

    route:
      group_by: ['alertname', 'severity']
      group_wait: 10s
      group_interval: 5m
      repeat_interval: 4h
      receiver: sns-webhook
      routes:
        - matchers:
            - severity = critical
          repeat_interval: 1h
          receiver: sns-webhook

    receivers:
      - name: sns-webhook
        webhook_configs:
          - url: 'http://localhost:9094/alert'
            send_resolved: true

    inhibit_rules:
      - source_matchers:
          - severity = critical
        target_matchers:
          - severity = warning
        equal: ['alertname', 'instance']
  YAML

  # Minimal HTTP server that forwards AlertManager webhooks to SNS.
  # Runs as a sidecar on localhost:9094 inside the Prometheus task.
  sns_bridge_script = <<-PYTHON
    import boto3, json, os
    from http.server import HTTPServer, BaseHTTPRequestHandler

    SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
    AWS_REGION    = os.environ["AWS_REGION"]

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass  # suppress default access log noise

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            body   = json.loads(self.rfile.read(length))
            sns    = boto3.client("sns", region_name=AWS_REGION)
            for alert in body.get("alerts", []):
                name    = alert["labels"].get("alertname", "Alert")
                status  = alert["status"].upper()
                summary = alert["annotations"].get("summary", name)
                sns.publish(
                    TopicArn=SNS_TOPIC_ARN,
                    Subject=f"[{status}] Prometheus: {name}",
                    Message=f"{summary}\n\nLabels: {json.dumps(alert['labels'], indent=2)}",
                )
            self.send_response(200)
            self.end_headers()

    HTTPServer(("0.0.0.0", 9094), Handler).serve_forever()
  PYTHON
}

# ── IAM: Prometheus ECS task role ────────────────────────────────────────────

resource "aws_iam_role" "prometheus_task" {
  name_prefix = "${var.project_name}-${var.environment}-prom-task-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-prom-task-role"
  })
}

resource "aws_iam_policy" "prometheus_task" {
  name_prefix = "${var.project_name}-${var.environment}-prom-task-"
  description = "Allows Prometheus ECS task to run ec2_sd_configs, ecs_sd_configs, and publish alerts to SNS."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2ServiceDiscovery"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeAvailabilityZones"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECSServiceDiscovery"
        Effect = "Allow"
        Action = [
          "ecs:ListClusters",
          "ecs:ListTasks",
          "ecs:DescribeTasks",
          "ecs:DescribeServices",
          "ecs:DescribeClusters",
          "ecs:ListContainerInstances",
          "ecs:DescribeContainerInstances"
        ]
        Resource = "*"
      },
      {
        Sid    = "SNSPublish"
        Effect = "Allow"
        Action = ["sns:Publish"]
        Resource = var.sns_topic_arn
      },
      {
        Sid    = "EFSMount"
        Effect = "Allow"
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:ClientRootAccess"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "prometheus_task" {
  role       = aws_iam_role.prometheus_task.name
  policy_arn = aws_iam_policy.prometheus_task.arn
}

# ── IAM: ECS execution role (image pull + CloudWatch Logs) ───────────────────

resource "aws_iam_role" "prometheus_execution" {
  name_prefix = "${var.project_name}-${var.environment}-prom-exec-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-prom-exec-role"
  })
}

resource "aws_iam_role_policy_attachment" "prometheus_execution" {
  role       = aws_iam_role.prometheus_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_policy" "prometheus_execution_service_connect" {
  name_prefix = "${var.project_name}-${var.environment}-prom-exec-sc-"
  description = "Allows Prometheus ECS execution role to register with ECS Service Connect."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECSServiceConnect"
        Effect = "Allow"
        Action = [
          "servicediscovery:RegisterInstance",
          "servicediscovery:DeregisterInstance",
          "route53:ChangeResourceRecordSets",
          "route53:GetHealthCheck",
          "route53:CreateHealthCheck",
          "route53:UpdateHealthCheck",
          "route53:DeleteHealthCheck"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "prometheus_execution_service_connect" {
  role       = aws_iam_role.prometheus_execution.name
  policy_arn = aws_iam_policy.prometheus_execution_service_connect.arn
}

# ── CloudWatch log groups ─────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "prometheus" {
  name              = "/ecs/${var.project_name}/${var.environment}/prometheus"
  retention_in_days = 7

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-prometheus-logs"
  })
}

resource "aws_cloudwatch_log_group" "sns_bridge" {
  name              = "/ecs/${var.project_name}/${var.environment}/sns-bridge"
  retention_in_days = 7

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-sns-bridge-logs"
  })
}

# ── ECS task definition ───────────────────────────────────────────────────────
#
# Three containers in one task (all on localhost):
#   prometheus    — scrapes metrics, evaluates rules, routes to AlertManager
#   alertmanager  — deduplicates and routes firing alerts to the SNS bridge
#   sns-bridge    — lightweight HTTP server that forwards webhooks to SNS

resource "aws_ecs_task_definition" "prometheus" {
  family                   = "${var.project_name}-${var.environment}-prometheus"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  task_role_arn            = aws_iam_role.prometheus_task.arn
  execution_role_arn       = aws_iam_role.prometheus_execution.arn

  container_definitions = jsonencode([
    {
      name      = "prometheus"
      image     = "prom/prometheus:v2.53.0"
      essential = true

      portMappings = [{ containerPort = 9090, protocol = "tcp", name = "prometheus-http" }]

      # Write configs from base64-encoded locals so no S3 bucket or custom image is needed.
      entryPoint = ["sh", "-c"]
      command = [
        "printf '%s' '${base64encode(local.prometheus_yml)}' | base64 -d > /etc/prometheus/prometheus.yml && printf '%s' '${base64encode(local.alert_rules_yml)}' | base64 -d > /etc/prometheus/alert_rules.yml && /bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.retention.time=15d --storage.tsdb.path=/prometheus --web.enable-lifecycle --web.enable-admin-api"
      ]

      mountPoints = [
        { sourceVolume = "prometheus-data", containerPath = "/prometheus", readOnly = false }
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "wget -qO- http://localhost:9090/-/healthy || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }

      memory            = 384
      memoryReservation = 256

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.prometheus.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "prometheus"
        }
      }
    },
    {
      name      = "alertmanager"
      image     = "prom/alertmanager:v0.27.0"
      essential = false

      portMappings = [{ containerPort = 9093, protocol = "tcp" }]

      entryPoint = ["sh", "-c"]
      command = [
        "printf '%s' '${base64encode(local.alertmanager_yml)}' | base64 -d > /tmp/alertmanager.yml && /bin/alertmanager --config.file=/tmp/alertmanager.yml --storage.path=/alertmanager"
      ]

      memory            = 128
      memoryReservation = 64

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.prometheus.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "alertmanager"
        }
      }
    },
    {
      name      = "sns-bridge"
      image     = "python:3.12-slim"
      essential = false

      entryPoint = ["sh", "-c"]
      command = [
        "pip install boto3 -q && printf '%s' '${base64encode(local.sns_bridge_script)}' | base64 -d > /tmp/bridge.py && python3 /tmp/bridge.py"
      ]

      environment = [
        { name = "AWS_REGION",    value = var.aws_region },
        { name = "SNS_TOPIC_ARN", value = var.sns_topic_arn }
      ]

      memory            = 128
      memoryReservation = 64

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.sns_bridge.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "sns-bridge"
        }
      }
    }
  ])

  volume {
    name = "prometheus-data"
    efs_volume_configuration {
      file_system_id          = var.efs_id
      transit_encryption      = "ENABLED"
      authorization_config {
        access_point_id = var.prometheus_access_point_id
        iam             = "ENABLED"
      }
    }
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-prometheus-task"
  })
}

# ── ECS Service ───────────────────────────────────────────────────────────────
#
# REPLICA desired_count=1: the task spec prohibits multiple monitoring instances.
# deployment_minimum_healthy_percent=0 allows rolling replace on a single-task service.

resource "aws_ecs_service" "prometheus" {
  name            = "${var.project_name}-${var.environment}-prometheus-svc"
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.prometheus.arn
  desired_count   = 1
  launch_type     = "EC2"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.monitoring_sg_id]
    assign_public_ip = false
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Register the Prometheus task IP in Cloud Map so Grafana resolves
  # prometheus.${namespace} via the VPC private hosted zone. The record
  # is updated automatically on every task replacement.
  service_registries {
    registry_arn = aws_service_discovery_service.prometheus.arn
  }

  enable_execute_command = false

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-prometheus-svc"
  })
}

# ── Cloud Map service for Prometheus DNS registration ─────────────────────────
# Each task registers its private IP as an A record under prometheus.<namespace>.
# Grafana uses this FQDN to reach Prometheus without any hardcoded IPs.
resource "aws_service_discovery_service" "prometheus" {
  name = "prometheus"

  dns_config {
    namespace_id   = split("/", var.cloudmap_namespace_arn)[1]
    routing_policy = "WEIGHTED"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-prometheus-cloudmap"
  })
}
