# Infrastructure Comparison: Week 3 (WordPress HA) vs Temporal Order Management

Both projects run containerized workloads on AWS ECS EC2 inside a private VPC. They share the same foundational AWS building blocks but make different architectural choices at almost every layer above the foundation — each choice driven by the nature of the workload.

---

## What They Share

| Area | Both Projects |
|---|---|
| Compute | ECS on EC2 (not Fargate), capacity provider with managed scaling |
| Networking | VPC with 2 public + 2 private subnets across 2 AZs, NAT Gateway for outbound |
| Load Balancing | Internet-facing ALB routing HTTP traffic to private ECS tasks |
| Database | RDS in private subnets, credentials in Secrets Manager + KMS encryption |
| Secrets | Secrets Manager for DB credentials, IAM-scoped access from tasks |
| IAM | Separate execution role (image pull, secrets) and task role (app permissions) |
| Logging | CloudWatch log groups per service, 7-day retention |
| AMI | SSM Parameter Store lookup for latest ECS-optimized Amazon Linux 2023 AMI |
| ASG Protection | `managed_termination_protection = ENABLED` — ECS controls instance lifecycle |
| Tagging | Consistent `Project`, `Environment`, `Name` tags on all resources |
| Terraform | Modular structure, environment-specific entry point under `environments/dev/` |

---

## Where They Differ — and Why

### 1. Network Mode: `awsvpc` vs `bridge`

| | Week 3 (WordPress) | Temporal |
|---|---|---|
| Mode | `awsvpc` | `bridge` |
| How it works | Each task gets its own ENI and private IP | Tasks share the host EC2 network interface |
| Port mapping | No host port — container port is the IP | `hostPort=0` (dynamic) for ALB; `hostPort=7233` (fixed) for NLB |

**Why WordPress uses `awsvpc`:**
WordPress is a single stateless service. `awsvpc` gives each task a dedicated IP, simplifies security group rules (SG attached to task, not EC2), and works naturally with ALB. There is no inter-service communication, so there's no downside.

**Why Temporal uses `bridge`:**
Temporal Server must expose a fixed port (`7233`) so the NLB can register it as an instance target. NLB instance target type requires a known `hostPort` — `awsvpc` mode does not support fixed host ports this way. `bridge` mode also allows multiple services to share one EC2 host with dynamic port allocation for ALB-backed services.

---

### 2. Number of Services

| | Week 3 | Temporal |
|---|---|---|
| Services | 1 (WordPress) | 4 (temporal-server, temporal-ui, api, worker) |
| Load balancers | 1 ALB | 1 ALB + 1 internal NLB |
| Startup order | Independent | Strict dependency chain: DB → bootstrap → temporal-server → ui/api/worker |

**Why:**
WordPress is a monolithic application — one container handles everything (HTTP, business logic, file serving). Temporal is a distributed system: the workflow engine (temporal-server), the operator console (temporal-ui), the REST API (api), and the execution engine (worker) are separate concerns that scale independently. Coupling them into one container would remove the ability to scale workers without scaling the API, or restart the API without touching the workflow engine.

---

### 3. Database Engine

| | Week 3 | Temporal |
|---|---|---|
| Engine | MySQL 8.0 | PostgreSQL 15 |
| Database | Single: `wordpress` | Two: `temporal`, `temporal_visibility` |
| Parameter group | Custom (utf8mb4, slow query log) | Default PostgreSQL |
| TLS | Standard | Required (`sslmode=require`) |

**Why WordPress uses MySQL:**
WordPress was designed for MySQL and has decades of optimization around it. The custom parameter group adds utf8mb4 encoding (emoji support) and slow query logging — both standard for WordPress production deployments.

**Why Temporal uses PostgreSQL:**
Temporal's persistence layer officially supports PostgreSQL and MySQL, but PostgreSQL is the more mature and better-tested backend for Temporal in production. The `temporal_visibility` database is a separate concern — it powers workflow search and filtering (the `OrderStatus` search attribute queries hit this database). Separating them allows independent tuning.

---

### 4. Persistent Storage

| | Week 3 | Temporal |
|---|---|---|
| Shared storage | EFS (Elastic File System) | None |
| What is stored | WordPress files: themes, plugins, uploads (`/var/www/html`) | Nothing — all state is in RDS |
| Access | EFS Access Point with IAM authorization, TLS in-transit encryption | N/A |

**Why WordPress needs EFS:**
WordPress stores uploaded media, installed plugins, and active themes on the local filesystem. Without shared storage, each task has its own isolated filesystem — a file uploaded through one task is invisible to another. With multiple tasks behind an ALB, users would see inconsistent state. EFS provides a single shared filesystem that all tasks mount simultaneously.

**Why Temporal does not need EFS:**
The worker and API are stateless. All durable state (workflow history, activity results, signals, timers) is written to RDS by the Temporal Server. Workers hold nothing locally — they receive work from Temporal Server, execute it, and return results. Killing a worker loses nothing. This is the core value proposition of Temporal: stateless workers backed by durable storage.

---

### 5. Scaling Model

| | Week 3 | Temporal |
|---|---|---|
| Task scaling | Application Auto Scaling (CPU/memory-based) | Manual (`desired_count` variable) |
| Scale-out trigger | CloudWatch metric breach (CPU > threshold) | Terraform variable change + apply |
| Scalable services | WordPress (1 service) | API and Worker (temporal-server fixed at 1) |
| EC2 scaling | ASG with managed capacity provider | ASG with managed capacity provider (same) |

**Why WordPress uses Application Auto Scaling:**
WordPress traffic is bursty and unpredictable. CPU spikes when a page is rendered, image processing happens, or a plugin runs. Automatic scaling responds to real load without human intervention — appropriate for a web application serving end users.

**Why Temporal uses manual scaling:**
The demo environment has predictable, low volume. More importantly, Temporal Server itself cannot be horizontally scaled with the `auto-setup` single-node image — so EC2 capacity is bounded anyway. Scaling the worker and API is a deliberate operator decision (how many parallel workflow executions do you want?), not an automatic response to CPU. Manual scaling via Terraform keeps the demo simple and makes the `desired_count` variable explicit and auditable.

---

### 6. Deployment Safety

| | Week 3 | Temporal |
|---|---|---|
| Circuit breaker | Yes — auto-rollback on failed deployment | No |
| Placement strategy | `spread` across AZs | Default (bin-packing) |
| Health check grace period | 120 seconds | Varies per service |

**Why WordPress has a circuit breaker:**
WordPress deploys a single, user-facing service. A bad deployment (broken plugin, misconfigured env var) would immediately impact all users. The circuit breaker detects failed health checks during a deployment and automatically rolls back to the previous task definition — zero manual intervention needed.

**Why Temporal does not:**
The services are internal to the system except the API. A failed API deployment rolls back manually (update service to previous task def revision). More importantly, the startup dependency chain (temporal-server must be healthy before workers register) makes circuit-breaker rollback semantics complex in this architecture. Omitted for demo simplicity — a production deployment would add this.

**Why Week 3 spreads across AZs:**
WordPress scales to multiple tasks. Without explicit AZ spread, ECS might place both tasks on the same EC2 in the same AZ — an AZ failure takes down everything. The `attribute:ecs.availability-zone` spread strategy guarantees one task per AZ.

**Why Temporal does not:**
With `desired_count = 1` for most services, there's only one task to place — spread strategy has no effect. The worker and API can run on any available instance.

---

### 7. Monitoring and Alerting

| | Week 3 | Temporal |
|---|---|---|
| Alerts | SNS topic → email for ECS CPU, ALB 5xx, RDS storage, RDS connections | CloudWatch alarms on ALB and RDS (no SNS subscription in code) |
| Dashboard | None (CloudWatch metrics only) | None |
| Gmail protection | Yes — `email-json` protocol + `AuthenticateOnUnsubscribe` | N/A |

**Why Week 3 has fuller monitoring:**
A WordPress site is a customer-facing product. Downtime, slow queries, or high error rates directly impact users. The SNS alerting pipeline ensures an operator is paged before the problem becomes an outage. The Gmail protection solves a real operational problem: Gmail's link scanner auto-clicks unsubscribe links, silently killing the alert subscription.

**Why Temporal has minimal monitoring:**
The demo is not customer-facing. Temporal UI provides built-in visibility into workflow state, activity failures, and retry history — reducing the need for external alerting during a demo or development session. Production Temporal deployments add Prometheus metrics (already partially configured with `TEMPORAL_METRICS_PROMETHEUS_FRAMEWORK_VALUE`) and Grafana dashboards.

---

### 8. Container Images

| | Week 3 | Temporal |
|---|---|---|
| Source | Docker Hub (`wordpress:6.5-apache`) | ECR (custom-built API and Worker); Docker Hub (temporal-server, temporal-ui) |
| Build required | No | Yes — API and Worker must be built and pushed to ECR before deploy |
| Version pinning | Minor version (`6.5`) | `latest` tag (temporal-server, temporal-ui) |

**Why WordPress uses Docker Hub:**
WordPress is a commodity, off-the-shelf application. There is no custom code to build. Using the official image reduces maintenance overhead — no CI/CD pipeline, no ECR repository, no image build step needed.

**Why Temporal uses ECR for API and Worker:**
The API and Worker are custom Python applications with your business logic. They must be built from source and stored privately. ECR integrates natively with ECS IAM authentication — no Docker Hub credentials to manage. Temporal Server and UI are third-party open-source tools, so Docker Hub images are used for those.

---

## Summary Table

| Design Decision | Week 3 (WordPress) | Temporal | Reason for Difference |
|---|---|---|---|
| Network mode | `awsvpc` | `bridge` | Fixed NLB port 7233 requires bridge |
| Services | 1 | 4 | Monolith vs distributed system |
| Database | MySQL 8.0 | PostgreSQL 15 | App compatibility vs Temporal's preferred backend |
| Shared storage | EFS | None | Stateful files vs stateless workers |
| Task scaling | Auto (CloudWatch) | Manual (Terraform var) | Unpredictable traffic vs controlled demo load |
| Deployment safety | Circuit breaker + AZ spread | None | User-facing prod vs internal demo |
| Load balancers | ALB only | ALB + NLB | HTTP only vs HTTP + gRPC |
| Monitoring | Full SNS alerting | Minimal | Customer-facing vs developer tooling |
| Container images | Docker Hub | Docker Hub + ECR | Off-the-shelf vs custom business logic |

---

## Which Choices Fit Which Scenario

**Use `awsvpc` when:** Services are independent, you want task-level security group isolation, or you're running Fargate. It simplifies networking but does not support fixed host ports.

**Use `bridge` when:** Services communicate directly on known ports, you need fixed host port mapping (e.g., for NLB instance targets), or you're packing multiple services on one EC2 host.

**Use EFS when:** Your application writes files that must be shared across multiple task instances — uploads, plugins, generated assets. Do not use it for databases or workflow state.

**Use Application Auto Scaling when:** Load is user-driven and unpredictable. Let CloudWatch metrics trigger scale-out automatically.

**Use manual `desired_count` when:** Load is predictable and controlled, or you need to reason carefully about which services scale together (as in Temporal, where worker count and task queue depth are related decisions).

**Use a deployment circuit breaker when:** The service is user-facing and a bad deploy must never reach 100% of traffic without verification. Always use this in production.

**Use SNS alerting when:** Uptime matters to real users. Monitoring without alerting is just data collection — it doesn't wake anyone up at 2am when the site goes down.
