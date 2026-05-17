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

  ingress {
    description     = "ALB to dynamic host ports (bridge mode ephemeral range)"
    from_port       = 32768
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

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

  egress {
    description = "HTTPS for ECR pulls"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
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

  egress {
    description = "HTTPS for ECR pulls"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
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

  egress {
    description = "HTTPS for ECR pulls"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-worker-sg"
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

resource "aws_security_group_rule" "temporal_egress_to_rds" {
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.temporal.id
  source_security_group_id = aws_security_group.rds.id
  description              = "PostgreSQL to RDS"
}

resource "aws_security_group_rule" "api_egress_to_temporal" {
  type                     = "egress"
  from_port                = 7233
  to_port                  = 7233
  protocol                 = "tcp"
  security_group_id        = aws_security_group.api.id
  source_security_group_id = aws_security_group.temporal.id
  description              = "Temporal gRPC endpoint"
}

resource "aws_security_group_rule" "worker_egress_to_temporal" {
  type                     = "egress"
  from_port                = 7233
  to_port                  = 7233
  protocol                 = "tcp"
  security_group_id        = aws_security_group.worker.id
  source_security_group_id = aws_security_group.temporal.id
  description              = "Temporal gRPC endpoint"
}

resource "aws_security_group_rule" "rds_ingress_from_temporal" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.temporal.id
  description              = "PostgreSQL from Temporal Server"
}

resource "aws_security_group_rule" "rds_ingress_from_api" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.api.id
  description              = "PostgreSQL from API (optional monitoring)"
}

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
