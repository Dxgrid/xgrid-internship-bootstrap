# 03 — Metrics, SLOs & Alerting

This is the "what we actually measure and act on" doc — the SRE substance.

---

## 1. Metric taxonomy (the part that trips everyone up)

Metrics come from **two emitters with different naming conventions**. Knowing which is which is essential for writing correct queries.

### Server-side metrics — **no prefix**
Emitted by the Temporal Server itself (scraped on `:8001`). These are the *authoritative lifecycle* signals.

| Metric | Meaning |
|---|---|
| `workflow_success`, `workflow_failed`, `workflow_timeout`, `workflow_terminate`, `workflow_cancel` | Final workflow outcomes (namespace-level, **no** `workflow_type` label) |
| `poll_success`, `poll_success_sync` | Task-queue poll matches; `_sync` = matched instantly (no backlog) |
| `persistence_latency_bucket` | DB persistence latency histogram |
| `service_errors_resource_exhausted` | RPS/concurrency limits being hit |

### SDK-side metrics — **`temporal_` prefix**
Emitted by the worker's Core SDK (scraped on `:9090`). Per-`workflow_type`/`activity_type` golden signals.

| Metric | Meaning |
|---|---|
| `temporal_workflow_completed`, `temporal_workflow_failed` | Workflows the *worker* finished |
| `temporal_activity_schedule_to_start_latency_bucket` | Queue wait before an activity starts — **the key scaling signal** |
| `temporal_worker_task_slots_used` / `_available` | Worker concurrency capacity, by `worker_type` |
| `temporal_workflow_task_execution_failed` | Non-determinism / code-bug canary |
| `temporal_request_failure`, `temporal_long_request_failure` | gRPC request failures |

### Two non-obvious rules
1. **Core/Python SDK histograms are in MILLISECONDS, no `_seconds` suffix.** A 150 ms threshold is `150`, not `0.15`. (Java appends `_seconds` and uses seconds — different.)
2. **`temporal_worker_task_slots_*` has two sources.** The `auto-setup` server runs internal Go *system* workers that ALSO emit it (`task_queue=temporal_sys_*`, scraped under `job=temporal-server`). Your app's Python worker emits it under `job=temporal-worker` (`task_queue=order-task-queue`). **Filter by `job` or `task_queue`** or you'll mix system + app capacity. (See [Discoveries #6](04-DISCOVERIES.md).)

---

## 2. Recording rules (precomputed SLIs)

Recording rules run *inside* Prometheus on a fixed interval, decoupled from the Grafana time range — essential for burn-rate windows to be correct.

| Rule | Definition (essence) |
|---|---|
| `temporal:workflow_success_rate:ratio_rate5m` | `success / (success + failed + timeout + terminate + cancel)` over 5m (server-sourced) |
| `temporal:workflow_error_rate:ratio_rate1h` | `1 − success_rate` over **1h** window (fast burn) |
| `temporal:workflow_error_rate:ratio_rate6h` | `1 − success_rate` over **6h** window (slow burn) |
| `temporal:poll_sync_rate:ratio_rate5m` | `rate(poll_success_sync) / rate(poll_success)` by `task_type` |
| `instance:node_cpu_utilisation:rate5m` | `100 − avg(rate(idle cpu))` per host |
| `instance:node_memory_utilisation:ratio` | `1 − MemAvailable/MemTotal` per host |

**Why the SLI is server-sourced:** server metrics capture outcomes the SDK never sees (server-side timeouts, terminations), and are namespace-level. The SDK metrics own the *per-type* golden-signal rows instead.

---

## 3. SLOs & error budgets

- **Availability SLO: 99% successful workflows over 30 days** → **error budget = 1%**.
- **Multi-window burn-rate alerting** (Google SRE method): instead of alerting on a raw error threshold, alert on *how fast the budget is burning*.

| Alert | Condition | Meaning |
|---|---|---|
| **WorkflowSLOFastBurn** (critical) | 1h error rate > `14.4 × (1 − 0.99)` | Burning so fast the 30-day budget exhausts in ~2 days → page now |
| **WorkflowSLOSlowBurn** (warning) | 6h error rate > `6 × (1 − 0.99)` | Sustained slow drain → ticket |

The **error-budget panel** in Grafana shows budget remaining:
`clamp_min(1 − ((1 − success_rate) / (1 − 0.99)), 0)`.

**Latency SLI:** activity `schedule_to_start` p95 — threshold **> 150 ms** (self-hosted canon). This is the *leading* scale-out signal: queue wait rises *before* throughput collapses.

---

## 4. The dashboard ("Temporal SRE — SLOs & Golden Signals")

Five rows, mapping to the SRE mental model:

| Row | Panels | Signal type |
|---|---|---|
| **SLO Overview** | Success rate vs 99%, error-budget gauge, activity p95, poll-sync rate | SLIs |
| **Golden Signals (worker SDK)** | Completions vs failures, activity latency p50/p95/p99 | Traffic + latency + errors |
| **Worker Health** | Active workers, activity slots used/available | Saturation |
| **Server Health** | Poll success rate, persistence latency p95 | Backend saturation |
| **Infrastructure (Node Exporter)** | CPU / memory / root-disk per host | Host saturation |

---

## 5. Alert catalog & routing

**Routing chain:** Prometheus (evaluates rules) → **AlertManager** (group, dedupe, inhibit, route by `severity`) → **sns-bridge** (`:9094`, webhook→`sns.publish`) → **SNS topic** → **email**.

| Alert | Severity | Fires when |
|---|---|---|
| `TemporalWorkerDown` | critical | `absent(up{job="temporal-worker"}==1)` for 2m (all workers gone) |
| `TemporalServerDown` | critical | `max(up{job="temporal-server"})==0` for 2m |
| `WorkflowSLOFastBurn` | critical | budget burning ~14.4× (2-day exhaustion) |
| `HighWorkflowTaskExecutionFailure` | critical | sustained workflow-task failures (non-determinism canary) |
| `WorkerActivitySlotsExhausted` | warning | `task_slots_available{ActivityWorker}==0` for 2m |
| `HighActivityScheduleToStartLatency` | warning | p95 > 150 ms for 3m |
| `LowPollSyncRate` / `VeryLowPollSyncRate` | warning / critical | poll-sync < 0.95 / < 0.90 |
| `WorkflowSLOSlowBurn`, `ActivityExecutionFailureRateHigh`, `HighRequestFailure`, `HighLongRequestFailure`, `ServerResourceExhausted` | warning | various sustained degradations |
| `NodeDown`, `HighCPU`, `HighMemory` | critical / warning | host-level (Node Exporter) |

**Two notable design choices:**
- `TemporalWorkerDown` uses **`absent()`**, not `up==0`. Workers are discovered via Cloud Map DNS — if *all* die, ECS deregisters the records, the DNS name empties, and the `up` series **disappears** (so `up==0` would never fire). `absent()` catches "no healthy worker series exists at all."
- Critical inhibits matching warning (same alertname+instance) → no double-paging during an incident.

**Operational gotcha:** SNS email only delivers after the subscriber **confirms** the subscription (click the link). Status `PendingConfirmation` = silent. (See [Discoveries #7](04-DISCOVERIES.md).)
