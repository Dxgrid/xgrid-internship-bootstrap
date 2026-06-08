# 01 — Architecture

## The problem we solved

The Temporal platform ran on ECS with **only CloudWatch logs** — no metrics, no dashboards, no SLOs, no proactive alerting. You could read logs *after* something broke, but you couldn't *see* system health or get paged. The task: add **centralized monitoring**.

"Centralized" is the key word: one Prometheus scrapes *everything*, one Grafana visualizes *everything*, one alert pipeline notifies on *everything* — regardless of which of the ~12 ECS services or 7 EC2 hosts a signal comes from.

---

## Topology

```
                          Internet
                             │
              ┌──────────────┴───────────────┐
              │         ALB (public)          │
              │  :8000 API  :8080 UI          │
              │  :80 / :8443 Grafana          │
              └──────────────┬───────────────┘
                             │
  ┌──────────────────────────────────────────────────────────────┐
  │  VPC · private subnets · ECS cluster (EC2 launch type, 7 hosts) │
  │                                                                │
  │   OBSERVED WORKLOAD                 OBSERVABILITY STACK         │
  │   ┌────────────────────┐           ┌──────────────────────┐    │
  │   │ temporal-server     │  :8001──▶ │ Prometheus  :9090     │   │
  │   │  (awsvpc, own ENI)  │           │  ├ AlertManager :9093 │   │
  │   ├────────────────────┤           │  └ sns-bridge   :9094 │    │
  │   │ worker ×N (awsvpc)  │  :9090──▶ │   (one awsvpc task)   │    │
  │   ├────────────────────┤           └──────────┬───────────┘    │
  │   │ api, temporal-ui    │                      │ TSDB           │
  │   │ 5 mock services     │           ┌──────────▼───────────┐    │
  │   └────────────────────┘           │ EFS (Prometheus data) │    │
  │                                     └──────────────────────┘    │
  │   node-exporter (DAEMON, 1 per host) :9100 ──▶ Prometheus       │
  │                                                                │
  │   ┌────────────────────┐           ┌──────────────────────┐    │
  │   │ Grafana (awsvpc)    │◀──query──▶│ Prometheus (DNS-SD)  │    │
  │   │  datasources:       │           └──────────────────────┘    │
  │   │  • Prometheus       │           ┌──────────────────────┐    │
  │   │  • CloudWatch       │◀──query──▶│ CloudWatch (AWS API) │    │
  │   └────────────────────┘           └──────────────────────┘    │
  └──────────────────────────────────────────────────────────────┘
                             │ alerts
                   AlertManager→sns-bridge→ SNS topic ─▶ email
```

---

## The 3 scrape paths (the heart of the design)

Prometheus discovers what to scrape dynamically — no hardcoded IPs. There are **three different discovery mechanisms**, each chosen for the network mode of its target:

| Job | Target | Network mode | Discovery | Port | Why this method |
|---|---|---|---|---|---|
| `temporal-server` | Temporal Server metrics | `awsvpc` (own ENI) | **Cloud Map DNS-SD** `server-metrics.<ns>` | 8001 | awsvpc task IP ≠ host IP — EC2-SD can't reach it (see [Discoveries #1](04-DISCOVERIES.md)) |
| `temporal-worker` | Worker SDK metrics | `awsvpc` (own ENI) | **Cloud Map DNS-SD** `worker-metrics.<ns>` | 9090 | Same — plus workers scale, so we need *all* IPs (MULTIVALUE) |
| `node_exporter` | EC2 host metrics | `host` network | **EC2-SD** (tag filter) | 9100 | Host-network = the metrics *are* on the host IP, so EC2-SD is correct here |

**Key insight:** discovery method must match network mode.
- `host` network → metrics live on the EC2 host IP → **EC2 service discovery** works.
- `awsvpc` network → metrics live on the *task's* ENI IP (not the host) → **Cloud Map DNS** is required.

Cloud Map routing policy is also chosen per workload:
- **`worker-metrics` = MULTIVALUE** — workers scale horizontally; the A-record returns *every* task IP so Prometheus scrapes all of them.
- **`server-metrics` = WEIGHTED** — server is a singleton; one A-record.

---

## Data flow, end to end

1. **Emit** — Temporal Server exposes Prometheus metrics on `:8001` (`PROMETHEUS_ENDPOINT=0.0.0.0:8001`). The Python worker exposes SDK metrics on `:9090` (`PrometheusConfig(bind_address="0.0.0.0:9090")`). Node Exporter exposes host metrics on `:9100`.
2. **Discover** — Prometheus resolves Cloud Map DNS names (workers/server) and queries the EC2 API (node exporters) every 15s.
3. **Scrape** — Prometheus pulls `/metrics` from each target every 15s, stored in its TSDB (on EFS).
4. **Compute** — recording rules pre-aggregate SLIs (success rate, poll-sync rate, error-burn rates) every 15–30s.
5. **Visualize** — Grafana queries Prometheus (`uid=temporalprom`) and CloudWatch (`uid=temporalcw`) for the dashboard.
6. **Alert** — alert rules evaluate continuously; firing alerts go to AlertManager → SNS-bridge sidecar → SNS topic → email.

---

## Why co-locate the stack on the *same* ECS cluster

We deliberately ran Prometheus/Grafana/Node-Exporter on the **same** ECS cluster as the workload (not a separate monitoring cluster):

- **Network simplicity** — scraping stays inside one VPC/SG boundary; no cross-VPC peering.
- **Cost** — reuses existing EC2 capacity and the existing RDS (Grafana's backend DB is a database on the workload's Postgres instance).
- **Node Exporter needs to be on every host anyway** — a `DAEMON` ECS service places exactly one Node Exporter per EC2 instance automatically.

Trade-off (be honest in the demo): co-location means a host failure affects both workload and monitoring on that host. For production you'd isolate the monitoring cluster. For this dev platform, co-location is the right cost/complexity call.

---

## Network & access summary

| Path | Mechanism |
|---|---|
| Public → API / UI / Grafana | ALB (`:8000`, `:8080`, `:80`/`:8443`) |
| Clients → Temporal gRPC | NLB (`:7233`) → server task ENI (target type `ip`) |
| Prometheus → targets | Security group: monitoring-SG allowed inbound on `:8001/:9090/:9100` on each target's SG |
| Grafana → Prometheus | Cloud Map DNS (`prometheus.<ns>:9090`) |
| Grafana → CloudWatch | AWS API (IAM read-only policy on Grafana task role) |
| Alerts → email | AlertManager → `localhost:9094` (sns-bridge) → SNS → subscribed email |

See [02-STACK.md](02-STACK.md) for each component in depth and [04-DISCOVERIES.md](04-DISCOVERIES.md) for the non-obvious failures we hit wiring this up.
