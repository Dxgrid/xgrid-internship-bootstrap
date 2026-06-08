# Temporal Knowledge Base Cross-Check

Each decision in the plan is rated: ✅ Confirmed | ⚠️ Nuanced / Tradeoff | ❌ Incorrect / Overstate

---

## 1. Replace `auto-setup` with `temporalio/server:1.25.2` + `temporal-sql-tool`

**Rating: ✅ Confirmed — with a critical deprecation note**

The KB confirms this strongly. From official support staff:
> "I would not use auto-setup image for any type of prod deployment — it starts up all server roles in the same container and same process."

And from the latest release notes, `temporalio/auto-setup` is now **formally deprecated**:
> "The following images are deprecated and will no longer receive updates: `temporalio/auto-setup`. For local development, we recommend using the CLI dev server."

**Tradeoff the plan understates:** The plan says `auto-setup` "runs schema migrations on every startup." That's accurate but incomplete. The bigger production problem is that it also co-locates all four services (frontend, history, matching, worker) in the same process — meaning they cannot be independently scaled or restarted. A schema migration failure silently takes down your entire server. The `temporalio/server` image is cleaner because it only runs the services you specify via `SERVICES=`.

**Gap the plan misses:** The plan runs all services in a single ECS task with `SERVICES=history,matching,frontend,worker`. This is still the co-location anti-pattern even with the correct image. It's acceptable for dev/cost-constrained environments, but the KB is explicit that services should be independently scalable in production. This is a conscious tradeoff the plan should document.

---

## 2. `AUTO_UPGRADE` versioning behavior on the Worker

**Rating: ⚠️ Nuanced — `PINNED` is actually more appropriate for `OrderWorkflow`**

The plan applies `AUTO_UPGRADE` as the default versioning behavior because it's "most similar to legacy behavior." The KB contradicts this for this specific use case.

The Temporal versioning decision guide from the KB:

| Workflow Duration | Recommended Behavior |
|---|---|
| **Short** (completes before next deploy) | `PINNED` |
| **Medium** (spans multiple deploys) | `AUTO_UPGRADE` + patching |
| **Long** (weeks to years) | `PINNED` + upgrade on CaN |

`OrderWorkflow` is order processing that completes in **minutes**. The KB's own example table says:
> "Order processing — Minutes → **PINNED** — Completes before next deploy."

**What `AUTO_UPGRADE` actually requires:** Auto-upgrade workflows are NOT restriction-free. They "need to be kept replay-safe manually, i.e. with patching." So using `AUTO_UPGRADE` on a minute-duration workflow adds a patching burden with zero benefit — the workflow completes before the next deploy happens anyway.

**Correct choice:** `PINNED` at the Workflow class level, not `AUTO_UPGRADE` as a default on the Worker constructor. The plan's rationale ("safe for deployments where no long-running workflows exist") accidentally arrives at the right conclusion but applies the wrong mechanism.

**Additional nuance:** The KB warns about a queue-blocking issue with `AUTO_UPGRADE`:
> "There is a possibility of a queue blocking limitation for new or Auto-Upgrade Workflows if there is a ramp, but one of the Current or Ramping versions is down or doesn't have enough capacity."

For a worker fleet with min=2, this is a real risk during rolling deploys.

---

## 3. CPU-based auto-scaling at 25% threshold

**Rating: ⚠️ Partially correct — but the KB is explicit that CPU is a fallback, not the primary signal**

The plan acknowledges this and uses it as an "I/O-bound proxy." The KB goes further:

> "The key insight: traditional CPU and memory metrics often mislead when it comes to Temporal workloads. You might see perfectly healthy CPU usage while your Task latency climbs."

The KB's recommended primary signals in order:
1. **Task Queue Backlog** (`DescribeTaskQueueEnhanced` API) — most direct
2. **Schedule-to-Start latency** — primary signal
3. **Worker Task Slots** (`temporal_worker_task_slots_available`) — capacity signal
4. CPU/memory — last resort, unreliable for I/O-bound workers

EvenUp's real-world case study in the KB used slot-based scaling as the primary and latency as the fallback — never CPU first.

**The plan's 25% CPU threshold is defensible as a practical ECS constraint** (ECS Application Auto Scaling doesn't natively integrate with Prometheus metrics), but this is an infrastructure limitation, not a best practice. The plan should be explicit: the correct scaling signal is `activity_schedule_to_start_latency` p95 and `temporal_worker_task_slots_available`. CPU at 25% is the available proxy given ECS primitives.

**What the plan should add:** A CloudWatch custom metric from the Prometheus `temporal_worker_task_slots_available` value, piped via a Lambda or OTEL collector, so ECS can scale on the right signal. This is non-trivial but correct.

---

## 4. Alert threshold for `activity_schedule_to_start_latency` at 150ms

**Rating: ✅ Confirmed — but with important context**

The 150ms threshold is directly from the Temporal blog's own SLO example:
> "We'll aim for 150ms like we do for our Request Latency SLO."

And the official alert:
```yaml
expr: histogram_quantile(0.95, ...) > 0.150
for: 5m
```

**However**, Temporal Cloud's own monitoring guide uses different thresholds:
- Alert at **>200ms** for p99
- Plot at >100ms for p95

**Tradeoff:** 150ms at p95 is a reasonable SLO for an order processing system with near-real-time expectations. The plan's choice is valid. But for batch workloads, this would be overly aggressive. The plan should document that 150ms is a starting point, not a universal truth.

---

## 5. Compensation activities should retry indefinitely (no `schedule_to_close_timeout`)

**Rating: ⚠️ Internally conflicted — the plan contradicts itself**

The plan's "Key Architecture Decisions" table states:
> "No `schedule_to_close_timeout` on compensation activities — Temporal knowledge base: compensation activities must retry indefinitely. A timed-out refund leaves the customer charged."

But the "Outstanding fixes" section says:
> "Add `schedule_to_close_timeout=timedelta(hours=24)` to `_run_compensations()` — satisfies guideline 'don't leave unlimited attempts without schedule_to_close_timeout.'"

**What the KB actually says:** From official support staff directly on this question:
> "Keep retrying the compensation activity until it succeeds."
> "StartToClose timeout should be set. But not `schedule_to_close`."
> "And no workflow timeouts."

The KB examples in the Saga documentation consistently use `start_to_close_timeout` on compensations but not `schedule_to_close_timeout`. The KB's position is clear: **indefinite retry is correct for compensations**. Adding a 24-hour `schedule_to_close_timeout` means a compensation can permanently fail after 24 hours if a payment system is down — leaving the customer in a charged-but-not-refunded state.

**Decision:** Remove `schedule_to_close_timeout` from compensations. Set only `start_to_close_timeout` (for the individual attempt) and `max_attempts=0` (unlimited). This is the KB-endorsed behavior and the "Key Architecture Decisions" table had it right; the "Outstanding fixes" section is wrong.

---

## 6. `temporal-dev` namespace instead of `default`

**Rating: ✅ Confirmed**

The KB is unambiguous:
> "Environments such as production and development usually have requirements for isolation. We recommend that each environment has its own Namespace."
> "Use Temporal Namespaces to isolate workflows for different environments (e.g. development, staging, production). Each Namespace is logically segregated."

Namespace naming convention from the KB: `<use-case>-<domain>-<environment>` — so `order-workflow-dev` would be more idiomatic than `temporal-dev`, but the concept is correct.

**Tradeoff the plan understates:** Changing the namespace from `default` to `temporal-dev` means existing workflow history in `default` is inaccessible. All workers, clients, and the API service must be updated simultaneously. If you have any in-flight workflows in `default` at migration time, they will be orphaned. The plan should include a cutover strategy.

---

## 7. Running all four Temporal services in one ECS task (`SERVICES=history,matching,frontend,worker`)

**Rating: ⚠️ Acceptable for dev/cost constraint but documented as a production anti-pattern**

The KB is explicit that services should run in separate processes for independent scaling:
> "When we say to run each of these services separately in production so they can be independently scaled, this is the exact step where production differs from local development."

The blog post describes the production pattern as separate processes per service. Running `SERVICES=history,matching,frontend,worker` in a single ECS task means:
- A history service OOM kills the frontend
- You cannot scale matching independently from history
- A task crash takes down all four services

**The plan's tradeoff is real:** Splitting into four separate ECS task definitions quadruples operational complexity, costs more (four separate ECS services, four ALB/NLB target groups), and is overkill for a dev/learning environment. The plan should document this explicitly as a dev compromise, not present it as production-appropriate.

---

## 8. `TEMPORAL_BROADCAST_ADDRESS = "127.0.0.1"` for single-node

**Rating: ✅ Confirmed as a practical single-node fix**

The KB examples show `broadcastAddress` being set to the pod/host IP for Ringpop membership discovery. Setting it to `127.0.0.1` for a single-node deployment where all services share a process is consistent with how the Temporal team handles this in their own docker-compose files.

**Tradeoff:** This setting breaks multi-node clustering. If you ever add a second EC2 instance and try to run a second temporal-server task, Ringpop will broadcast `127.0.0.1` to the ring and the nodes will not discover each other. The plan's ASG min=2 could cause exactly this problem if two instances both run `temporal-server` with `BROADCAST_ADDRESS=127.0.0.1`. This needs to be resolved: either pin temporal-server to one instance via ECS placement constraint, or set `BROADCAST_ADDRESS` to the actual EC2 instance private IP (injected via ECS metadata endpoint).

---

## 9. Prometheus scraping Worker metrics via EC2 Service Discovery

**Rating: ✅ Correct approach for bridge network mode**

The KB confirms that schedule-to-start latency and slot metrics are emitted by the SDK from the Worker process. EC2 SD on port 9090 is the right way to discover workers in bridge network mode where no stable ENI IP exists.

**Gap in the plan:** The Prometheus scrape config uses an `AmazonECSManaged` tag filter. This tag is automatically applied to EC2 instances launched by ECS capacity providers — but the plan uses a plain ASG with a launch template, not an ECS Capacity Provider. The tag may not be present. Verify the tag exists or use a different filter (e.g., tag the ASG instances explicitly).

---

## 10. Scraping Temporal Server metrics on port 8000

**Rating: ✅ Confirmed**

The KB forum examples and docker-compose configs consistently use `PROMETHEUS_ENDPOINT=0.0.0.0:9090` for the Temporal server (not 8000). The plan assigns port 8000 to the server metrics endpoint and 9090 to the worker. This is configurable — just make sure the port doesn't conflict with the API service, which the plan also puts on 8000 (ALB → API). This is a port collision risk that the plan doesn't address.

**Action needed:** Use a distinct port for Temporal server metrics, e.g., `8001`, or confirm the API service uses a different bind address than the metrics endpoint.

---

## 11. ASG min=2, Worker ECS min_capacity=2

**Rating: ✅ Confirmed**

The KB explicitly states:
> "Best practice is to always have more than one [Worker]."

And for rolling deployments:
> "During ECS rolling deployment, if min=1, one worker is stopped before the replacement is healthy. All in-flight activities stall."

This is correct and well-reasoned.

---

## 12. Worker `max_concurrent_activities=20`, `max_concurrent_workflow_tasks=50`

**Rating: ⚠️ Not cross-checked with actual load — these are reasonable starting points, not tuned values**

The KB's tuning guidance says to start with defaults and tune based on `worker_task_slots_available` going to zero. The Python SDK default for `max_concurrent_activities` is 100 (not 20). Setting it to 20 is conservative.

**Tradeoff:** 20 activity slots × 2 workers = 40 concurrent activities minimum. If your fraud/payment/shipping calls take 500ms each (reasonable for external APIs), that's 80 activities/second theoretical throughput. For order processing this may be fine, but the plan should justify 20 vs. the SDK default of 100 — or acknowledge it's a starting point to be tuned.

---

## 13. EFS for Prometheus and Grafana persistence

**Rating: ✅ Confirmed as necessary**

The plan correctly identifies that without EFS, every Prometheus restart loses all metric history. This matches Week 6's pattern and is the correct approach for persistent storage on ECS.

**Tradeoff not mentioned:** EFS introduces a latency overhead (~1-2ms per write) vs. local NVMe. For Prometheus TSDB this is acceptable. But if Prometheus scrape intervals are very short (<5s) and cardinality is high, this can become a bottleneck. For a dev cluster scraping ~10 targets every 15s, this is a non-issue.

---

## 14. Reusing PostgreSQL RDS for Grafana (adding `grafana` database)

**Rating: ✅ Reasonable for dev, with one caveat**

The plan correctly avoids spinning up a second RDS instance. Grafana's PostgreSQL support is well-established.

**Tradeoff:** Grafana and Temporal share the same RDS instance. A Grafana schema migration or a noisy Grafana query could impact Temporal's DB performance. For dev this is fine. For production, separate RDS instances (or at minimum separate DB users with resource limits) would be appropriate.

---

## 15. `graceful_shutdown_timeout` + `stopTimeout: 30s`

**Rating: ✅ Confirmed**

The KB explicitly flags this:
> "Ensure graceful shutdown so Workers complete in-flight Tasks before termination. Set appropriate termination grace periods."

30 seconds is a reasonable value. The plan's combination of signal handler + `graceful_shutdown_timeout` + ECS `stopTimeout` is the correct three-layer approach.

---

## Summary of Tradeoffs

| Decision | KB Status | Key Tradeoff |
|---|---|---|
| `server` image + `sql-tool` | ✅ Confirmed | Single-task co-location is still a dev pattern |
| `AUTO_UPGRADE` default | ❌ Wrong for OrderWorkflow | Should be `PINNED` — workflow completes in minutes |
| CPU 25% scaling | ⚠️ Fallback only | Correct signal is `activity_schedule_to_start_latency` p95 + slot depletion |
| 150ms alert threshold | ✅ Confirmed | Batch workloads need higher threshold |
| No `schedule_to_close` on compensations | ✅ Correct (KB table wins) | Outstanding fix section contradicts this — remove the 24h timeout |
| `temporal-dev` namespace | ✅ Confirmed | Need a cutover strategy for in-flight workflows in `default` |
| All services in one task | ⚠️ Dev compromise | Breaks independent scaling — document explicitly |
| `BROADCAST_ADDRESS=127.0.0.1` | ⚠️ Single-node only | Breaks if second EC2 also runs temporal-server |
| EC2 SD for Prometheus | ✅ Correct | Verify ECSManaged tag is actually applied |
| Server metrics port 8000 | ⚠️ Port collision risk | Conflicts with API service on port 8000 — use 8001 |
| ASG min=2, worker min=2 | ✅ Confirmed | — |
| Activity slots 20 | ⚠️ Conservative | SDK default is 100; justify or treat as starting point |
| EFS for Prometheus/Grafana | ✅ Confirmed | Minor latency overhead; non-issue at dev scale |
| Shared RDS for Grafana | ✅ Dev acceptable | Separate for production |
| Graceful shutdown 30s | ✅ Confirmed | — |
