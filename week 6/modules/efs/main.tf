locals {
  default_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_efs_file_system" "main" {
  encrypted        = true
  kms_key_id       = var.kms_key_arn
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-efs"
  })
}

# UID 65534 (nobody) matches the user the official prom/prometheus image runs as.
resource "aws_efs_access_point" "prometheus" {
  file_system_id = aws_efs_file_system.main.id

  root_directory {
    path = "/prometheus"
    creation_info {
      owner_gid   = 65534
      owner_uid   = 65534
      permissions = "755"
    }
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-prometheus-ap"
  })
}

# UID 472 matches the user the official grafana/grafana image runs as.
resource "aws_efs_access_point" "grafana" {
  file_system_id = aws_efs_file_system.main.id

  root_directory {
    path = "/grafana"
    creation_info {
      owner_gid   = 472
      owner_uid   = 472
      permissions = "755"
    }
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-grafana-ap"
  })
}

resource "aws_efs_mount_target" "main" {
  count           = length(var.private_subnet_ids)
  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = var.private_subnet_ids[count.index]
  security_groups = [var.efs_sg_id]

  depends_on = [aws_efs_file_system.main]
}

resource "aws_efs_backup_policy" "main" {
  file_system_id = aws_efs_file_system.main.id

  backup_policy {
    status = "ENABLED"
  }
}

# DenyUnencryptedTransport is always present. AllowPrometheusMount and AllowGrafanaMount
# are injected only when the respective task role ARNs are provided — avoids a chicken-and-egg
# error on the first apply before the Prometheus/Grafana modules have created their task roles.
resource "aws_efs_file_system_policy" "main" {
  file_system_id = aws_efs_file_system.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid       = "DenyUnencryptedTransport"
          Effect    = "Deny"
          Principal = "*"
          Action    = "elasticfilesystem:*"
          Resource  = "*"
          Condition = {
            Bool = {
              "aws:SecureTransport" = "false"
            }
          }
        }
      ],
      var.prometheus_task_role_arn != "" ? [
        {
          Sid    = "AllowPrometheusMount"
          Effect = "Allow"
          Principal = {
            AWS = var.prometheus_task_role_arn
          }
          Action = [
            "elasticfilesystem:ClientMount",
            "elasticfilesystem:ClientWrite",
            "elasticfilesystem:ClientRootAccess"
          ]
          Resource = aws_efs_file_system.main.arn
          Condition = {
            StringEquals = {
              "elasticfilesystem:AccessPointArn" = aws_efs_access_point.prometheus.arn
            }
          }
        }
      ] : [],
      var.grafana_task_role_arn != "" ? [
        {
          Sid    = "AllowGrafanaMount"
          Effect = "Allow"
          Principal = {
            AWS = var.grafana_task_role_arn
          }
          Action = [
            "elasticfilesystem:ClientMount",
            "elasticfilesystem:ClientWrite"
          ]
          Resource = aws_efs_file_system.main.arn
          Condition = {
            StringEquals = {
              "elasticfilesystem:AccessPointArn" = aws_efs_access_point.grafana.arn
            }
          }
        }
      ] : []
    )
  })
}
