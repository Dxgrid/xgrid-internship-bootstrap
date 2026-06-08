# ECR Repositories for Temporal Order Management
# Two repositories: one for FastAPI service, one for Temporal Worker

resource "aws_ecr_repository" "api" {
  name                 = "${var.project_name}-api"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # allow `terraform destroy` to remove the repo even with images present

  image_scanning_configuration {
    scan_on_push = var.image_scan_enabled
  }

  tags = {
    Name        = "${var.project_name}-api"
    Environment = var.environment
  }
}

resource "aws_ecr_repository" "worker" {
  name                 = "${var.project_name}-worker"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # allow `terraform destroy` to remove the repo even with images present

  image_scanning_configuration {
    scan_on_push = var.image_scan_enabled
  }

  tags = {
    Name        = "${var.project_name}-worker"
    Environment = var.environment
  }
}

# Shared repository for the 5 dependency mock services (fraud, inventory, payment,
# shipping, notification). Each is pushed as a distinct tag in this single repo.
resource "aws_ecr_repository" "services" {
  name                 = "${var.project_name}-services"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # allow `terraform destroy` to remove the repo even with images present

  image_scanning_configuration {
    scan_on_push = var.image_scan_enabled
  }

  tags = {
    Name        = "${var.project_name}-services"
    Environment = var.environment
  }
}

# Lifecycle Policy — Keep only the latest 10 images (prevent storage bloat)
resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "worker" {
  repository = aws_ecr_repository.worker.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
