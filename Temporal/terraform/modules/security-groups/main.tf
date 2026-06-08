# Security Groups for Temporal Order Management
# Cross-SG references are expressed as separate aws_security_group_rule resources
# to break the circular dependency that would arise from inline ingress/egress blocks.

# ─── ALB ────────────────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${var.environment}-alb-sg"
  description = "Allow HTTP inbound for API and Temporal UI"
  vpc_id      = var.vpc_id

  ingress {
    description = "API (port 8000)"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Temporal UI (port 8080)"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP legacy (port 80)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-alb-sg"
    Environment = var.environment
  }
}

# ─── ECS INSTANCE ────────────────────────────────────────────────────────────

resource "aws_security_group" "ecs_instance" {
  name        = "${var.project_name}-${var.environment}-ecs-instance-sg"
  description = "EC2 instances running ECS tasks - inbound from ALB"
  vpc_id      = var.vpc_id

  # Ingress is managed entirely by separate aws_security_group_rule resources below
  # (dynamic host ports from ALB, gRPC, metrics). Only egress is inline here — this SG
  # has no separate egress rules, so there's no inline-vs-separate conflict.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-ecs-instance-sg"
    Environment = var.environment
  }
}

# ─── TEMPORAL SERVER ─────────────────────────────────────────────────────────

resource "aws_security_group" "temporal" {
  name        = "${var.project_name}-${var.environment}-temporal-sg"
  description = "Temporal Server - gRPC inbound from API and Worker"
  vpc_id      = var.vpc_id

  # Inline all-outbound egress (the awsvpc server task needs RDS 5432, ECR/AWS 443,
  # DNS 53). MUST be inline, not a separate aws_security_group_rule — mixing inline
  # egress with separate egress rules makes the inline block authoritative and silently
  # revokes the separate rules on every apply.
  egress {
    description = "All outbound (RDS, ECR, AWS APIs, DNS) for the awsvpc server task"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-temporal-sg"
    Environment = var.environment
  }
}

# ─── API ─────────────────────────────────────────────────────────────────────

resource "aws_security_group" "api" {
  name        = "${var.project_name}-${var.environment}-api-sg"
  description = "FastAPI service - inbound from ALB"
  vpc_id      = var.vpc_id

  ingress {
    description     = "API from ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Inline all-outbound egress (awsvpc API task needs NLB gRPC 7233, ECR/AWS 443, DNS).
  # Inline-only — see the temporal SG note about inline vs separate egress conflicts.
  egress {
    description = "All outbound (NLB gRPC, ECR, AWS APIs, DNS) for the awsvpc API task"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-api-sg"
    Environment = var.environment
  }
}

# ─── WORKER ──────────────────────────────────────────────────────────────────

resource "aws_security_group" "worker" {
  name        = "${var.project_name}-${var.environment}-worker-sg"
  description = "Temporal Worker - no inbound, outbound to Temporal Server only"
  vpc_id      = var.vpc_id

  # Inline all-outbound egress (awsvpc worker needs NLB gRPC 7233, mock services 8000,
  # ECR/AWS 443, DNS 53). Inline-only — see the temporal SG note. This is the bug that
  # caused the worker to crash-loop with "connection timed out" to the Temporal NLB:
  # the separate worker_egress_all rule kept being revoked by an inline 443-only block.
  egress {
    description = "All outbound (NLB gRPC, mock services, ECR, AWS APIs, DNS) for awsvpc worker"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-worker-sg"
    Environment = var.environment
  }
}

# ─── MONITORING (Prometheus + Grafana, awsvpc tasks) ─────────────────────────
# Attached to Prometheus and Grafana ECS tasks. Grafana UI (3000) is reachable
# from the ALB only. Scrape rules (monitoring → worker:9090, ecs-instance:9100/8001)
# are separate aws_security_group_rule resources below to avoid circular references.

resource "aws_security_group" "monitoring" {
  name        = "${var.project_name}-${var.environment}-monitoring-sg"
  description = "Prometheus + Grafana tasks. Grafana 3000 from ALB; scrape rules are external."
  vpc_id      = var.vpc_id

  # Ingress (Grafana 3000 from ALB, Prometheus self-scrape) is managed by separate
  # aws_security_group_rule resources below. Only egress is inline (no separate egress
  # rules target this SG), so there is no inline-vs-separate conflict.
  egress {
    description = "All outbound (AWS APIs for EC2 SD, EFS mounts, ECR pulls, scrape targets)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-monitoring-sg"
    Environment = var.environment
  }
}

# ─── EFS (Prometheus TSDB persistence) ───────────────────────────────────────

resource "aws_security_group" "efs" {
  name        = "${var.project_name}-${var.environment}-efs-sg"
  description = "Allow NFS (2049) from monitoring tasks for Prometheus TSDB persistence."
  vpc_id      = var.vpc_id

  ingress {
    description     = "NFS from Prometheus task"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-efs-sg"
    Environment = var.environment
  }
}

# ─── MOCK DEPENDENCY SERVICES (fraud/inventory/payment/shipping/notification) ──
# awsvpc tasks the worker calls over HTTP on :8000. Reachable only from the worker.

resource "aws_security_group" "services" {
  name        = "${var.project_name}-${var.environment}-services-sg"
  description = "Dependency mock services - inbound :8000 from the worker only."
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP :8000 from the Temporal worker"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.worker.id]
  }

  egress {
    description = "All outbound (ECR pulls, AWS APIs, DNS)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-services-sg"
    Environment = var.environment
  }
}

# ─── RDS ─────────────────────────────────────────────────────────────────────

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.environment}-rds-sg"
  description = "PostgreSQL RDS - inbound from Temporal Server only"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-rds-sg"
    Environment = var.environment
  }
}

# ─── CROSS-SG RULES (avoid circular inline references) ───────────────────────

# ALB → EC2 host dynamic port range (bridge-mode ephemeral ports for UI/API/Grafana).
# Moved out of the ecs_instance SG inline block so all ecs_instance ingress is managed
# by separate rules (mixing inline + separate ingress revokes the separate ones).
resource "aws_security_group_rule" "ecs_instance_ingress_dynamic_from_alb" {
  type                     = "ingress"
  from_port                = 32768
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs_instance.id
  source_security_group_id = aws_security_group.alb.id
  description              = "ALB to dynamic host ports (bridge mode ephemeral range)"
}

# ALB → Grafana UI (3000). Moved out of the monitoring SG inline ingress block.
resource "aws_security_group_rule" "monitoring_ingress_grafana_from_alb" {
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.monitoring.id
  source_security_group_id = aws_security_group.alb.id
  description              = "Grafana UI from ALB only"
}

resource "aws_security_group_rule" "temporal_ingress_from_nlb" {
  type              = "ingress"
  from_port         = 7233
  to_port           = 7233
  protocol          = "tcp"
  security_group_id = aws_security_group.temporal.id
  cidr_blocks       = [var.vpc_cidr]
  description       = "Temporal gRPC from NLB health checks (NLBs have no SG, use VPC CIDR)"
}

resource "aws_security_group_rule" "temporal_ingress_from_api" {
  type                     = "ingress"
  from_port                = 7233
  to_port                  = 7233
  protocol                 = "tcp"
  security_group_id        = aws_security_group.temporal.id
  source_security_group_id = aws_security_group.api.id
  description              = "Temporal gRPC from API"
}

resource "aws_security_group_rule" "temporal_ingress_from_worker" {
  type                     = "ingress"
  from_port                = 7233
  to_port                  = 7233
  protocol                 = "tcp"
  security_group_id        = aws_security_group.temporal.id
  source_security_group_id = aws_security_group.worker.id
  description              = "Temporal gRPC from Worker"
}

# temporal egress is now an inline all-outbound block on the temporal SG (above).
# Separate egress rules were removed — mixing inline + separate egress caused the
# inline block to silently revoke them on every apply.

# Prometheus scrapes the server's :8001 metrics endpoint on the task ENI.
resource "aws_security_group_rule" "temporal_ingress_metrics_from_monitoring" {
  type                     = "ingress"
  from_port                = 8001
  to_port                  = 8001
  protocol                 = "tcp"
  security_group_id        = aws_security_group.temporal.id
  source_security_group_id = aws_security_group.monitoring.id
  description              = "Temporal Server Prometheus metrics (:8001) scraped by Prometheus"
}

# api and worker egress are now inline all-outbound blocks on their SGs (above).
# Separate egress rules removed to avoid the inline-vs-separate revoke conflict.

resource "aws_security_group_rule" "rds_ingress_from_temporal" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.temporal.id
  description              = "PostgreSQL from Temporal Server"
}

# rds_ingress_from_api intentionally removed — the API never connects to RDS directly.
# API → Temporal Server → RDS is the correct path. Allowing API → RDS widens the
# blast radius if the API container is compromised without providing any functionality.

resource "aws_security_group_rule" "ecs_instance_ingress_from_api_grpc" {
  type                     = "ingress"
  from_port                = 7233
  to_port                  = 7233
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs_instance.id
  source_security_group_id = aws_security_group.api.id
  description              = "Temporal gRPC from API"
}

resource "aws_security_group_rule" "ecs_instance_ingress_from_worker_grpc" {
  type                     = "ingress"
  from_port                = 7233
  to_port                  = 7233
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs_instance.id
  source_security_group_id = aws_security_group.worker.id
  description              = "Temporal gRPC from Worker"
}

# Bridge mode: containers NAT through the host NIC (ecs-instance-sg).
# NLB preserves client IP, so gRPC traffic arrives from the EC2 host IP —
# not from the task-level SGs. Allow the full VPC CIDR on 7233 to cover
# both NLB health checks and bridge-NAT'd container traffic.
resource "aws_security_group_rule" "ecs_instance_ingress_grpc_from_vpc" {
  type              = "ingress"
  from_port         = 7233
  to_port           = 7233
  protocol          = "tcp"
  security_group_id = aws_security_group.ecs_instance.id
  cidr_blocks       = [var.vpc_cidr]
  description       = "Temporal gRPC from VPC (NLB + bridge-mode NAT)"
}

# RDS inbound from ECS instance SG: in bridge mode all container egress
# (including Temporal Server → PostgreSQL) exits via the host NIC.
resource "aws_security_group_rule" "rds_ingress_from_ecs_instance" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.ecs_instance.id
  description              = "PostgreSQL from ECS instances (bridge mode)"
}

# ─── MONITORING SCRAPE + GRAFANA RULES ───────────────────────────────────────

# Prometheus (awsvpc) → Worker (awsvpc) SDK metrics on :9090.
resource "aws_security_group_rule" "worker_ingress_metrics_from_monitoring" {
  type                     = "ingress"
  from_port                = 9090
  to_port                  = 9090
  protocol                 = "tcp"
  security_group_id        = aws_security_group.worker.id
  source_security_group_id = aws_security_group.monitoring.id
  description              = "Worker SDK Prometheus metrics scraped by Prometheus"
}

# Prometheus → Node Exporter (host network mode) on :9100, on the EC2 host NIC.
resource "aws_security_group_rule" "ecs_instance_ingress_node_exporter_from_monitoring" {
  type                     = "ingress"
  from_port                = 9100
  to_port                  = 9100
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs_instance.id
  source_security_group_id = aws_security_group.monitoring.id
  description              = "Node Exporter host metrics scraped by Prometheus"
}

# Prometheus → Temporal Server metrics (bridge mode, hostPort 8001) on the host NIC.
resource "aws_security_group_rule" "ecs_instance_ingress_server_metrics_from_monitoring" {
  type                     = "ingress"
  from_port                = 8001
  to_port                  = 8001
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs_instance.id
  source_security_group_id = aws_security_group.monitoring.id
  description              = "Temporal Server Prometheus metrics scraped by Prometheus"
}

# Grafana → Prometheus on :9090 (both in the monitoring SG — self-reference).
# Without this Grafana's datasource cannot reach Prometheus.
resource "aws_security_group_rule" "monitoring_ingress_prometheus_self" {
  type                     = "ingress"
  from_port                = 9090
  to_port                  = 9090
  protocol                 = "tcp"
  security_group_id        = aws_security_group.monitoring.id
  source_security_group_id = aws_security_group.monitoring.id
  description              = "Grafana to Prometheus query API (9090) within the monitoring SG"
}

# Grafana (monitoring SG) → RDS PostgreSQL for its backend database.
resource "aws_security_group_rule" "rds_ingress_from_monitoring" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.monitoring.id
  description              = "PostgreSQL from Grafana (backend DB)"
}

# worker egress is now an inline all-outbound block on the worker SG (above).
