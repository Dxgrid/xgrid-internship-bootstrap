# Temporal Order Platform

A durable order-processing system built on [Temporal](https://temporal.io) and deployed
on **AWS ECS** with full SRE observability (Prometheus + Grafana + alerting).

An order flows through fraud check → inventory reservation → a human validation gate →
payment → parallel per-item shipping → notification. If any step fails, a **saga**
automatically compensates (refund the customer, release the inventory) so the system is
never left in an inconsistent state.

---

## What it demonstrates

| Temporal concept | Where |
|---|---|
| **Workflow orchestration** | `OrderWorkflow` drives the whole order lifecycle |
| **Activities** | fraud, payment, inventory, shipping, notification calls |
| **Saga / compensation** | refund + revert inventory on failure (LIFO, infinite retry) |
| **Child workflows (fan-out/fan-in)** | one `ShippingWorkflow` per item, run in parallel |
| **Signals** | `proceed_to_payment`, `cancel_order`, `update_address_signal` |
| **Queries** | live order status |
| **Updates** | synchronous `update_address` |
| **Human-in-the-loop** | workflow waits up to 1h on a validation signal |

---

## Architecture

![System Architecture](Sytem%20Design%20Architecture.jpeg)

- **ALB** (public) → Order API `:8000`, Temporal UI `:8080`, Grafana `:80`
- **NLB** (internal) → Temporal gRPC `:7233`
- **RDS PostgreSQL** → Temporal state (`temporal`, `temporal_visibility`) + Grafana
- **Cloud Map** (`temporal-order-dev.local`) → service discovery for Prometheus scraping
- Everything runs as **ECS services** on a single EC2-backed cluster.

See [docs/observability/01-ARCHITECTURE.md](../docs/observability/01-ARCHITECTURE.md) for detail.

---

## Project structure

```
Temporal/
├── python/
│   ├── workflows/        OrderWorkflow + ShippingWorkflow
│   ├── activities/       fraud, payment, inventory, shipping, notification
│   ├── api/              FastAPI service (submit orders, signals, queries)
│   ├── worker.py         the Temporal worker (with Prometheus metrics on :9090)
│   └── models.py         shared dataclasses
├── services/             5 mock dependency services (FastAPI)
├── terraform/            infrastructure as code (ECS, RDS, ALB/NLB, monitoring)
└── scripts/              daily reliability report
```

---

## Running it

### Locally
```bash
cd python
uv sync
# start a local Temporal dev server, then:
./startlocalworker.sh      # worker
uvicorn api.main:app --port 8000   # API
```

### On AWS (Terraform)
```bash
cd terraform/environments/dev
terraform init
terraform apply
```
A first apply builds & pushes the container images and bootstraps the databases
automatically (see `bootstrap.tf`). After it completes, get the URLs:
```bash
terraform output
```

> **Rebuilding from scratch?** `terraform destroy` + re-apply needs the databases,
> ECR images, and the `OrderStatus` search attribute restored. This is automated, but
> the manual procedure is in
> [docs/observability/06-OPERATIONS-RUNBOOK.md](../docs/observability/06-OPERATIONS-RUNBOOK.md) §7.

---

## Operations

- **Test / failure-injection suite:** `python3 ../temporal_test_suite.py` (16-option menu:
  generate traffic, fire alarms, run outage drills, kill tasks and watch ECS self-heal).
- **Daily reliability report:** `python3 scripts/daily-reliability-report.py` (`--dry-run`
  to print without emailing). Runs via cron at 06:00.
- **Runbook:** [docs/observability/06-OPERATIONS-RUNBOOK.md](../docs/observability/06-OPERATIONS-RUNBOOK.md)
- **Dashboards & SLOs:** [docs/observability/03-METRICS-SLO-ALERTING.md](../docs/observability/03-METRICS-SLO-ALERTING.md)

---

## SLOs

| SLO | Target |
|---|---|
| Workflow success rate | ≥ 99% over 30 days |
| Activity schedule-to-start p95 | ≤ 150 ms |

Alerts (fast/slow error-budget burn, non-determinism canary, low poll-sync) route through
AlertManager → SNS → email. AWS-native CloudWatch alarms cover service-down independently
of the monitoring stack.
