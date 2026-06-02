locals {
  default_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${var.environment}-alb-sg"
  description = "Allow HTTP inbound from the internet to the ALB."
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-alb-sg"
  })
}

resource "aws_security_group" "ecs" {
  name        = "${var.project_name}-${var.environment}-ecs-sg"
  description = "Allow HTTP (80) from ALB. Node Exporter and /metrics scraping rules are external aws_security_group_rule resources."
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP from ALB only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Mixing inline ingress blocks with external aws_security_group_rule resources causes
  # Terraform to remove the external rules on every apply. ignore_changes prevents that drift.
  lifecycle {
    ignore_changes = [ingress]
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-ecs-sg"
  })
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.environment}-rds-sg"
  description = "Allow MySQL (3306) from ECS only."
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL from ECS only"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Mixing inline ingress with external aws_security_group_rule causes drift on every
  # apply. Use ignore_changes so the externally-managed Grafana rule is preserved.
  lifecycle {
    ignore_changes = [ingress]
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-rds-sg"
  })
}

# Grafana runs in the monitoring SG and must reach RDS MySQL on 3306.
# Managed as an external rule (not inline) to avoid the inline+external drift problem.
resource "aws_security_group_rule" "rds_allow_grafana" {
  type                     = "ingress"
  description              = "MySQL from Grafana ECS task (monitoring SG)"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.monitoring.id
  security_group_id        = aws_security_group.rds.id
}

# Attached to Prometheus and Grafana ECS tasks (awsvpc) on private subnets.
# Port 9090 (Grafana→Prometheus) and 9100 (Prometheus→Node Exporter) rules are external
# aws_security_group_rule resources to avoid inline+external drift.
resource "aws_security_group" "monitoring" {
  name        = "${var.project_name}-${var.environment}-monitoring-sg"
  description = "Allow Grafana (3000) from ALB. Internal Prometheus and Node Exporter rules are external aws_security_group_rule resources."
  vpc_id      = var.vpc_id

  ingress {
    description     = "Grafana UI from ALB only"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Allow all outbound (AWS APIs for EC2 SD, EFS mounts, ECR image pulls)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    ignore_changes        = [ingress]
    create_before_destroy = true
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-monitoring-sg"
  })
}

resource "aws_security_group" "efs" {
  name        = "${var.project_name}-${var.environment}-efs-sg"
  description = "Allow NFS (2049) from ECS and monitoring tasks."
  vpc_id      = var.vpc_id

  ingress {
    description     = "NFS from ECS tasks"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  ingress {
    description     = "NFS from Prometheus and Grafana ECS tasks"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-efs-sg"
  })
}

# Allow monitoring SG → ECS SG on port 9100 so Prometheus can scrape Node Exporter.
resource "aws_security_group_rule" "ecs_allow_node_exporter" {
  type                     = "ingress"
  description              = "Node Exporter scraping from Prometheus ECS task"
  from_port                = 9100
  to_port                  = 9100
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.monitoring.id
  security_group_id        = aws_security_group.ecs.id
}

# Allow monitoring SG → ECS SG on port 80 so Prometheus can scrape the app /metrics endpoint.
resource "aws_security_group_rule" "ecs_allow_prometheus_scrape" {
  type                     = "ingress"
  description              = "App /metrics scraping from Prometheus ECS task"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.monitoring.id
  security_group_id        = aws_security_group.ecs.id
}

# Allow monitoring SG → self on port 9090 so the Grafana ECS task can reach the Prometheus datasource.
resource "aws_security_group_rule" "monitoring_grafana_to_prometheus" {
  type                     = "ingress"
  description              = "Prometheus API access from Grafana ECS task (intra-monitoring SG)"
  from_port                = 9090
  to_port                  = 9090
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.monitoring.id
  security_group_id        = aws_security_group.monitoring.id
}
