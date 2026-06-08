# Temporal on AWS: Week 4 Deployment Architecture — Deep Dive

**Date**: June 2, 2026  
**Project**: Temporal Order Management System  
**Deployment Model**: 3-tier AWS ECS on EC2 with PostgreSQL RDS backend

---

## Executive Summary

Week 4 deploys a **production-grade Temporal workflow engine** on AWS using Infrastructure-as-Code (Terraform). The system combines:

1. **Temporal Server** (single-node) — orchestrates workflows, manages state persistence
2. **PostgreSQL RDS** — stores workflow history and visibility data
3. **FastAPI Backend** — REST API for workflow submission and querying
4. **Python Worker** — executes workflow logic and activities
5. **Temporal UI** — web console for workflow monitoring

The architecture uses **9 Terraform modules** to decompose infrastructure concerns: networking, security, compute (ECS), databases, load balancing, and identity management. This enables repeatable, auditable deployments where infrastructure changes are versioned and reviewable.

---

## Part 1: Architectural Overview

### System Topology

```
┌─────────────────────────────────────────────────────────────────────┐
│                          INTERNET                                    │
│                     (External Users)                                 │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
        ┌──────────────────────────────────────┐
        │  Application Load Balancer (ALB)     │
        │  Internet-facing                      │
        │  :8000 → API  :8080 → Temporal UI   │
        └──────────┬───────────────────────────┘
                   │
        ┌──────────┴───────────────────────────────────────┐
        │         AWS VPC (10.0.0.0/16)                    │
        │     us-east-1a (10.0.3.0/24)                    │
        │     us-east-1b (10.0.4.0/24)                    │
        │                                                   │
        │  ┌─────────────────────────────────────┐         │
        │  │  ECS Cluster (EC2)                   │         │
        │  │  ASG: min=1, max=2                   │         │
        │  │                                       │         │
        │  │  ┌──────────────────────────────┐   │         │
        │  │  │ EC2 Instance 1 (us-east-1a)  │   │         │
        │  │  │ temporal-server (port 7233)  │   │         │
        │  │  │ temporal-ui (port dynamic)   │   │         │
        │  │  │ api (port dynamic)           │   │         │
        │  │  │ worker (no port)             │   │         │
        │  │  └──────────────────────────────┘   │         │
        │  │                                       │         │
        │  │  ┌──────────────────────────────┐   │         │
        │  │  │ EC2 Instance 2 (us-east-1b)  │   │         │
        │  │  │ api (port dynamic)           │   │         │
        │  │  │ worker (no port)             │   │         │
        │  │  └──────────────────────────────┘   │         │
        │  └─────────┬──────────────────────────┘         │
        │            │                                      │
        │  ┌─────────▼────────────────────────┐          │
        │  │  Internal NLB (TCP:7233)          │          │
        │  │  Routes gRPC traffic to           │          │
        │  │  Temporal Server (port 7233 host)│          │
        │  └─────────┬────────────────────────┘          │
        │            │                                      │
        │  ┌─────────▼────────────────────────┐          │
        │  │  RDS PostgreSQL 15               │          │
        │  │  Databases:                       │          │
        │  │  - temporal (event history)      │          │
        │  │  - temporal_visibility (search)  │          │
        │  │  - Backups: 7 days retention     │          │
        │  │  - Storage: 20 GB gp2 encrypted  │          │
        │  └────────────────────────────────┘          │
        │                                                   │
        └───────────────────────────────────────────────────┘

       ┌──────────────────────────────────────┐
       │  Secrets Manager (KMS-encrypted)     │
       │  Stores: RDS credentials              │
       └──────────────────────────────────────┘
```

### Key Architectural Decisions

#### 1. **Single-Node Temporal Server**
- Uses `temporalio/auto-setup:latest` container image
- All internal services (frontend, history, matching, worker) run in one process
- **Trade-off**: Simple deployment, easier testing; not suitable for high-availability production

#### 2. **Bridge Network Mode (Not Awsvpc)**
- Containers communicate via host network using NAT
- Temporal Server uses fixed `hostPort=7233` on the EC2 instance
- API/Worker/UI use dynamic `hostPort=0` (randomly assigned from ephemeral range 32768-65535)
- **Implications**: 
  - Security group rules must reference the ECS instance's security group (not individual container IPs)
  - Only one Temporal Server can run per EC2 instance
  - Traffic originating from containers appears to come from the host IP

#### 3. **Internal NLB for gRPC**
- **Problem solved**: ALB kills idle connections after 60 seconds → Temporal workers polling for tasks disconnect and reconnect constantly
- **Solution**: Use Network Load Balancer (Layer 4, TCP passthrough) with no timeout interference
- **Mechanics**: NLB routes traffic to Temporal Server via instance target type on fixed port 7233
- **Cost**: ~$16/month for NLB + $0.006/LCU (minimal traffic volume)

#### 4. **ALB for HTTP Services**
- Routes :8000 to API tasks (multiple instances across AZs)
- Routes :8080 to Temporal UI tasks
- Uses dynamic port registration via ECS service integration
- Health checks every 30 seconds with 3 retries before marking unhealthy

#### 5. **PostgreSQL over MySQL**
- **Why PostgreSQL**: Temporal's advanced visibility uses PostgreSQL-specific features:
  - `ILIKE` for case-insensitive search attribute filtering
  - `jsonb` operators for complex queries
  - Better performance for the `temporal_visibility` database (search index)
- **MySQL limitation**: Can store event history but cannot run visibility queries
- **Version**: PostgreSQL 15.17 (latest 15 branch)

---

## Part 2: The Workflow Execution Flow

### Order Workflow Lifecycle (End-to-End)

Understanding how a single order progresses through the system illustrates the integration of Temporal, ECS, and databases:

```
USER ACTION (Browser)
       │
       ▼
[API Task] POST /orders
       │
       ├─→ Validate OrderInput (pydantic model)
       │
       ├─→ Create Temporal Client
       │   client = Client(target_host=TEMPORAL_ADDRESS:7233)
       │           ↓
       │   [NLB routes to EC2 instance port 7233]
       │           ↓
       │   [Temporal Server on instance receives]
       │
       ├─→ Start Workflow
       │   workflow_id = f"order-{order_id}"
       │   handle = await client.start_workflow(
       │       OrderWorkflow.run,
       │       OrderInput(...),
       │       id=workflow_id,
       │       task_queue="order-task-queue"
       │   )
       │           ↓
       │   Temporal Server writes to RDS:
       │   - Workflow execution history event
       │   - Pending task (for Worker to poll)
       │   - Search attributes (OrderStatus=PENDING)
       │
       ├─→ Return workflow_id to client
       │
       └─→ [API Response: 200 OK, workflow_id]

WORKER POLLING (Background)
       │
       ├─→ [Worker Task] connects to Temporal Server port 7233
       │   worker = Worker(
       │       client,
       │       task_queue="order-task-queue"
       │   )
       │   await worker.run()
       │           ↓
       │   Worker makes long-poll gRPC call:
       │   PollWorkflowTaskQueueRequest() → NLB → port 7233 → Server
       │
       ├─→ Temporal Server sees pending task, sends back:
       │   WorkflowTask {
       │       workflow_id: "order-12345",
       │       history: [event1, event2, ...],
       │       pending_decisions: [...]
       │   }
       │
       ├─→ Worker reconstructs workflow state by replaying history
       │   - Replays all events from RDS
       │   - Executes Workflow.run() deterministically
       │   - Reaches decision point (next activity)
       │
       ├─→ Worker returns WorkflowTaskCompleted with decisions:
       │   [ScheduleActivityTask(check_fraud)]
       │
       ├─→ Temporal Server persists new events to RDS
       │   Inserts into history table:
       │   - WorkflowTaskStarted
       │   - WorkflowTaskCompleted
       │   - ActivityTaskScheduled
       │
       └─→ Worker immediately polls again (loop continues)

WORKFLOW EXECUTION (First Activity)
       │
       ├─→ Worker receives ActivityTask for check_fraud
       │
       ├─→ Worker executes activity:
       │   result = await check_fraud(order)
       │   # Makes HTTP call to fraud service
       │   # (simulated or real service)
       │
       ├─→ Worker returns ActivityTaskCompleted with result
       │
       ├─→ Temporal Server persists to RDS, schedules next activity
       │
       └─→ [Loop continues through workflow steps]

HUMAN-IN-THE-LOOP (Pause Point)
       │
       ├─→ Workflow reaches AWAITING_VALIDATION step
       │   workflow.wait_condition(lambda: self._proceed, timeout=1hr)
       │
       ├─→ Worker polls, gets WorkflowTask with:
       │   history_events: [... AWAITING_VALIDATION decision ...]
       │
       ├─→ Worker executes Workflow.run(), reaches wait_condition()
       │   → Cannot proceed (condition false, timeout not exceeded)
       │   → Returns no decisions (stalls gracefully)
       │
       ├─→ Worker continues polling (waiting for signal)
       │
       ├─→ [Operator/API] sends proceed_to_payment signal
       │   client.signal_workflow(
       │       workflow_id=order_id,
       │       signal_name="proceed_to_payment"
       │   )
       │
       ├─→ Temporal Server stores signal in RDS
       │   Updates workflow's signal queue
       │
       ├─→ Worker's next poll returns updated WorkflowTask with signal
       │
       ├─→ Worker replays history again, reaches wait_condition()
       │   condition evaluates true (signal received)
       │   Workflow continues to CHARGING step
       │
       └─→ [Loop continues until completion or failure]

WORKFLOW COMPLETION
       │
       ├─→ Workflow executes all steps
       │   - Fraud check ✓
       │   - Prepare shipment ✓
       │   - Human approval (signal received) ✓
       │   - Charge customer (4 retries, eventually succeeds) ✓
       │   - Ship items (parallel child workflows) ✓
       │   - Send notification ✓
       │
       ├─→ Workflow.run() returns OrderOutput
       │
       ├─→ Temporal Server persists completion to RDS:
       │   INSERT INTO workflow_execution:
       │   - status = 'COMPLETED'
       │   - close_time = now()
       │   - result = <serialized OrderOutput>
       │
       ├─→ Worker receives no more tasks for this workflow
       │
       ├─→ [API query endpoint] can retrieve result:
       │   client.get_workflow_handle(workflow_id).result()
       │   → Reads from RDS, returns OrderOutput
       │
       └─→ Browser polling UI updates to show COMPLETED

FAILURE & COMPENSATION (If Cancelled)
       │
       ├─→ API receives cancel_order signal at any step
       │   client.signal_workflow(
       │       workflow_id,
       │       signal_name="cancel_order"
       │   )
       │
       ├─→ Workflow's next poll receives cancel signal
       │
       ├─→ Workflow.run() checks cancel condition, triggers early exit
       │   return await self._early_exit()
       │
       ├─→ _early_exit() executes compensations in LIFO order
       │   if refund already charged:
       │     await refund_customer(order)
       │   if inventory already reserved:
       │     await revert_inventory(order)
       │
       ├─→ Each compensation is an activity task
       │   Persisted to RDS as compensation activities
       │
       ├─→ Workflow completes with status=CANCELLED
       │
       └─→ Eventual consistency: All side effects rolled back
```

### State Persistence to RDS

Every meaningful workflow event is persisted to PostgreSQL. The Temporal Server writes synchronously to RDS before acknowledging receipt to the worker:

**Workflow History Table** (`workflow_execution_history`):
```sql
INSERT INTO workflow_execution_history (
    workflow_id,
    event_id,
    event_type,      -- WorkflowExecutionStarted, ActivityTaskScheduled, etc.
    event_time,
    attributes       -- JSON payload with event-specific data
) VALUES (
    'order-12345',
    1,
    'WorkflowExecutionStarted',
    '2026-06-02 10:30:00',
    '{"input": {...}, "workflow_type": "OrderWorkflow"}'
);
```

**Visibility Table** (`workflow_execution_visibility`):
```sql
INSERT INTO workflow_execution_visibility (
    workflow_id,
    namespace,
    status,
    start_time,
    close_time,
    search_attributes  -- JSONB: {"OrderStatus": "PREPARING_SHIPMENT"}
) VALUES (
    'order-12345',
    'default',
    'RUNNING',
    '2026-06-02 10:30:00',
    NULL,
    '{"OrderStatus": "PREPARING_SHIPMENT"}'
);
```

When searching workflows via API or UI, Temporal queries the visibility table using PostgreSQL's JSONB operators:
```sql
SELECT * FROM workflow_execution_visibility
WHERE search_attributes @> '{"OrderStatus": "PREPARING_SHIPMENT"}'
AND status = 'RUNNING'
ORDER BY start_time DESC;
```

---

## Part 3: Infrastructure Modules in Detail

### Module 1: VPC (Reused from Week 3)

```hcl
module "vpc" {
  source = "../../week\ 3/modules/vpc"
  
  environment = var.environment
  region      = var.region
}

# Outputs:
# vpc_id
# private_subnet_ids (2 subnets across 2 AZs)
# public_subnet_ids (2 subnets across 2 AZs)
# nat_gateway_ip (for outbound traffic from private subnets)
```

**Structure**:
- VPC: 10.0.0.0/16
- Public subnets: 10.0.1.0/24 (us-east-1a), 10.0.2.0/24 (us-east-1b)
- Private subnets: 10.0.3.0/24 (us-east-1a), 10.0.4.0/24 (us-east-1b)
- NAT Gateway in public subnet → allows private instances outbound internet access

**Purpose**: ECS instances, RDS, and NLB live in private subnets. NAT Gateway allows them to pull container images from ECR and talk to external services while remaining unreachable from the internet.

---

### Module 2: Security Groups (Network Microwalls)

```hcl
module "security_groups" {
  source = "./modules/security-groups"
  
  vpc_id = module.vpc.vpc_id
  # Creates 6 security groups:
  # - alb_sg: Internet-facing load balancer
  # - nlb_sg: Internal network load balancer
  # - ecs_instance_sg: EC2 instances in ECS cluster
  # - temporal_server_sg: Temporal Server container
  # - api_sg: API container
  # - worker_sg: Worker container
  # - rds_sg: PostgreSQL RDS
}
```

**Security Group Rules** (abbreviated):

```
ALB SG:
  Inbound:
    - TCP:8000 from 0.0.0.0/0 (allow external API requests)
    - TCP:8080 from 0.0.0.0/0 (allow external UI access)
  Outbound:
    - TCP:* to ECS Instance SG (route to API/UI tasks)

NLB SG:
  Inbound:
    - TCP:7233 from ECS Instance SG (allow workers to connect)
  Outbound:
    - TCP:7233 to ECS Instance SG (route to Temporal Server)

ECS Instance SG:
  Inbound:
    - TCP:32768-65535 from ALB SG (dynamic port range for API/UI)
    - TCP:7233 from NLB SG (Temporal Server gRPC)
    - TCP:22 from VPN/Jump host (SSH, if needed)
  Outbound:
    - TCP:5432 to RDS SG (database access)
    - TCP:443 to 0.0.0.0/0 (ECR image pulls, external APIs)

RDS SG:
  Inbound:
    - TCP:5432 from ECS Instance SG (only containers can access DB)
  Outbound:
    - (None, RDS is read/write sink)
```

**Key Design**: Traffic flows from ALB → ECS instances → RDS. Circular traffic blocked (defense in depth). External users cannot directly reach EC2 or RDS.

---

### Module 3: ECS Cluster (Compute Foundation)

```hcl
module "ecs_cluster" {
  source = "./modules/ecs-cluster"
  
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  ecs_instance_sg_id  = module.security_groups.ecs_instance_sg_id
  
  min_instances       = 1
  max_instances       = 2
  instance_type       = "t3.medium"
}

# Creates:
# - ECS Cluster
# - EC2 Launch Template (with ECS agent)
# - Auto Scaling Group (1-2 instances)
# - Capacity Provider (links ASG to ECS)
```

**Instance Configuration**:
```
EC2 t3.medium:
  - 2 vCPU
  - 4 GB RAM
  - ECS agent running (containerized)
  - Docker Engine running
  - CloudWatch logs agent
  - 100 GB root volume (gp2)
  - Launched in private subnets (across 2 AZs for fault tolerance)
```

**Capacity Provider**:
- Links ASG capacity to ECS managed scaling
- When CPU/memory on instances reaches threshold, ASG scales up
- Prevents task placement failures due to insufficient capacity

**ASG Scaling**:
- **Min**: 1 instance (always running)
- **Max**: 2 instances (can scale up if needed)
- Uses **capacity-based scaling**: if tasks have unmet CPU/memory requirements, scale up

---

### Module 4: RDS PostgreSQL (Persistent State)

```hcl
module "rds_temporal" {
  source = "./modules/rds-temporal"
  
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  rds_sg_id          = module.security_groups.rds_sg_id
  db_password        = var.db_password  # From tfvars
}

resource "aws_db_instance" "temporal" {
  identifier        = "temporal-order-dev-temporal-db"
  engine            = "postgres"
  engine_version    = "15.17"
  instance_class    = "db.t3.micro"  # 1 vCPU, 1 GB RAM
  allocated_storage = 20             # GB, gp2 (burst-capable SSD)
  storage_encrypted = true           # KMS-encrypted at rest
  
  username = var.db_username
  password = var.db_password         # INJECTED, not in state file
  
  db_subnet_group_name   = aws_db_subnet_group.temporal.name
  vpc_security_group_ids = [var.rds_sg_id]
  publicly_accessible    = false     # Private subnets only
  multi_az               = false     # Single AZ for dev (set true in prod)
  
  backup_retention_period = 7        # 7-day backup window
  enabled_cloudwatch_logs_exports = ["postgresql"]
  monitoring_interval     = 60       # Performance Insights every 60s
  parameter_group_name    = aws_db_parameter_group.temporal.name
  skip_final_snapshot     = false    # Create snapshot on destroy
}
```

**Two Databases Inside One RDS Instance**:

1. **`temporal`** — Event History & State
   - Stores all workflow execution histories
   - Stores pending tasks for workers to poll
   - Stores namespace configuration
   - Table: `workflow_execution_history` (primary)
   - Table: `workflow_execution` (current state)
   - Table: `task_queue` (pending tasks)
   - Typical size: Grows ~10-50 KB per workflow (depending on duration/activity count)

2. **`temporal_visibility`** — Search Index
   - Stores indexed search attributes (OrderStatus, customer_id, etc.)
   - Enables `temporal workflow list --query "OrderStatus=PREPARING_SHIPMENT"`
   - Uses PostgreSQL JSONB column for search attribute storage
   - Query performance: typically <100ms for 10k workflows

**Schema Creation** (Idempotent Bootstrap):
```bash
# Runs as ECS one-shot task before services start
PGPASSWORD="$POSTGRES_PWD" psql \
  "host=$POSTGRES_SEEDS port=5432 user=$POSTGRES_USER dbname=postgres sslmode=require" \
  -c "CREATE DATABASE temporal;" || true
```

The `|| true` prevents failure if databases already exist (idempotent).

**Backup Strategy**:
- Automated snapshots: 7-day retention
- Point-in-time recovery: up to 7 days
- Restore process: AWS RDS console → "Restore to Point in Time" → new instance
- **Cost**: ~$5/month for 20GB storage + backup increments

---

### Module 5: Secrets Manager + KMS (Credential Security)

```hcl
module "secrets" {
  source = "./modules/secrets"
  
  rds_username = var.db_username
  rds_password = var.db_password
}

# Creates:
# - KMS Customer Master Key (CMK) for encryption
# - Secrets Manager secret containing RDS credentials
# - Output: secret ARN for IAM role permissions
```

**Secret Structure** (in Secrets Manager):
```json
{
  "username": "temporal_admin",
  "password": "AbCd1234!XyZ"
}
```

**Encryption**:
- At-rest: AES-256 encrypted with KMS CMK
- In-transit: TLS when retrieved via AWS SDK
- Rotation: Manual (set up in production)

**Access Pattern** (from ECS Task):
```python
# Inside container
import boto3
secret_client = boto3.client('secretsmanager')
response = secret_client.get_secret_value(SecretId='temporal-db-secret')
credentials = json.loads(response['SecretString'])
password = credentials['password']
```

Requires IAM execution role permission:
```json
{
  "Effect": "Allow",
  "Action": ["secretsmanager:GetSecretValue"],
  "Resource": ["arn:aws:secretsmanager:*:*:secret:temporal-*"]
}
```

---

### Module 6: IAM Roles (Task Permissions)

```hcl
module "iam" {
  source = "./modules/iam"
  
  project_name         = var.project_name
  db_secret_arn        = module.secrets.secret_arn
  ecr_api_repo_arn     = module.ecr.api_repo_arn
  ecr_worker_repo_arn  = module.ecr.worker_repo_arn
}

# Creates:
# - ECS Execution Role (for container startup)
# - ECS Task Role (permissions inside container)
```

**Execution Role** (EC2 → ECS Agent):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": ["arn:aws:secretsmanager:*:*:secret:temporal-*"]
    }
  ]
}
```

Allows EC2 instance to:
- Pull images from ECR
- Create CloudWatch log groups/streams
- Fetch RDS password from Secrets Manager

**Task Role** (Inside Container):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["cloudwatch:PutMetricData"],
      "Resource": "*"
    }
  ]
}
```

Allows container processes to:
- Emit custom CloudWatch metrics
- (Extensible for additional permissions like S3 for backups, SNS for alerts, etc.)

---

### Module 7: ECR (Container Image Registry)

```hcl
module "ecr" {
  source = "./modules/ecr"
  
  project_name = var.project_name
}

# Creates:
# - ECR repository: temporal-order-api
# - ECR repository: temporal-order-worker
# - Lifecycle policies: keep last 10 images, delete untagged after 30 days
```

**Image Build & Push Workflow**:

```bash
# Step 1: Build API image
cd week\ 4/python/api
docker build -t temporal-order-api:latest .

# Step 2: Tag for ECR
docker tag temporal-order-api:latest \
  432500708329.dkr.ecr.us-east-1.amazonaws.com/temporal-order-api:latest

# Step 3: Authenticate Docker
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  432500708329.dkr.ecr.us-east-1.amazonaws.com

# Step 4: Push
docker push 432500708329.dkr.ecr.us-east-1.amazonaws.com/temporal-order-api:latest
```

**Deployment**:
After push, redeploy ECS service:
```bash
aws ecs update-service \
  --cluster temporal-order-cluster \
  --service temporal-order-api \
  --force-new-deployment
```

ECS pulls new `:latest` tag, stops old tasks, launches new ones (rolling deployment).

---

### Module 8: NLB for Temporal (gRPC Passthrough)

```hcl
module "nlb_temporal" {
  source = "./modules/nlb-temporal"
  
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  nlb_sg_id          = module.security_groups.nlb_sg_id
  ecs_instance_sg_id = module.security_groups.ecs_instance_sg_id
}

# Creates:
# - Network Load Balancer (Layer 4, TCP)
# - Target Group (TCP:7233, instance targets)
# - Listener (TCP:7233 → Target Group)
# - No health checks (allows Temporal internal health logic)
```

**Why NLB Instead of ALB?**

| Aspect | ALB | NLB |
|--------|-----|-----|
| **Layer** | Layer 7 (HTTP/HTTPS) | Layer 4 (TCP/UDP) |
| **Idle Timeout** | **60 seconds** ❌ | Configurable (default unlimited) ✓ |
| **Protocol Support** | HTTP, HTTPS, gRPC (with h2c) | TCP, UDP, TLS, QUIC |
| **Connection Handling** | Terminates, re-opens | Passthrough (transparent) |
| **Use Case** | Request-response APIs | Long-polling, streaming |

**Problem with ALB**:
```
Worker → ALB → Temporal Server
  │
  └─ Make long-poll request
     gRPC connection stays open (waiting for task)
     
After 60s of no data:
     ALB's idle timeout fires
     ALB closes connection (502 Bad Gateway to worker)
     Worker crashes ❌
```

**Solution with NLB**:
```
Worker → NLB → Temporal Server
  │
  └─ Make long-poll request
     NLB routes packets transparently
     Connection stays open indefinitely (TCP passthrough)
     When task arrives, data flows immediately ✓
```

**Target Group Configuration**:
```hcl
resource "aws_lb_target_group" "temporal_grpc" {
  name        = "temporal-grpc"
  port        = 7233
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"  # Not lambda, not ip
  
  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
    timeout             = 10
    port                = "7233"
    protocol            = "TCP"
  }
}
```

**Instance Targets**:
```
Target 1: EC2 instance (i-0123456789abcdef0) port 7233
  ↓
ECS bridge networking on host
  ↓
Container port 7233 mapped to hostPort 7233
  ↓
Temporal Server inside container listening on 7233
```

The NLB DNS name: `temporal-nlb-1234567890.us-east-1.elb.amazonaws.com:7233`

API and Worker clients connect to:
```
TEMPORAL_ADDRESS=temporal-nlb-1234567890.us-east-1.elb.amazonaws.com:7233
```

---

### Module 9: ALB for HTTP (API & UI)

```hcl
module "alb_temporal" {
  source = "./modules/alb-temporal"
  
  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  alb_sg_id          = module.security_groups.alb_sg_id
  ecs_instance_sg_id = module.security_groups.ecs_instance_sg_id
}

# Creates:
# - Application Load Balancer (internet-facing)
# - Target Group 1: :8000 → API tasks
# - Target Group 2: :8080 → Temporal UI tasks
# - Listener (HTTP:80) + Host-based routing (future: HTTPS)
```

**Traffic Flow**:

```
Internet User
  │
  ▼ (HTTP GET /orders)
ALB (0.0.0.0:80)
  │
  ├─ Host header = api.temporal.internal? → Target Group 8000
  │                 ▼
  │           Register targets from ECS service:
  │           - EC2 instance (i-xxx) port 32890 (dynamic)
  │           - EC2 instance (i-yyy) port 32891 (dynamic)
  │                 ▼
  │           Pick one, forward request
  │           ▼
  │           [API Container] (FastAPI)
  │           └─ 200 OK, JSON response
  │
  └─ Path = /temporal/? → Target Group 8080
                ▼
          Register targets from ECS service:
          - EC2 instance (i-xxx) port 32900 (dynamic)
                ▼
          [Temporal UI Container] (React)
          └─ 200 OK, HTML/CSS/JS
```

**Dynamic Port Registration**:
After ECS service launches a new task (e.g., API container on host port 32890), the service automatically registers that port with ALB's target group. ALB immediately starts routing traffic there.

**Health Checks**:
```
ALB health check every 30 seconds:
  GET http://EC2-instance:dynamic-port/health
  
If API returns 200 → Healthy ✓
If no 200 within 10 seconds or 3 consecutive failures → Unhealthy ✗
  (task is removed from load balancer, left to be replaced)
```

---

## Part 4: ECS Services in Detail

### Task Definition — Temporal Server

```hcl
resource "aws_ecs_task_definition" "temporal_server" {
  family                   = "temporal-order-temporal-server"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([{
    name           = "temporal-server"
    image          = "temporalio/auto-setup:latest"
    memory         = 512
    cpu            = 256
    essential      = true
    interactive    = false
    pseudoTerminal = false

    portMappings = [{
      containerPort = 7233
      hostPort      = 7233
      protocol      = "tcp"
    }]

    environment = [
      { name = "DB",                             value = "postgres12" },
      { name = "DB_PORT",                        value = "5432" },
      { name = "POSTGRES_USER",                  value = "temporal_admin" },
      { name = "POSTGRES_SEEDS",                 value = "temporal-order-dev-temporal-db.xxxxx.us-east-1.rds.amazonaws.com" },
      { name = "SKIP_DB_CREATE",                 value = "true" },
      { name = "BIND_ON_IP",                     value = "0.0.0.0" },
      { name = "TEMPORAL_BROADCAST_ADDRESS",     value = "127.0.0.1" },
      { name = "POSTGRES_TLS_ENABLED",           value = "true" },
      { name = "POSTGRES_TLS_DISABLE_HOST_VERIFICATION", value = "true" },
    ]

    secrets = [{
      name      = "POSTGRES_PWD"
      valueFrom = "arn:aws:secretsmanager:us-east-1:432500708329:secret:temporal-db-secret-XXXXX:password::"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/temporal-order-temporal-server"
        "awslogs-region"        = "us-east-1"
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}
```

**Key Environment Variables Explained**:

- `DB = "postgres12"`: Driver identifier for PostgreSQL
- `POSTGRES_SEEDS`: RDS endpoint (auto-setup queries this to establish connection)
- `SKIP_DB_CREATE = "true"`: Don't auto-create databases (schema bootstrap task does this)
- `BIND_ON_IP = "0.0.0.0"`: Listen on all interfaces (critical!)
- `TEMPORAL_BROADCAST_ADDRESS = "127.0.0.1"`: Internal membership ring address (must be loopback for single-node)
- `POSTGRES_TLS_ENABLED = "true"`: Encrypt connection to RDS
- `POSTGRES_TLS_DISABLE_HOST_VERIFICATION = "true"`: Skip cert hostname verification (RDS cert may not match internal DNS name)

**Port Mapping**:
- `hostPort = 7233` (fixed, not dynamic 0)
  - Allows NLB to target specific port on EC2
  - Only one Temporal Server per EC2 host
  - If another task tries port 7233 on same host → **conflict**, task fails

**Logging**:
- CloudWatch log group: `/ecs/temporal-order-temporal-server`
- Log stream: `ecs/temporal-order-temporal-server/12345` (one per task)
- Logs persist 7 days (configurable retention)

**Service Configuration**:
```hcl
resource "aws_ecs_service" "temporal_server" {
  name            = "temporal-order-temporal-server"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.temporal_server.arn
  desired_count   = 1
  launch_type     = "EC2"
  
  deployment_configuration {
    maximum_percent         = 100  # Allow 1 old + 1 new simultaneously
    minimum_healthy_percent = 0    # Can go to 0 temporarily during deployment
  }
  
  load_balancer {
    target_group_arn = var.nlb_target_group_arn
    container_name   = "temporal-server"
    container_port   = 7233
  }
}
```

**Deployment Behavior**:
1. `desired_count = 1` means ECS always maintains exactly 1 running task
2. If task crashes/stops:
   - ECS detects it (health check failure or stopped event)
   - ECS launches replacement task
   - NLB updates target group to route to new task's port 7233
3. No rolling updates (always 1 instance, can't have > 1 at a time due to port conflict)

---

### Task Definition — API

```hcl
container_definitions = jsonencode([{
  name    = "api"
  image   = "${var.api_ecr_repository_url}:latest"
  memory  = 256
  cpu     = 256
  
  portMappings = [{
    containerPort = 8000
    hostPort      = 0      # Dynamic port assignment
    protocol      = "tcp"
  }]

  environment = [
    { name = "TEMPORAL_ADDRESS",    value = "temporal-nlb-1234567890.us-east-1.elb.amazonaws.com" },
    { name = "TEMPORAL_NAMESPACE",  value = "default" },
    { name = "TEMPORAL_TASK_QUEUE", value = "order-task-queue" },
    { name = "PORT",                value = "8000" }
  ]

  healthCheck = {
    command     = ["CMD-SHELL", "curl -f http://localhost:8000/health || exit 1"]
    interval    = 30
    timeout     = 5
    retries     = 3
    startPeriod = 15
  }
}])

# Service
resource "aws_ecs_service" "api" {
  desired_count = var.desired_api_count  # e.g., 2
  
  load_balancer {
    target_group_arn = var.alb_target_group_arn_8000
    container_name   = "api"
    container_port   = 8000
  }
}
```

**Key Differences from Temporal Server**:
- `hostPort = 0`: ECS picks a random port from ephemeral range (32768-65535)
- `desired_count = var.desired_api_count` (e.g., 2, 3): Can scale horizontally
- ALB target group automatically registers/deregisters tasks as they start/stop
- Health check every 30s via HTTP (not just TCP)

**Scaling Example**:
```
Deploy with desired_api_count = 2:
  Task 1: EC2 instance us-east-1a, container port 8000 → host port 32890
  Task 2: EC2 instance us-east-1b, container port 8000 → host port 32891
  
  ALB target group has 2 targets:
  - i-0xxx:32890 (50% traffic)
  - i-0yyy:32891 (50% traffic)

  User request → ALB → picks target (round-robin) → API response
  If one API task crashes:
    ECS detects health check failure
    ECS launches replacement task on same or different instance
    ALB updates target group
    No user impact (other API instance absorbs traffic)
```

---

### Task Definition — Worker

```hcl
container_definitions = jsonencode([{
  name   = "worker"
  image  = "${var.worker_ecr_repository_url}:latest"
  memory = 512
  cpu    = 256
  # No portMappings!
  
  environment = [
    { name = "TEMPORAL_ADDRESS",    value = "temporal-nlb-1234567890.us-east-1.elb.amazonaws.com" },
    { name = "TEMPORAL_NAMESPACE",  value = "default" },
    { name = "TEMPORAL_TASK_QUEUE", value = "order-task-queue" }
  ]
}])

# Service
resource "aws_ecs_service" "worker" {
  desired_count = var.desired_worker_count  # e.g., 1, 2, 3
  
  # No load_balancer block (worker doesn't serve requests)
}
```

**Why No Port Mapping?**
- Workers don't serve HTTP traffic
- They make **outbound** gRPC connections to Temporal Server only
- No health check endpoint
- No load balancer registration needed

**Worker Responsibility**:
1. Connect to Temporal Server (gRPC, port 7233)
2. Poll `order-task-queue` for pending workflows/activities
3. Execute workflow and activity code
4. Return completed tasks to server
5. Repeat (infinite loop until container stops)

**Scaling Workers**:
```bash
# Increase worker capacity
aws ecs update-service \
  --cluster temporal-order-cluster \
  --service temporal-order-worker \
  --desired-count 3

# Result:
# Task 1: Worker instance 1
# Task 2: Worker instance 2
# Task 3: Worker instance 1 (or 2, depending on capacity)

# All 3 connect to same Temporal Server
# Server distributes tasks among them (load balancing via gRPC)
```

**Memory Allocation**:
- Worker: 512 MB (vs. API: 256 MB)
- **Why**: Workflow replay reconstructs in-memory state by replaying entire event history
- Long-running workflows with 1000+ events need more RAM to replay
- Activity buffers (reading files, processing images) also use memory

---

## Part 5: Deployment Workflow

### Step-by-Step Deployment

**Prerequisite**: AWS credentials configured, Terraform installed, Docker installed

**Step 1: Prepare Terraform Variables**

```bash
cd week\ 4/terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars

# Edit:
# db_password = "SecurePassword123!"
# alert_email = "ops@example.com"
# desired_api_count = 2
# desired_worker_count = 2
```

**Step 2: Initialize Terraform & Create S3 Backend** (One-time)

```bash
cd week\ 4/terraform/scripts
bash create-remote-state.sh

# Creates:
# - S3 bucket: temporal-order-tf-state-432500708329
# - .tflock locking mechanism (S3 conditional writes)
```

**Step 3: Bootstrap Terraform**

```bash
cd week\ 4/terraform/environments/dev
terraform init

# Downloads modules, initializes backend
```

**Step 4: Plan Infrastructure**

```bash
terraform plan

# Output: shows all resources to be created (50+ AWS resources)
# Review for correctness before applying
```

**Step 5: Apply Infrastructure**

```bash
terraform apply

# Execution order (automatic, via depends_on chains):
# 1. VPC + Subnets + NAT Gateway
# 2. Security Groups
# 3. ECS Cluster + Auto Scaling Group
# 4. RDS Instance (waiting for security groups, subnets)
# 5. Secrets Manager + KMS Key
# 6. IAM Roles (waiting for secrets)
# 7. Schema Bootstrap Task (waiting for RDS)
# 8. ECS Services (Temporal Server, API, Worker, UI)
# 9. Load Balancers (ALB, NLB)

# Time: ~10-15 minutes for full deployment
```

**Step 6: Build & Push Container Images**

```bash
# Authenticate ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  432500708329.dkr.ecr.us-east-1.amazonaws.com

# Build API
cd week\ 4/python/api
docker build -t temporal-order-api:latest .
docker tag temporal-order-api:latest \
  432500708329.dkr.ecr.us-east-1.amazonaws.com/temporal-order-api:latest
docker push 432500708329.dkr.ecr.us-east-1.amazonaws.com/temporal-order-api:latest

# Build Worker
cd ../worker
docker build -t temporal-order-worker:latest .
docker tag temporal-order-worker:latest \
  432500708329.dkr.ecr.us-east-1.amazonaws.com/temporal-order-worker:latest
docker push 432500708329.dkr.ecr.us-east-1.amazonaws.com/temporal-order-worker:latest

# Time: ~3-5 minutes (depends on internet speed)
```

**Step 7: Force ECS Services to Redeploy**

```bash
# Pull new images and update services
aws ecs update-service \
  --cluster temporal-order-cluster \
  --service temporal-order-temporal-server \
  --force-new-deployment

aws ecs update-service \
  --cluster temporal-order-cluster \
  --service temporal-order-api \
  --force-new-deployment

aws ecs update-service \
  --cluster temporal-order-cluster \
  --service temporal-order-worker \
  --force-new-deployment
```

**Step 8: Verify Deployment**

```bash
# Check ECS services
aws ecs list-services --cluster temporal-order-cluster
aws ecs describe-services --cluster temporal-order-cluster --services temporal-order-api

# Check ALB targets
aws elbv2 describe-target-health --target-group-arn arn:aws:elasticloadbalancing:...

# Check CloudWatch logs
aws logs tail /ecs/temporal-order-api --follow

# Access application
ALB_DNS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(DNSName, 'alb')].DNSName" --output text)
echo "http://$ALB_DNS:8000/orders"     # API
echo "http://$ALB_DNS:8080"             # Temporal UI
```

---

## Part 6: Operational Considerations

### Monitoring & Observability

**CloudWatch Logs**:
```
/ecs/temporal-order-temporal-server   → Temporal Server logs
/ecs/temporal-order-api               → API logs
/ecs/temporal-order-worker            → Worker logs
/ecs/temporal-order-temporal-ui       → Temporal UI logs
```

**CloudWatch Metrics** (from ECS):
- `AWS/ECS:DesiredTaskCount` — how many tasks should be running
- `AWS/ECS:RunningTaskCount` — how many actually are running
- `AWS/RDS:CPUUtilization` — database CPU usage
- `AWS/RDS:DatabaseConnections` — active DB connections

**Temporal UI** (Built-in Observability):
- Access: `http://{ALB-DNS}:8080`
- Features:
  - Workflow list (queryable by search attributes like `OrderStatus`)
  - Workflow execution history (events)
  - Activity retries/failures
  - Task queue size
  - Worker heartbeats

**Example Query** (CLI):
```bash
# List workflows in PREPARING_SHIPMENT state
temporal workflow list \
  --query "OrderStatus = 'PREPARING_SHIPMENT'" \
  --namespace default
```

### Scaling Strategies

**Horizontal Scaling (Add More Workers/API)**:

```bash
# More workers = more parallel workflow/activity execution
terraform apply -var="desired_worker_count=5"

# More API instances = higher REST API throughput
terraform apply -var="desired_api_count=4"

# ASG scales compute automatically based on capacity needs
```

**Vertical Scaling** (Larger instances):

```bash
# Change EC2 instance type
terraform apply -var="instance_type=t3.large"

# Triggers ASG to launch new instances, drain old ones
```

**Temporal Server Scaling** (Advanced):

The `temporalio/auto-setup:latest` image is single-node only. For high-availability multi-node clusters:
1. Switch to `temporalio/server:latest` (requires manual schema setup)
2. Deploy multiple Temporal Server tasks (configure internal membership)
3. Use multi-master PostgreSQL (Aurora, streaming replication)
4. Deploy behind NLB with multiple target ports

Not covered in Week 4 (single-node sufficient for demo).

### Failure Modes & Recovery

**Worker Crash**:
```
Worker task stops → ECS detects via health monitor
→ ECS launches replacement worker
→ Workflow execution stalls temporarily (no worker to pick up tasks)
→ New worker connects, picks up pending tasks, continues workflow
→ No data loss (history in RDS)
```

**API Task Crash**:
```
API task stops → ALB health check fails
→ ALB removes from target group
→ ECS launches replacement
→ Other API instances absorb traffic
→ No pending workflows lost (state in Temporal Server)
```

**Temporal Server Crash**:
```
Temporal Server stops → Worker connections drop
→ Workers reconnect immediately (exponential backoff)
→ ECS auto-restarts container
→ Server reads history from RDS (state fully recovered)
→ Workers resume polling same queue
→ No lost events (all history in RDS)
```

**RDS Connection Lost**:
```
Network partition → Temporal Server can't reach RDS
→ Server keeps running but can't persist new events
→ After 10 seconds timeout, server returns error to worker
→ Worker fails task with retryable error
→ When connectivity restored, worker retries
→ Server syncs with RDS, continues workflow
```

**Data Persistence**:
- All workflow state in RDS (replicated, 7-day backups)
- No state in EC2 containers (stateless design)
- RDS failure = restore from backup (restore to point-in-time, launch new instance)

### Cost Analysis

**Monthly Costs** (US East 1, dev environment):

| Component | Config | Cost |
|-----------|--------|------|
| **EC2** | t3.medium, 1 instance running | ~$20 |
| **RDS** | db.t3.micro, 20 GB gp2, 7-day backups | ~$25 |
| **ALB** | 1 load balancer, minimal traffic | ~$16 |
| **NLB** | 1 load balancer, minimal traffic | ~$16 |
| **NAT Gateway** | 1 NAT gateway, ~1 GB data | ~$5 |
| **ECR** | 2 repositories, 100 MB storage | <$1 |
| **CloudWatch** | Logs + metrics + alarms | ~$5 |
| **Secrets Manager** | 1 secret | <$1 |
| **KMS** | 1 CMK + API calls | ~$1 |
| **S3 Backend** | Terraform state storage | <$1 |
| **Total** | | **~$90/month** |

**Cost Optimization Tips**:
- Use single ALB for both API & UI (combine target groups)
- Use RDS reserved instances (33% savings for 1-year commitment)
- Use ec2-spot-instances for workers (70% savings, acceptable interruption risk)
- Consolidate logs to 30-day retention (CloudWatch storage ~$0.50/GB)

---

## Part 7: Advanced Topics

### Workflow Replay & Determinism

**How Replay Works**:
```
Worker receives WorkflowTask for order-12345:

history_events = [
  Event 1: WorkflowExecutionStarted
  Event 2: ActivityTaskScheduled (check_fraud)
  Event 3: ActivityTaskCompleted (result = {"fraud": false})
  Event 4: ActivityTaskScheduled (prepare_shipment)
  Event 5: ActivityTaskCompleted (result = {...})
  Event 6: TimerStarted (wait_condition, timeout 1hr)
  (STALLED HERE: waiting for signal)
]

Worker executes Workflow.run():

  await check_fraud() → gets result from Event 3 (no re-execution)
  await prepare_shipment() → gets result from Event 5 (no re-execution)
  await workflow.wait_condition() → checks Event 6 status
    condition = (self._proceed or self._cancelled)
    condition is false, no signal received yet
    → returns immediately (stalls gracefully)

Worker returns no new decisions (waiting)

Next poll (30s later):
  If signal received:
    history_events has new event: Signal received
    Worker replays again
    Condition now true
    Workflow continues

Determinism Rule: Any non-deterministic code breaks replay
  ❌ Bad: if random.random() > 0.5: ...  (different on replay)
  ✓ Good: use workflow context for decisions, fixed logic
```

This enables **workflow versioning** (running old workflow code on new history) — advanced use case.

### Search Attributes & Visibility

**Custom Search Attributes**:

```python
# In workflow
ORDER_STATUS_KEY = SearchAttributeKey.for_keyword("OrderStatus")

workflow.upsert_search_attributes([
    ORDER_STATUS_KEY.value_set("PREPARING_SHIPMENT")
])

# In database (visibility table)
INSERT INTO workflow_execution_visibility (
    workflow_id,
    search_attributes  -- JSONB column
) VALUES (
    'order-12345',
    '{"OrderStatus": "PREPARING_SHIPMENT"}'
);

# Query (CLI)
temporal workflow list --query "OrderStatus = 'PREPARING_SHIPMENT'"
  # Uses PostgreSQL: WHERE search_attributes @> '{"OrderStatus": "PREPARING_SHIPMENT"}'
```

**Performance**: JSONB index on search_attributes column enables O(log n) queries on 10k+ workflows.

### Multi-Region Deployment

Future enhancement (not Week 4):
```
US East (Primary)         EU West (DR)
  VPC                       VPC
  ├─ ECS                    ├─ ECS
  ├─ RDS Master             └─ RDS Read Replica
  └─ ALB/NLB                   (async replication)

Global Route 53 DNS failover:
  healthy → us-east ALB
  unhealthy → eu-west ALB
```

---

## Conclusion

Week 4's Temporal deployment demonstrates **enterprise-grade infrastructure design**:

1. **Modularity**: 9 independent Terraform modules, each handles one concern
2. **Resilience**: Automatic restart, health checks, multi-AZ readiness
3. **Observability**: CloudWatch logs, Temporal UI, query-able workflow history
4. **Determinism**: Workflow replay enables durability across failures
5. **State Persistence**: PostgreSQL backend ensures no data loss

The architecture is **production-ready** with minor enhancements:
- Add HTTPS (ACM + ALB listener)
- Add monitoring alerts (CloudWatch alarms → SNS → email)
- Add multi-region DR (Route 53 + RDS read replicas)
- Scale Temporal Server to multi-node (requires manual config)
- Implement auto-scaling policies (CPU > 70% → scale workers)

This deep dive shows how Temporal's durable execution model integrates seamlessly with AWS infrastructure, providing a foundation for complex, long-running workflows with automatic recovery and observability built-in.

