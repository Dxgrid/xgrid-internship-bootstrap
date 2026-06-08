# 05 — Demo Runbook

A scripted walkthrough for the live demo. Driver: `python3 temporal_test_suite.py` (menu-driven). Total ~12–15 min. Practice the order once beforehand.

---

## Pre-flight (do 10 min BEFORE the demo)

1. **Confirm everything is up:**
   ```bash
   python3 temporal_test_suite.py   # → 29 (platform status): all services COMPLETED, worker 2/2
   ```
2. **Confirm SNS subscription is `Confirmed`** (else no alert email — see [Discoveries #7](04-DISCOVERIES.md)):
   ```
   menu → 5
   ```
3. **Open browser tabs:**
   - Grafana: `http://temporal-order-dev-alb-826497180.us-east-1.elb.amazonaws.com` (or `:8443`)
   - Temporal UI: `…:8080`
4. **Pre-warm the dashboard** — generate a little traffic so panels aren't empty when you open (`menu → 11`), then hard-refresh Grafana (Ctrl+Shift+R).

---

## The narrative arc (what story you're telling)

> "Distributed app on ECS had only logs. I built centralized observability: metrics → dashboards → SLOs → alerting. Let me show it collecting, visualizing, and *acting* on signals — including auto-recovery and a real page."

Four beats: **(1) it collects → (2) it visualizes → (3) it has SLOs → (4) it alerts & recovers.**

---

## Beat 1 — "It collects" (2 min)

**Say:** "Prometheus scrapes three sources using AWS-native service discovery — no hardcoded IPs."

**Do:**
```
menu → 3   # Prometheus targets: temporal-server, temporal-worker, node_exporter all UP
```
**Point out:** three jobs, all `up`. Mention the **key architectural choice**: awsvpc tasks (server/worker) are found via **Cloud Map DNS**, while host-network Node Exporter uses **EC2 service discovery** — *because discovery method must match network mode*. (This is your strongest technical point — see [Discoveries #1](04-DISCOVERIES.md).)

---

## Beat 2 — "It visualizes" (3 min)

**Say:** "Grafana is the single pane of glass — application metrics from Prometheus *and* AWS infrastructure metrics from CloudWatch, together."

**Do:** Open Grafana → "Temporal SRE — SLOs & Golden Signals." Walk the five rows top-down:
- **SLO Overview** — success rate, error-budget gauge, activity p95, poll-sync rate.
- **Golden Signals** — completions vs failures, latency p50/p95/p99.
- **Worker Health** — active workers, activity slots (saturation).
- **Server Health** — poll success, persistence latency.
- **Infrastructure** — per-host CPU/mem/disk from Node Exporter.

**Then generate live load and watch it move:**
```
menu → 12   # 20 orders, submitted AND proceeded automatically
```
Hard-refresh after ~45s — completions tick up, latency populates. **Say:** "End-to-end: emit → discover → scrape → record → visualize, in about 45 seconds."

---

## Beat 3 — "It has SLOs, not just charts" (2 min)

**Say:** "Charts show *what happened*; SLOs tell you *whether you're meeting your reliability target and how fast you're burning the budget*."

**Do:**
```
menu → 21   # recording rules loaded (success_rate, poll_sync_rate, burn windows)
menu → 22   # current SLO values: success rate, error rates 1h/6h, poll sync
```
**Point out:** 99% / 30-day SLO → 1% error budget; **multi-window burn-rate** alerts (fast 1h@14.4×, slow 6h@6×) — the Google SRE method, not naive threshold alerting.

---

## Beat 4 — "It alerts AND the platform self-heals" (4 min) — the showstopper

### 4a. Auto-recovery
**Say:** "ECS self-heals; observability proves it."
**Do:**
```
menu → 9    # kill one worker task
menu → 29   # show it: worker briefly 1/2 → ECS replaces it → back to 2/2
```
Show the **Active Workers** panel dip and recover.

### 4b. A real page (start this EARLY — it needs ~2 min)
**Say:** "Now a real alert, end to end — Prometheus → AlertManager → SNS → my inbox."
**Do:**
```
menu → 23   # stops a worker, counts down the 2-min alert threshold, then checks the email path
```
While the countdown runs, **explain the chain** ([03 §5](03-METRICS-SLO-ALERTING.md)):
Prometheus rule (`absent(up{job="temporal-worker"})`, `for: 2m`) → AlertManager (severity routing, critical inhibits warning) → **sns-bridge** sidecar (webhook→`sns.publish`) → SNS → email.
**Payoff:** show the alert email arriving on your phone/inbox.

> Tip: trigger **4b first**, then fill the 2-minute wait with 4a (recovery) so there's no dead air.

---

## Closing (1 min)

**Say:** "All Terraform IaC, reproducible. Beyond building it, I hit and documented several issues not in any existing guide — like awsvpc tasks being unscrapable by EC2 service discovery, and a dashboard-JSON escaping bug that silently breaks queries. Those are written up for the community."

Point to [04-DISCOVERIES.md](04-DISCOVERIES.md).

---

## If something breaks live (recovery lines)

| If… | Say / do |
|---|---|
| A panel shows "No data" | "Some series only populate under load —" run `menu → 11`, keep talking, refresh. |
| Email is slow | "SNS email is best-effort delivery; the alert already fired in AlertManager —" show `menu → 24` / Prometheus alerts. |
| A service shows not-COMPLETED | "ECS is mid-deployment — this is the self-healing I'm about to demo," then `menu → 29` again. |

---

## Likely questions & crisp answers

- **"Why Prometheus over CloudWatch alone?"** PromQL, recording rules, SLO/burn-rate math, and per-`workflow_type` dimensionality CloudWatch can't express cheaply. I still use CloudWatch — surfaced inside Grafana for infra metrics.
- **"Why co-locate monitoring with the workload?"** Cost + network simplicity for dev; Node Exporter must be per-host anyway (DAEMON). Prod would isolate the monitoring cluster.
- **"How do you not lose metrics on restart?"** EFS-backed TSDB. (Honest caveat: EFS/NFS is a dev convenience; prod → local/EBS + Thanos/Mimir.)
- **"How does Prometheus find scaling workers?"** Cloud Map MULTIVALUE A-records — every worker IP, refreshed every 15s.
- **"What's the alerting philosophy?"** SLO-based, multi-window burn rate, severity routing with inhibition — page on budget burn, ticket on slow drains.
