# Centralized observability for the Temporal platform.
# Mirrors the Week 6 SRE pattern, adapted for Temporal:
#   - Prometheus + AlertManager + SNS bridge (one awsvpc task, on localhost)
#   - Node Exporter (DAEMON, host network) for EC2 host metrics
#   - Grafana (awsvpc) backed by the existing PostgreSQL RDS
#   - EFS for Prometheus TSDB persistence across task restarts
# Scrape targets:
#   - temporal-worker : Cloud Map dns_sd (worker-metrics.<ns>:9090) — SDK metrics
#   - temporal-server : ec2_sd :8001 — server metrics
#   - node_exporter   : ec2_sd :9100 — host metrics

locals {
  default_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  prometheus_fqdn = "prometheus.${var.cloudmap_namespace_name}"

  # ── Prometheus scrape config ────────────────────────────────────────────────
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
      - /etc/prometheus/recording_rules.yml
      - /etc/prometheus/alert_rules.yml

    scrape_configs:
      - job_name: prometheus
        static_configs:
          - targets: ['localhost:9090']

      # Temporal Worker SDK metrics — every worker task IP via Cloud Map MULTIVALUE.
      - job_name: temporal-worker
        dns_sd_configs:
          - names: ['${var.worker_metrics_dns_name}']
            type: A
            port: ${var.worker_metrics_port}
            refresh_interval: 15s
        relabel_configs:
          - source_labels: [__meta_dns_name]
            target_label: service

      # Temporal Server metrics — awsvpc task, discovered via Cloud Map DNS SD.
      - job_name: temporal-server
        dns_sd_configs:
          - names: ['server-metrics.${var.cloudmap_namespace_name}']
            type: A
            port: ${var.temporal_server_metrics_port}
            refresh_interval: 15s
        relabel_configs:
          - source_labels: [__meta_dns_name]
            target_label: instance

      # Node Exporter — host network mode, one per EC2 host.
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
  YAML

  # ── Alert rules — thresholds and metric names verified against the Temporal KB.
  # Python uses the Core SDK: metric prefix `temporal_`, NO `_seconds` suffix
  # (only the Java SDK appends `_seconds`).
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

      - name: temporal_worker_alerts
        rules:
          # absent() — not `up == 0`. Workers are discovered via Cloud Map dns_sd;
          # if ALL workers die, ECS deregisters the records, the DNS name empties,
          # and the `up` series disappears entirely — so `up == 0` would be vacuous
          # and never fire. absent() catches "no healthy worker series exists".
          - alert: TemporalWorkerDown
            expr: absent(up{job="temporal-worker"} == 1)
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "Temporal worker unreachable"
              description: "No worker is reporting a healthy scrape target for 2 minutes (all workers down or undiscoverable)."

          - alert: WorkerActivitySlotsExhausted
            expr: temporal_worker_task_slots_available{worker_type="ActivityWorker"} == 0
            for: 2m
            labels:
              severity: warning
            annotations:
              summary: "Activity worker slots exhausted"
              description: "All activity slots are occupied — workers cannot accept new activities. Scale out."

          # NOTE: Core (Python) SDK histograms are in MILLISECONDS, so 150ms = 150
          # (not 0.15). A seconds-based reference like the "Scaling Temporal" blog
          # would use 0.15 — do not copy that threshold here.
          - alert: HighActivityScheduleToStartLatency
            expr: histogram_quantile(0.95, sum(rate(temporal_activity_schedule_to_start_latency_bucket[5m])) by (le)) > 150
            for: 3m
            labels:
              severity: warning
            annotations:
              summary: "Activity schedule-to-start p95 > 150ms"
              description: "Activities are queueing — workers can't keep up. This is the primary scale-out signal per Temporal guidance."

          - alert: HighWorkflowTaskScheduleToStartLatency
            expr: histogram_quantile(0.95, sum(rate(temporal_workflow_task_schedule_to_start_latency_bucket[5m])) by (le)) > 150
            for: 3m
            labels:
              severity: warning
            annotations:
              summary: "Workflow task schedule-to-start p95 > 150ms"
              description: "Workflow tasks are queueing — insufficient workflow pollers."

      - name: temporal_server_alerts
        rules:
          # max(...) == 0 — not per-target `up == 0`. ec2_sd scrapes :8001 on ALL
          # EC2 hosts, but only ONE runs temporal-server (distinctInstance, desired=1),
          # so the other hosts always report up=0. Per-target `up == 0` would fire
          # constantly. max() fires only when NO instance is serving :8001.
          - alert: TemporalServerDown
            expr: max(up{job="temporal-server"}) == 0
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "Temporal server metrics endpoint down"
              description: "No instance is serving the Temporal Server :8001 metrics endpoint for 2 minutes."

      - name: host_alerts
        rules:
          - alert: NodeDown
            expr: up{job="node_exporter"} == 0
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "Node Exporter unreachable: {{ $labels.instance }}"
              description: "Cannot scrape host metrics. EC2 instance may be down."

          - alert: HighCPU
            expr: instance:node_cpu_utilisation:rate5m > 80
            for: 3m
            labels:
              severity: warning
            annotations:
              summary: "High CPU on {{ $labels.instance }}"
              description: "CPU has been above 80% for 3 minutes."

          - alert: HighMemory
            expr: instance:node_memory_utilisation:ratio > 0.85
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "High memory on {{ $labels.instance }}"
              description: "Memory usage above 85% for 5 minutes."

      # ── SLO burn-rate alerts (multi-window, Google SRE) ─────────────────────
      # Availability SLO = 99% over 30d → error budget = 1%. Fast burn (1h window
      # at 14.4x) pages; slow burn (6h window at 6x) tickets.
      - name: temporal_slo_alerts
        rules:
          - alert: WorkflowSLOFastBurn
            expr: temporal:workflow_error_rate:ratio_rate1h > (14.4 * (1 - 0.99))
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "Workflow SLO fast burn — error budget draining"
              description: "1h workflow error rate {{ $value | humanizePercentage }} exceeds 14.4x budget; the 30-day 99% budget would exhaust in ~2 days at this rate."

          - alert: WorkflowSLOSlowBurn
            expr: temporal:workflow_error_rate:ratio_rate6h > (6 * (1 - 0.99))
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Workflow SLO slow burn"
              description: "6h workflow error rate {{ $value | humanizePercentage }} exceeds 6x budget."

      # ── Correctness (worker SDK, per workflow/activity type) ────────────────
      - name: temporal_correctness_alerts
        rules:
          # The non-determinism / code-bug canary. A failing workflow task is
          # retried indefinitely, so this surfaces bugs BEFORE workflows fail.
          - alert: HighWorkflowTaskExecutionFailure
            expr: sum(rate(temporal_workflow_task_execution_failed[5m])) by (workflow_type) > 0
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Workflow task failures on {{ $labels.workflow_type }}"
              description: "Sustained workflow-task failures — usually non-determinism or a code panic. Workflows retry the task until the worker is fixed and redeployed."

          - alert: ActivityExecutionFailureRateHigh
            expr: sum(rate(temporal_activity_execution_failed[5m])) by (activity_type) > 0.1
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Elevated final activity failures: {{ $labels.activity_type }}"
              description: "Activity failures exhausting retries above 0.1/s for 10m."

          - alert: HighRequestFailure
            expr: sum(rate(temporal_request_failure[5m])) > 0
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Worker gRPC request failures"
              description: "temporal_request_failure rising — task-completion timeouts, payload-size (4MB) limits, or proxy rejections."

          - alert: HighLongRequestFailure
            expr: sum(rate(temporal_long_request_failure[5m])) > 0
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Worker long-poll request failures (possible namespace RPS throttling)"
              description: "temporal_long_request_failure rising — often namespace rate limiting."

      # ── Server health (matching + frontend, scraped on :8001) ───────────────
      - name: temporal_server_health_alerts
        rules:
          - alert: LowPollSyncRate
            expr: temporal:poll_sync_rate:ratio_rate5m < 0.95
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Poll sync rate < 95% ({{ $labels.task_type }})"
              description: "Matching is flushing tasks to persistence; schedule-to-start latency will degrade. Add pollers/workers."

          - alert: VeryLowPollSyncRate
            expr: temporal:poll_sync_rate:ratio_rate5m < 0.90
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Poll sync rate < 90% ({{ $labels.task_type }})"
              description: "Severe async matching — persistence load high and tasks backlogging."

          - alert: ServerResourceExhausted
            expr: sum(rate(service_errors_resource_exhausted[5m])) by (resource_exhausted_cause) > 0
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Temporal server resource exhausted: {{ $labels.resource_exhausted_cause }}"
              description: "RPS/concurrency/system limits being hit. Tune dynamic config or reduce load."
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

  # Minimal HTTP server forwarding AlertManager webhooks to SNS. Sidecar on :9094.
  sns_bridge_script = <<-PYTHON
    import boto3, json, os
    from http.server import HTTPServer, BaseHTTPRequestHandler

    SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
    AWS_REGION    = os.environ["AWS_REGION"]

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

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
                    Subject=f"[{status}] Temporal Prometheus: {name}"[:100],
                    Message=f"{summary}\n\nLabels: {json.dumps(alert['labels'], indent=2)}",
                )
            self.send_response(200)
            self.end_headers()

    HTTPServer(("0.0.0.0", 9094), Handler).serve_forever()
  PYTHON

  # Grafana provisions the Prometheus datasource at startup from a base64 blob —
  # no custom image or config volume needed.
  grafana_datasource_yml = <<-YAML
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        uid: temporalprom
        url: http://${local.prometheus_fqdn}:9090
        isDefault: true
        editable: true
      - name: CloudWatch
        type: cloudwatch
        uid: temporalcw
        jsonData:
          defaultRegion: ${var.aws_region}
          authType: default
        editable: true
  YAML

  # ── SLO/SLI recording rules ─────────────────────────────────────────────────
  # Precomputed so burn-rate windows are decoupled from the Grafana dashboard
  # time range. The availability SLI is SERVER-sourced (workflow_success/failed/
  # timeout/terminate/cancel on :8001) — authoritative final outcomes including
  # server-side timeouts/terminations the worker SDK never sees. Scoped to the
  # temporal-dev namespace to exclude internal temporal-system scanner workflows.
  # `or vector(1)` makes the rate 100%-healthy (error 0) when there is no traffic,
  # so idle periods don't trip the burn-rate alerts.
  # NOTE: server metrics carry no `temporal_` prefix and no `_total` suffix; SDK
  # metrics use `temporal_` and (with default Core PrometheusConfig) no `_total`.
  # Confirm exact names against /metrics on first redeploy if a panel is empty.
  recording_rules_yml = <<-YAML
    groups:
      - name: temporal_slo_recording
        interval: 30s
        rules:
          - record: temporal:workflow_success_rate:ratio_rate5m
            expr: |
              (
                sum(rate(workflow_success{namespace="temporal-dev"}[5m]))
                /
                (
                  sum(rate(workflow_success{namespace="temporal-dev"}[5m]))
                  + sum(rate(workflow_failed{namespace="temporal-dev"}[5m]))
                  + sum(rate(workflow_timeout{namespace="temporal-dev"}[5m]))
                  + sum(rate(workflow_terminate{namespace="temporal-dev"}[5m]))
                  + sum(rate(workflow_cancel{namespace="temporal-dev"}[5m]))
                )
              ) or vector(1)

          - record: temporal:workflow_error_rate:ratio_rate1h
            expr: |
              1 - (
                (
                  sum(rate(workflow_success{namespace="temporal-dev"}[1h]))
                  /
                  (
                    sum(rate(workflow_success{namespace="temporal-dev"}[1h]))
                    + sum(rate(workflow_failed{namespace="temporal-dev"}[1h]))
                    + sum(rate(workflow_timeout{namespace="temporal-dev"}[1h]))
                    + sum(rate(workflow_terminate{namespace="temporal-dev"}[1h]))
                    + sum(rate(workflow_cancel{namespace="temporal-dev"}[1h]))
                  )
                ) or vector(1)
              )

          - record: temporal:workflow_error_rate:ratio_rate6h
            expr: |
              1 - (
                (
                  sum(rate(workflow_success{namespace="temporal-dev"}[6h]))
                  /
                  (
                    sum(rate(workflow_success{namespace="temporal-dev"}[6h]))
                    + sum(rate(workflow_failed{namespace="temporal-dev"}[6h]))
                    + sum(rate(workflow_timeout{namespace="temporal-dev"}[6h]))
                    + sum(rate(workflow_terminate{namespace="temporal-dev"}[6h]))
                    + sum(rate(workflow_cancel{namespace="temporal-dev"}[6h]))
                  )
                ) or vector(1)
              )

          # Sync match rate (server matching service) by task_type. Leading
          # indicator: drops before schedule-to-start latency degrades.
          - record: temporal:poll_sync_rate:ratio_rate5m
            expr: |
              sum(rate(poll_success_sync[5m])) by (task_type)
              /
              sum(rate(poll_success[5m])) by (task_type)
  YAML

  # ── Grafana dashboard provider ──────────────────────────────────────────────
  grafana_dashboard_provider_yml = <<-YAML
    apiVersion: 1
    providers:
      - name: temporal
        orgId: 1
        folder: Temporal
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards
  YAML
}

# ═══════════════════════════════════════════════════════════════════════════════
# EFS — Prometheus TSDB persistence
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_efs_file_system" "monitoring" {
  encrypted        = true
  kms_key_id       = var.kms_key_arn
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-monitoring-efs"
  })
}

# UID 65534 (nobody) matches the user prom/prometheus runs as.
resource "aws_efs_access_point" "prometheus" {
  file_system_id = aws_efs_file_system.monitoring.id

  posix_user {
    uid = 65534
    gid = 65534
  }

  root_directory {
    path = "/prometheus"
    creation_info {
      owner_uid   = 65534
      owner_gid   = 65534
      permissions = "755"
    }
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-prometheus-ap"
  })
}

resource "aws_efs_mount_target" "monitoring" {
  count           = length(var.private_subnet_ids)
  file_system_id  = aws_efs_file_system.monitoring.id
  subnet_id       = var.private_subnet_ids[count.index]
  security_groups = [var.efs_sg_id]
}

# ═══════════════════════════════════════════════════════════════════════════════
# IAM — Prometheus task role (EC2/ECS service discovery, SNS publish, EFS mount)
# ═══════════════════════════════════════════════════════════════════════════════

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
  description = "Prometheus EC2 service discovery + SNS publish + EFS mount."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EC2ServiceDiscovery"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeAvailabilityZones"]
        Resource = "*"
      },
      {
        Sid      = "SNSPublish"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
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
        Resource = aws_efs_file_system.monitoring.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "prometheus_task" {
  role       = aws_iam_role.prometheus_task.name
  policy_arn = aws_iam_policy.prometheus_task.arn
}

# ═══════════════════════════════════════════════════════════════════════════════
# CloudWatch log groups
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_cloudwatch_log_group" "prometheus" {
  name              = "/ecs/${var.project_name}/${var.environment}/prometheus"
  retention_in_days = 7
  tags              = local.default_tags
}

resource "aws_cloudwatch_log_group" "node_exporter" {
  name              = "/ecs/${var.project_name}/${var.environment}/node-exporter"
  retention_in_days = 7
  tags              = local.default_tags
}

resource "aws_cloudwatch_log_group" "grafana" {
  name              = "/ecs/${var.project_name}/${var.environment}/grafana"
  retention_in_days = 7
  tags              = local.default_tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# Prometheus task (prometheus + alertmanager + sns-bridge) — awsvpc
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_ecs_task_definition" "prometheus" {
  family                   = "${var.project_name}-${var.environment}-prometheus"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  task_role_arn            = aws_iam_role.prometheus_task.arn
  execution_role_arn       = var.execution_role_arn

  container_definitions = jsonencode([
    {
      name      = "prometheus"
      image     = "prom/prometheus:v2.53.0"
      essential = true

      portMappings = [{ containerPort = 9090, protocol = "tcp" }]

      entryPoint = ["sh", "-c"]
      command = [
        "printf '%s' '${base64encode(local.prometheus_yml)}' | base64 -d > /etc/prometheus/prometheus.yml && printf '%s' '${base64encode(local.recording_rules_yml)}' | base64 -d > /etc/prometheus/recording_rules.yml && printf '%s' '${base64encode(local.alert_rules_yml)}' | base64 -d > /etc/prometheus/alert_rules.yml && /bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.retention.time=15d --storage.tsdb.path=/prometheus --web.enable-lifecycle"
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

      memory            = 512
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
          "awslogs-group"         = aws_cloudwatch_log_group.prometheus.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "sns-bridge"
        }
      }
    }
  ])

  volume {
    name = "prometheus-data"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.monitoring.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.prometheus.id
        iam             = "ENABLED"
      }
    }
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-prometheus-task"
  })
}

# Cloud Map A record so Grafana resolves prometheus.<namespace> across restarts.
resource "aws_service_discovery_service" "prometheus" {
  name = "prometheus"

  dns_config {
    namespace_id   = var.cloudmap_namespace_id
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
    Name = "${var.project_name}-${var.environment}-prometheus-sd"
  })
}

resource "aws_ecs_service" "prometheus" {
  name            = "${var.project_name}-${var.environment}-prometheus"
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.prometheus.arn
  desired_count   = 1
  launch_type     = "EC2"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.monitoring_sg_id]
    assign_public_ip = false
  }

  # Single-task service backed by EFS — must stop before starting the replacement.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  service_registries {
    registry_arn = aws_service_discovery_service.prometheus.arn
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-prometheus"
  })
}

# ═══════════════════════════════════════════════════════════════════════════════
# Node Exporter — DAEMON, host network + pid namespace
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_ecs_task_definition" "node_exporter" {
  family                   = "${var.project_name}-${var.environment}-node-exporter"
  requires_compatibilities = ["EC2"]
  network_mode             = "host"
  pid_mode                 = "host"
  execution_role_arn       = var.execution_role_arn

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

      portMappings = [{ hostPort = 9100, containerPort = 9100, protocol = "tcp" }]

      mountPoints = [
        { sourceVolume = "proc", containerPath = "/host/proc", readOnly = true },
        { sourceVolume = "sys", containerPath = "/host/sys", readOnly = true },
        { sourceVolume = "rootfs", containerPath = "/rootfs", readOnly = true }
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
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "node-exporter"
        }
      }
    }
  ])

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-node-exporter-task"
  })
}

resource "aws_ecs_service" "node_exporter" {
  name                               = "${var.project_name}-${var.environment}-node-exporter"
  cluster                            = var.cluster_id
  task_definition                    = aws_ecs_task_definition.node_exporter.arn
  scheduling_strategy                = "DAEMON"
  launch_type                        = "EC2"
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-node-exporter"
  })
}

# ═══════════════════════════════════════════════════════════════════════════════
# Grafana — awsvpc, PostgreSQL backend (reuses the Temporal RDS instance)
# ═══════════════════════════════════════════════════════════════════════════════

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
  description = "Grafana CloudWatch datasource read access."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "CloudWatchRead"
      Effect = "Allow"
      Action = [
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:ListMetrics",
        "cloudwatch:DescribeAlarms",
        "tag:GetResources"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "grafana_task" {
  role       = aws_iam_role.grafana_task.name
  policy_arn = aws_iam_policy.grafana_task.arn
}

resource "aws_ecs_task_definition" "grafana" {
  family                   = "${var.project_name}-${var.environment}-grafana"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  task_role_arn            = aws_iam_role.grafana_task.arn
  execution_role_arn       = var.execution_role_arn

  container_definitions = jsonencode([
    {
      name      = "grafana"
      image     = "grafana/grafana:10.4.2"
      essential = true

      portMappings = [{ containerPort = 3000, protocol = "tcp" }]

      entryPoint = ["sh", "-c"]
      command = [
        "mkdir -p /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards && printf '%s' '${base64encode(local.grafana_datasource_yml)}' | base64 -d > /etc/grafana/provisioning/datasources/datasources.yml && printf '%s' '${base64encode(local.grafana_dashboard_provider_yml)}' | base64 -d > /etc/grafana/provisioning/dashboards/dashboards.yml && printf '%s' '${base64encode(file("${path.module}/dashboards/temporal-slo.json"))}' | base64 -d > /var/lib/grafana/dashboards/temporal-slo.json && /run.sh"
      ]

      environment = [
        { name = "GF_SECURITY_ADMIN_USER",      value = "admin" },
        { name = "GF_SECURITY_ADMIN_PASSWORD",  value = var.grafana_admin_password },
        { name = "GF_USERS_ALLOW_SIGN_UP",      value = "false" },
        { name = "GF_AUTH_ANONYMOUS_ENABLED",   value = "false" },
        { name = "GF_DATABASE_TYPE",            value = "postgres" },
        { name = "GF_DATABASE_HOST",            value = "${var.rds_endpoint}:5432" },
        { name = "GF_DATABASE_NAME",            value = "grafana" },
        { name = "GF_DATABASE_USER",            value = var.db_username },
        { name = "GF_DATABASE_SSL_MODE",        value = "require" }
      ]

      secrets = [
        { name = "GF_DATABASE_PASSWORD", valueFrom = "${var.db_secret_arn}:password::" }
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "wget -qO- http://localhost:3000/api/health || exit 1"]
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
          "awslogs-group"         = aws_cloudwatch_log_group.grafana.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "grafana"
        }
      }
    }
  ])

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-grafana-task"
  })
}

resource "aws_ecs_service" "grafana" {
  name            = "${var.project_name}-${var.environment}-grafana"
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

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-grafana"
  })
}
