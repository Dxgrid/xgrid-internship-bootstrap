# Week 4 Terraform — Temporal Order Management Deployment Guide

## Overview

This Terraform deploys a complete 3-tier Temporal Order Management System on AWS:

- **Infrastructure**: VPC with public/private subnets (reuses Week 3 VPC module)
- **Compute**: Single ECS cluster with 4 services (Temporal Server, API, Worker, optional UI)
- **Database**: Separate PostgreSQL RDS for Temporal workflow history
- **Container Registry**: ECR repositories for API and Worker images
- **Load Balancing**: Internal NLB for Temporal gRPC (port 7233, TCP passthrough) + ALB for API (8000) and Temporal UI (8080)

---

## Architecture Decisions

### 1. **Relative Paths to Week 3 Modules** ✅
```hcl
source = "../../week\ 3/modules/vpc"
```
Calls Week 3 VPC module directly. No copying, no duplication.

### 2. **Single ECS Cluster** ✅
One cluster, multiple services (Temporal Server, API, Worker). Cost-efficient, same pattern as production systems.

### 3. **New ALB for Temporal** ✅
Separate from Week 3's WordPress ALB. Clean separation, easier to explain during demo.

### 4. **Separate RDS** ✅
New PostgreSQL instance isolated from Week 3 WordPress database. Temporal manages its own schema via `temporalio/auto-setup` container.

### 5. **Internal NLB for Temporal gRPC** ✅
ALB kills long-poll connections at the 60 s idle timeout → 502 Bad Gateway for Temporal Workers. The NLB operates at Layer 4 (TCP passthrough) with no timeout interference. Temporal Server registers with the NLB using a fixed `hostPort = 7233`; API and Worker resolve it via the NLB DNS name.

---

## File Structure

```
temporal-order-management-demo/terraform/
├── environments/
│   └── dev/
│       ├── main.tf                      ← Entry point (calls all modules)
│       ├── variables.tf                 ← Input variables
│       ├── outputs.tf                   ← Output values
│       ├── provider.tf                  ← AWS provider config
│       ├── backend.tf                   ← S3 backend config
│       └── terraform.tfvars.example     ← Example values
├── modules/
│   ├── security-groups/                 ← NEW: Extended SGs for Temporal
│   ├── alb-temporal/                    ← NEW: ALB for ports 8000 + 8080
│   ├── nlb-temporal/                    ← NEW: Internal NLB for gRPC port 7233
│   ├── ecs-cluster/                     ← NEW: EC2 cluster, ASG, capacity provider
│   ├── rds-temporal/                    ← NEW: PostgreSQL for Temporal
│   ├── secrets/                         ← NEW: Secrets Manager + KMS for DB creds
│   ├── ecr/                             ← NEW: ECR repos for images
│   ├── iam/                             ← NEW: ECS execution + task roles
│   └── ecs-services/                    ← NEW: 4 task definitions + services
└── scripts/
    └── create-remote-state.sh           ← Bootstrap S3 bucket + DynamoDB for backend
```

---

## Deployment Steps

### Prerequisites

1. **AWS Account** with appropriate permissions
2. **Terraform** >= 1.0 installed
3. **AWS CLI** v2 configured with credentials
4. **Docker** for building and pushing container images
5. **Week 3 deployed** (or at minimum, the VPC and ECS cluster exist)

### Step 1: Initialize Terraform

```bash
cd temporal-order-management-demo/terraform/environments/dev/

# Copy example variables
cp terraform.tfvars.example terraform.tfvars

# Edit with your values
nano terraform.tfvars
# Set: db_password, alert_email, other configs
```

### Step 2: Create S3 Backend for State (First Time Only)

`backend.tf` uses Terraform's native S3 locking (`use_lockfile = true`, requires Terraform >= 1.9) — no DynamoDB table needed. Terraform writes a `.tflock` file alongside the state using S3 conditional writes.

Run the bootstrap script once to create the S3 bucket:

```bash
cd temporal-order-management-demo/terraform/scripts
bash create-remote-state.sh
```

Or manually:

```bash
aws s3api create-bucket \
  --bucket temporal-order-terraform-state \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket temporal-order-terraform-state \
  --versioning-configuration Status=Enabled
```

### Step 3: Initialize Terraform

```bash
terraform init
```

### Step 4: Validate Configuration

```bash
terraform fmt -recursive     # Format all files
terraform validate          # Check syntax
```

### Step 5: Plan and Apply Infrastructure

```bash
# Plan (review changes)
terraform plan -out=tfplan

# Apply in phases (safer)
terraform apply -target=module.vpc
terraform apply -target=module.security_groups
terraform apply -target=module.ecs_cluster
terraform apply -target=module.rds_temporal
terraform apply -target=module.alb_temporal
terraform apply -target=module.ecr
terraform apply -target=module.iam

# Check outputs
terraform output -raw alb_temporal_dns_name
terraform output -raw api_ecr_repository_url
```

### Step 6: Build and Push Container Images

```bash
# Get ECR credentials
AWS_REGION=us-east-1
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Get image URLs from Terraform output
API_ECR=$(terraform output -raw api_ecr_repository_url)
WORKER_ECR=$(terraform output -raw worker_ecr_repository_url)

# Navigate to Python project
cd ../../python/

# Build and push API image
docker build -f Dockerfile -t $API_ECR:latest .
docker push $API_ECR:latest

# Build and push Worker image
docker build -f Dockerfile.worker -t $WORKER_ECR:latest .
docker push $WORKER_ECR:latest
```

**Note**: You'll need Dockerfile and Dockerfile.worker in the python/ directory. Example:

**Dockerfile** (API):
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY pyproject.toml .
RUN pip install -e .
COPY . .
CMD ["python", "-m", "uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

**Dockerfile.worker**:
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY pyproject.toml .
RUN pip install -e .
COPY . .
CMD ["python", "worker.py"]
```

### Step 7: Deploy ECS Services

```bash
terraform apply -target=module.ecs_services
```

Wait for tasks to become healthy:
```bash
aws ecs describe-services \
  --cluster temporal-order-dev-cluster \
  --services temporal-order-api temporal-order-worker \
  --query 'services[*].[serviceName,deployments[0].runningCount]'
```

### Step 7.5: Create OrderStatus Search Attribute

Temporal's custom search attributes must be registered before workflows can use them. The `OrderStatus` attribute is not in the Temporal Server default schema — create it once after the server is healthy.

The Temporal Server runs inside a private VPC. Use SSM Session Manager to port-forward from your local machine (no SSH key or bastion required — just the `AmazonSSMManagedInstanceCore` policy on the EC2 instance, which the ECS cluster module provisions automatically).

```bash
# 1. Find the running EC2 instance in the ECS ASG
EC2_ID=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:Project,Values=temporal-order" \
    "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)
echo "EC2 instance: $EC2_ID"

# 2. Terminal 1 — open SSM port-forward to Temporal gRPC
aws ssm start-session \
  --target "$EC2_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["7233"],"localPortNumber":["7233"]}'

# 3. Terminal 2 — register the search attribute (keep Terminal 1 open)
temporal operator search-attribute create \
  --address localhost:7233 \
  --namespace default \
  --name OrderStatus \
  --type Keyword
```

**Verify** the attribute was created:
```bash
temporal operator search-attribute list --address localhost:7233 --namespace default | grep OrderStatus
```

You should see `OrderStatus  Keyword` in the output. Close the SSM session in Terminal 1 when done.

### Step 8: Get Service URLs

```bash
# API URL
terraform output -raw api_url

# Temporal UI URL
terraform output -raw temporal_ui_url

# Example:
# API:       http://alb-12345.us-east-1.elb.amazonaws.com:8000
# Temporal UI: http://alb-12345.us-east-1.elb.amazonaws.com:8080
```

### Step 9: Test Health Checks

```bash
ALB_DNS=$(terraform output -raw alb_temporal_dns_name)

# API health
curl http://$ALB_DNS:8000/health

# Temporal Server (gRPC, so this won't work directly from CLI)
# But check CloudWatch logs to verify it's running
```

---

## Troubleshooting

### Temporal Server fails to start
**Problem**: `TEMPORAL_BROADCAST_ADDRESS` not set
**Solution**: The auto-setup container sets this dynamically. Check logs:
```bash
aws logs tail /ecs/temporal-order/dev/temporal-server --follow
```

### API can't reach Temporal Server
**Problem**: `TEMPORAL_ADDRESS` points to wrong host or NLB not reachable
**Solution**: The address is computed automatically from the internal NLB DNS name — no manual input required. Check the NLB target group health in the AWS Console (EC2 > Load Balancers > `temporal-order-dev-temporal-nlb`) and confirm the Temporal Server task is registered and healthy. Also verify the Temporal Server ECS service is running:
```bash
terraform output temporal_nlb_address
aws ecs describe-services \
  --cluster temporal-order-dev \
  --services temporal-order-temporal-server \
  --query 'services[0].deployments[0].{running:runningCount,desired:desiredCount}'
```

### Images don't exist in ECR
**Problem**: Tried to deploy without pushing images
**Solution**: Complete Step 6 (Build and Push Images) before Step 7

### ALB target group shows "unhealthy"
**Problem**: API health check failing
**Solution**: 
- Verify API task is running: `aws ecs describe-tasks --cluster ... --tasks ...`
- Check task logs: `aws logs tail /ecs/temporal-order/dev/api --follow`
- Ensure API connects to Temporal: Check `TEMPORAL_ADDRESS` env var

---

## Monitoring & Logs

### CloudWatch Logs

All services write to CloudWatch. View in real-time:

```bash
# Temporal Server
aws logs tail /ecs/temporal-order/dev/temporal-server --follow

# API
aws logs tail /ecs/temporal-order/dev/api --follow

# Worker
aws logs tail /ecs/temporal-order/dev/worker --follow
```

### CloudWatch Alarms

Alarms are created for:
- ALB unhealthy hosts
- ALB 5xx errors
- RDS CPU utilization
- RDS connections
- RDS free storage

View in AWS Console: **CloudWatch > Alarms**

---

## Cleanup

**Destroy all resources** (deletes everything):

```bash
terraform destroy
```

**Or destroy specific modules:**
```bash
terraform destroy -target=module.ecs_services
terraform destroy -target=module.alb_temporal
terraform destroy -target=module.rds_temporal
# ... then manual cleanup for other resources
```

---

## Demo Walkthrough (Friday)

1. **Show Terraform code** — Explain module reuse pattern
2. **Run `terraform output`** — Show ALB DNS, ECR URLs
3. **Curl API health check** — Prove API is responding
4. **Access Temporal UI** — http://[ALB_DNS]:8080
5. **Run test order** via API — Show workflow in Temporal UI
6. **Show CloudWatch logs** — Prove all services working together

---

## Next Steps

- Add HTTPS/TLS listener to ALB (requires certificate)
- Add API Gateway in front of ALB (optional)
- Scale API and Worker tasks using target tracking
- Add SNS notifications for deployment events
- Add monitoring dashboard (CloudWatch Dashboard)
