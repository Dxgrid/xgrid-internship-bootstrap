# ─── HANDS-OFF REBUILD BOOTSTRAP ─────────────────────────────────────────────
#
# `terraform destroy` + re-apply recreates all AWS resources but NOT the data that
# lives *inside* them. Three things are data, not Terraform resources, and so were
# lost on every rebuild and had to be restored by hand:
#
#   1. The PostgreSQL databases (`temporal`, `temporal_visibility`, `grafana`).
#      A fresh RDS only has the default `postgres` DB. The temporal-server (auto-setup
#      does schema, not DB creation) and Grafana both crash-loop with
#      `database "..." does not exist` until these exist.
#
#   2. The container images in ECR. `destroy` deletes the repos and every image with
#      them, so the API / worker / mock-service ECS tasks have nothing to pull (0 tasks).
#
# This file makes both reproducible so a rebuild is fully hands-off. The third item —
# the `OrderStatus` search attribute — is already handled by
# `null_resource.temporal_namespace_setup` inside the ecs-services module.
#
# Both resources run from an ACTIVE ECS container instance via SSM (RDS and the NLB
# live in private subnets and are unreachable from the machine running `terraform
# apply`). The image build/push runs locally (needs the Docker daemon + source tree).

# ─── 1. DATABASE BOOTSTRAP ───────────────────────────────────────────────────
# Creates the three databases on the fresh RDS. Idempotent: `CREATE DATABASE`
# failures (already-exists) are swallowed so re-apply is a no-op. Uses the public
# postgres:15 image purely as a psql client (already cached on the instances after
# the first run). Must complete before temporal-server / grafana start.
resource "null_resource" "db_bootstrap" {
  triggers = {
    # Re-run if the RDS instance is replaced (endpoint changes).
    rds_endpoint = module.rds_temporal.rds_endpoint
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      REGION="${var.aws_region}"
      CLUSTER="${module.ecs_cluster.cluster_id}"
      RDS="${module.rds_temporal.rds_endpoint}"
      DB_USER="${var.db_username}"
      DB_PASS='${local.db_password}'

      echo "Finding an active ECS container instance to run DB bootstrap from..."
      CI="None"; i=0
      until [ "$CI" != "None" ] && [ -n "$CI" ]; do
        i=$((i+1)); [ "$i" -gt 40 ] && { echo "Timed out waiting for ACTIVE container instance." >&2; exit 1; }
        CI=$(aws ecs list-container-instances --cluster "$CLUSTER" --status ACTIVE \
          --region "$REGION" --query 'containerInstanceArns[0]' --output text 2>/dev/null || echo "None")
        [ "$CI" = "None" ] && { echo "  none yet, waiting 15s..."; sleep 15; }
      done
      INSTANCE_ID=$(aws ecs describe-container-instances --cluster "$CLUSTER" \
        --container-instances "$CI" --region "$REGION" \
        --query 'containerInstances[0].ec2InstanceId' --output text)
      case "$INSTANCE_ID" in i-*) ;; *) echo "Bad instance id '$INSTANCE_ID'." >&2; exit 1 ;; esac

      echo "Creating databases on $RDS via SSM on $INSTANCE_ID..."
      PSQL="docker run --rm -e PGPASSWORD=\"$DB_PASS\" postgres:15 psql 'host=$RDS port=5432 user=$DB_USER dbname=postgres sslmode=require'"
      CMD_ID=$(aws ssm send-command --document-name "AWS-RunShellScript" \
        --instance-ids "$INSTANCE_ID" --region "$REGION" \
        --parameters "{\"commands\":[
          \"$PSQL -c 'CREATE DATABASE temporal;' 2>&1 || true\",
          \"$PSQL -c 'CREATE DATABASE temporal_visibility;' 2>&1 || true\",
          \"$PSQL -c 'CREATE DATABASE grafana;' 2>&1 || true\",
          \"echo db-bootstrap-done\"
        ]}" --query 'Command.CommandId' --output text)

      echo "Waiting for SSM command $CMD_ID..."
      j=0
      while true; do
        j=$((j+1))
        STATUS=$(aws ssm get-command-invocation --command-id "$CMD_ID" \
          --instance-id "$INSTANCE_ID" --region "$REGION" \
          --query 'Status' --output text 2>/dev/null || echo "Pending")
        case "$STATUS" in
          Success) echo "DB bootstrap complete."; break ;;
          Failed|Cancelled|TimedOut|DeliveryTimedOut)
            echo "SSM DB bootstrap $STATUS:" >&2
            aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
              --region "$REGION" --query 'StandardOutputContent' --output text >&2 || true
            exit 1 ;;
        esac
        [ "$j" -gt 30 ] && { echo "DB bootstrap still running after ~5m." >&2; exit 1; }
        sleep 10
      done
    EOT
  }

  depends_on = [module.ecs_cluster, module.rds_temporal]
}

# ─── 2. IMAGE BUILD & PUSH ───────────────────────────────────────────────────
# Builds and pushes all 7 application images to ECR. Runs locally (needs Docker).
# Lessons baked in from the manual rebuild:
#   - `--platform linux/amd64`: the ECS instances are amd64; a laptop default build
#     (e.g. arm64) produces an `exec format error` at task start.
#   - Sequential pushes: parallel `docker push` to the same registry was killed with
#     `connection reset by peer`; one-at-a-time is reliable.
#   - `buildx ... --push` builds and pushes in one step (avoids the multi-arch
#     manifest-list local image that plain `docker push` chokes on).
resource "null_resource" "image_build_push" {
  triggers = {
    # Rebuild whenever any source file under python/ or services/ changes.
    python_src   = sha1(join("", [for f in fileset("${path.module}/../../../python", "**") : filesha1("${path.module}/../../../python/${f}")]))
    services_src = sha1(join("", [for f in fileset("${path.module}/../../../services", "**") : filesha1("${path.module}/../../../services/${f}")]))
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      REGION="${var.aws_region}"
      REGISTRY="${element(split("/", module.ecr.api_repository_url), 0)}"
      API_URL="${module.ecr.api_repository_url}"
      WORKER_URL="${module.ecr.worker_repository_url}"
      SERVICES_URL="${module.ecr.services_repository_url}"
      PY="${path.module}/../../../python"
      SVC="${path.module}/../../../services"

      echo "Logging in to ECR $REGISTRY..."
      aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

      echo "Building + pushing API..."
      docker buildx build --platform linux/amd64 --push -t "$API_URL:latest" -f "$PY/Dockerfile.api" "$PY"

      echo "Building + pushing Worker..."
      docker buildx build --platform linux/amd64 --push -t "$WORKER_URL:latest" -f "$PY/Dockerfile.worker" "$PY"

      # tag = service dir name minus the _service suffix (fraud, inventory, ...)
      for d in fraud_service inventory_service notification_service payment_service shipping_service; do
        TAG="$${d%_service}"
        echo "Building + pushing $TAG..."
        docker buildx build --platform linux/amd64 --push -t "$SERVICES_URL:$TAG" "$SVC/$d"
      done

      echo "All images pushed."
    EOT
  }

  depends_on = [module.ecr]
}
