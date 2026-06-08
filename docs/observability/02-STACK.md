# 02 — Tech Stack

Each component: **what it is → why we chose it → how it's wired here.** Two groups: the **observability tools** and the **AWS glue** that makes them work on ECS.

---

## Part A — Observability tools

### Prometheus — `prom/prometheus:v2.53.0`
- **What:** pull-based time-series DB + scraper. The collection and storage core.
- **Why:** de-facto standard for container/SRE metrics; native service discovery; PromQL; powers recording rules + alerts in one binary.
- **How here:** one container in an `awsvpc` task, listening `:9090`. Scrapes the 3 jobs (see [01](01-ARCHITECTURE.md)). Config (`prometheus.yml`), recording rules, and alert rules are injected as base64 blobs at container start (no custom image, no config volume). TSDB persisted to **EFS** (`--storage.tsdb.path=/prometheus`, 15-day retention). `--web.enable-lifecycle` lets us hot-reload config via `POST /-/reload`.

### AlertManager — `prom/alertmanager:v0.27.0`
- **What:** dedupe / group / route / silence layer for alerts.
- **Why:** Prometheus *fires* alerts but doesn't route them — AlertManager decides *who* gets notified and *how often*, and suppresses noise.
- **How here:** sidecar container in the same task, `:9093`. Routing config:
  - `group_by: [alertname, severity]`, `group_wait: 10s`, `group_interval: 5m`.
  - `repeat_interval: 4h` default, but **`1h` for `severity=critical`** (critical re-pages 4× more often).
  - **Inhibit rule:** a firing `critical` suppresses a matching `warning` (same alertname+instance) — no double-paging.
  - Single receiver `sns-webhook` → `http://localhost:9094/alert`.

### SNS-bridge — `python:3.12-slim` + boto3 (custom sidecar)
- **What:** ~25-line Python HTTP server translating AlertManager webhooks → SNS publishes.
- **Why:** AlertManager has no native SNS receiver. Rather than run a heavyweight adapter, a tiny `BaseHTTPRequestHandler` on `:9094` reads the webhook JSON and calls `sns.publish()` per alert.
- **How here:** third container in the task. Subject = `[FIRING|RESOLVED] Temporal Prometheus: <alertname>`; body = summary + labels. Gets `SNS_TOPIC_ARN` + `AWS_REGION` from env; publishes via the task role's `sns:Publish` permission.

> These three (Prometheus + AlertManager + sns-bridge) share **one task = one network namespace**, which is why they reach each other on `localhost`.

### Node Exporter — `quay.io/prometheus/node-exporter:v1.8.1`
- **What:** exposes host-level metrics (CPU, memory, disk, filesystem, network) from `/proc` and `/sys`.
- **Why:** Prometheus app metrics tell you about *workflows*; Node Exporter tells you about the *machines* underneath. Both are needed for SRE.
- **How here:** ECS service with **`scheduling_strategy = DAEMON`** → exactly one per EC2 host (7 total), automatically, even as the ASG scales. Runs in **`host` network + `pid` host** mode and bind-mounts `/proc`, `/sys`, `/` (read-only) so it reads the *real* host, not the container. Scraped via EC2-SD on `:9100`.

### Grafana — `grafana/grafana` (provisioned)
- **What:** dashboards + visualization.
- **Why:** the human-facing pane of glass; native Prometheus + CloudWatch datasources; dashboards-as-code via provisioning.
- **How here:** `awsvpc` task behind the ALB (`:80` and `:8443` — `:8443` because corporate firewalls often block `:80`). **Two datasources provisioned at startup:**
  - **Prometheus** (`uid=temporalprom`) → `http://prometheus.<ns>:9090` (finds Prometheus via Cloud Map DNS).
  - **CloudWatch** (`uid=temporalcw`) → AWS API via the Grafana task role's read-only CloudWatch policy.
  - **Backend DB:** Grafana's own state (users, dashboards) lives in a `grafana` database on the **existing RDS Postgres** — no second DB instance, and Grafana survives task restarts statelessly.
  - The dashboard JSON ("Temporal SRE — SLOs & Golden Signals") is base64-injected and auto-provisioned.

**SRE talking point:** one Grafana unifying *application* metrics (Prometheus) and *AWS infrastructure* metrics (CloudWatch) is exactly the "single pane of glass" SREs aim for.

---

## Part B — AWS glue

### ECS (EC2 launch type)
- **Role:** runs every container — workload and monitoring — as Tasks/Services on a shared EC2 cluster.
- **Why it matters here:** network mode per task drives the whole discovery design (`awsvpc` → own ENI → Cloud Map; `host` → host IP → EC2-SD). `DAEMON` strategy gives one-per-host Node Exporter for free.

### AWS Cloud Map (service discovery)
- **Role:** DNS-based service discovery for dynamic `awsvpc` task IPs.
- **Why it matters here:** the linchpin that makes scraping `awsvpc` tasks possible at all. ECS auto-registers/deregisters each task's ENI IP as an A-record under `<service>.temporal-order-dev.local`. Prometheus `dns_sd_configs` resolves these.
  - `worker-metrics` (MULTIVALUE — all worker IPs), `server-metrics` (WEIGHTED — singleton), `prometheus` (so Grafana finds Prometheus).

### ECR (Elastic Container Registry)
- **Role:** private registry for our custom images (API, worker).
- **Why it matters here:** the worker image (which emits the SDK metrics) is built and pushed to ECR; ECS pulls it by immutable tag. Public images (Prometheus, Grafana, Node Exporter) come from their upstream registries.

### CloudWatch
- **Role:** AWS-native logs + metrics.
- **Why it matters here, two ways:**
  1. **Logs** — every ECS task ships stdout/stderr to CloudWatch Log Groups (`/ecs/temporal-order/dev/*`) — our debugging backbone.
  2. **Metrics** — ECS/ALB/RDS infra metrics, surfaced *inside Grafana* via the CloudWatch datasource, and used for CloudWatch **alarms** (ALB unhealthy hosts, 5xx) that also notify via SNS.

### ALB + NLB
- **ALB (L7):** HTTP routing for API (`:8000`), Temporal UI (`:8080`), Grafana (`:80`/`:8443`). Path/port-based, health-checked target groups.
- **NLB (L4):** TCP `:7233` for Temporal gRPC → server task ENI (`target_type = ip`, required for awsvpc).

### EFS
- **Role:** network filesystem for **Prometheus TSDB persistence**.
- **Why it matters here:** without it, every Prometheus task restart = total loss of metric history. EFS (encrypted, with an access point) keeps the TSDB across restarts. *(Caveat: Prometheus warns NFS is unsupported — fine for dev, see [Discoveries #9](04-DISCOVERIES.md).)*

### IAM (task roles)
- **Prometheus task role:** `ec2:DescribeInstances` + `ec2:DescribeAvailabilityZones` (for EC2-SD), `sns:Publish` (sns-bridge), EFS `ClientMount/Write/RootAccess`.
- **Grafana task role:** read-only CloudWatch (`cloudwatch:Get*/List*/Describe*`, `tag:Get*`) for the CloudWatch datasource.
- **Why it matters here:** EC2 service discovery silently returns *nothing* without `DescribeInstances` — least-privilege still has to cover discovery.

---

## Quick reference — ports

| Component | Port | Exposure |
|---|---|---|
| Prometheus | 9090 | internal (Cloud Map) |
| AlertManager | 9093 | localhost (in-task) |
| sns-bridge | 9094 | localhost (in-task) |
| Node Exporter | 9100 | host network, scraped by Prometheus |
| Grafana | 3000 → ALB `:80`/`:8443` | public |
| Temporal Server metrics | 8001 | internal (Cloud Map) |
| Worker SDK metrics | 9090 | internal (Cloud Map) |
| Temporal gRPC | 7233 | NLB |
