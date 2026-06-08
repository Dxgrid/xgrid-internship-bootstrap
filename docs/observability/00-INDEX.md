# Centralized Observability for Temporal-on-ECS — Documentation

> **One-line summary:** Took a distributed workflow application (Temporal Server, workers, API, 5 mock microservices) running on AWS ECS with *only* CloudWatch logs, and built a full **SRE-grade observability platform** — metrics pipeline, dashboards, SLOs with error budgets, and multi-window alerting — using the Prometheus/Grafana ecosystem glued together with AWS-native service discovery (Cloud Map), all as Terraform infrastructure-as-code.

This is a **DevOps / SRE observability** deliverable. Temporal is the *workload being observed*; the star of the project is the **centralized monitoring stack**.

---

## The deliverable in one sentence per layer

| Layer | What it does |
|---|---|
| **Collection** | Prometheus scrapes 3 metric sources: Temporal Server (`:8001`), worker SDK (`:9090`), Node Exporter (`:9100`). |
| **Discovery** | AWS Cloud Map (DNS service discovery) finds dynamic `awsvpc` task IPs; EC2 SD finds host-level Node Exporters. |
| **Storage** | Prometheus TSDB persisted on EFS so metric history survives task restarts. |
| **Visualization** | Grafana dashboard ("Temporal SRE — SLOs & Golden Signals") with **two datasources**: Prometheus + CloudWatch. |
| **SLOs** | Recording rules precompute success rate, poll-sync rate, and multi-window error-burn rates. |
| **Alerting** | Prometheus alert rules → AlertManager (severity routing) → Python SNS-bridge sidecar → SNS → email. |

---

## Document map

Read in order for understanding; jump to 04/05 for the demo and community post.

| # | Doc | Purpose | Audience |
|---|---|---|---|
| 01 | [Architecture](01-ARCHITECTURE.md) | Topology, the 3 scrape paths, data flow, why ECS co-location | You |
| 02 | [Tech Stack](02-STACK.md) | Every component (Prometheus, Grafana, Node Exporter, AlertManager, SNS-bridge) + AWS glue (ECR, Cloud Map, CloudWatch, ALB/NLB, EFS, IAM) | You |
| 03 | [Metrics, SLOs & Alerting](03-METRICS-SLO-ALERTING.md) | Metric taxonomy, recording rules, SLO/error-budget/burn-rate math, the alert chain | You |
| 04 | [Discoveries (not in Temporal KB)](04-DISCOVERIES.md) | The novel gotchas + root-cause + fix — **self-contained for community upload** | Community |
| 05 | [Demo Runbook](05-DEMO-RUNBOOK.md) | Scripted walkthrough for the live demo: what to run, what to say, failure→recovery | You (tomorrow) |

---

## Live endpoints (dev)

| Service | URL |
|---|---|
| Grafana | `http://temporal-order-dev-alb-826497180.us-east-1.elb.amazonaws.com` (also `:8443`) |
| Temporal UI | `…:8080` |
| Order API | `…:8000` |
| Prometheus | internal only (awsvpc) — query via the test suite or SSM |

**Test/demo driver:** `python3 temporal_test_suite.py` (menu-driven — see [05-DEMO-RUNBOOK.md](05-DEMO-RUNBOOK.md)).

---

## The 30-second elevator pitch (for the demo intro)

> "I built centralized observability for a distributed Temporal application on ECS. Prometheus collects golden-signal and SLO metrics from three sources using AWS Cloud Map for service discovery of dynamic container IPs. Grafana visualizes them alongside CloudWatch infrastructure metrics. I defined SLOs with error budgets and multi-window burn-rate alerts that page through SNS email via AlertManager. The whole thing is Terraform IaC and survives restarts via EFS-backed storage. Along the way I hit — and documented — several issues that aren't in any existing guide, like the fact that `awsvpc` tasks can't be scraped by EC2 service discovery."
