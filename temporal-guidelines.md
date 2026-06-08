# Temporal Developer Guidelines — Do's and Don'ts

> Source: Temporal official documentation, courses (101/102), knowledge base, and production best practices.  
> Language focus: **Python SDK**

---

## 1. Workflow Definitions

### ✅ DO

- Keep Workflow code **deterministic** — every execution must produce the same sequence of commands on replay.
- Use `workflow.now()` instead of `datetime.datetime.now()` for current time.
- Use `workflow.uuid4()` to generate UUIDs inside a Workflow.
- Use `asyncio.gather()` for parallel execution of child workflows or activities — this is safe in the Python SDK.
- Use `workflow.wait_condition()` for human-in-the-loop or event-driven pauses.
- Use `workflow.logger` for logging inside Workflows (not the standard `logging` module directly).
- Model Workflow inputs and outputs as **dataclasses or serializable data structures** to support backwards-compatible evolution.
- Choose **meaningful, deterministic Workflow IDs** (e.g. `order-{order_id}`) — Temporal guarantees uniqueness per namespace.
- Use `workflow.upsert_search_attributes()` to track business state for observability and filtering.
- Use `@workflow.signal`, `@workflow.query`, and `@workflow.update` for external interaction with running Workflows.
- Handle the difference between **signals** (async, no return) and **updates** (sync, returns value, can validate).

### ❌ DON'T

- **Never call external services, databases, file systems, or network APIs directly from Workflow code.** Put all I/O in Activities.
- **Never use `datetime.datetime.now()`** in a Workflow — use `workflow.now()` instead. The Python sandbox will fail if you try.
- **Never use random numbers directly in a Workflow** — generate them in an Activity and pass the result back.
- **Never use raw threads** (`threading.Thread`) in a Workflow — use `asyncio` constructs instead.
- **Never store or evaluate `run_id`** in conditional logic — it can change across retries and Continue-as-New.
- **Never iterate over unordered data structures** (sets, unsorted dicts from external sources) when the order affects which Activities are called — always sort first.
- **Never call LLM or AI APIs directly from Workflow code** — they are non-deterministic even when the network call succeeds (same prompt, different response).
- **Never add, remove, or reorder Activities in a running Workflow without versioning** — this causes non-determinism errors on replay.

---

## 2. Activity Definitions

### ✅ DO

- **Always set `start_to_close_timeout`** on every Activity — this is required and is how Temporal detects a Worker crash.
- Set `start_to_close_timeout` to **slightly longer than the slowest successful execution** you expect.
- Make Activities that perform **writes idempotent** — Activities have at-least-once execution guarantees on retry.
- Use **idempotency keys** for operations like payment charges to prevent duplicate effects on retry:
  ```python
  idempotency_key = f"charge-{order.order_id}-{activity.info().workflow_run_id}"
  ```
- Use `activity.info().attempt` to detect retry attempt number inside an Activity.
- For **long-running Activities**, call `activity.heartbeat()` periodically and set a `heartbeat_timeout`.
- Use `ApplicationError` to raise non-retryable errors for business logic failures (e.g. fraud detected).
- Return serializable values (dataclasses, primitives) from Activities.
- Each Activity Execution **can have its own Retry Policy** — tune per use case.

### ❌ DON'T

- **Never set `start_to_close_timeout` too long without heartbeating** — a 12-hour timeout means Temporal won't retry for 12 hours if a Worker crashes.
- **Never set `maximum_attempts=1` just to avoid retries for non-idempotent operations** — make the operation idempotent instead. Setting max attempts to 1 means a network outage before the call will permanently fail the Activity.
- **Never set `schedule_to_start_timeout` unless you are doing host-specific task routing** — this is rarely needed and is not a substitute for `start_to_close_timeout`.
- **Never ignore heartbeat failures** in a long-running Activity — if heartbeat throws, cancel and exit the Activity.
- **Don't assume an Activity runs exactly once** — design for at-least-once. Two attempts of the same Activity can run simultaneously if a Worker crashes mid-execution.

---

## 3. Retry Policies

### ✅ DO

- Always configure a `RetryPolicy` for Activities that call external services.
- Use **exponential backoff** (`backoff_coefficient=2.0`) to prevent thundering herd on downstream services.
- Set `maximum_interval` to cap backoff at a reasonable ceiling (e.g. 60 seconds or less).
- Use `non_retryable_error_types` to stop retrying on known permanent failures (e.g. `InvalidOrderError`).
- Use different Retry Policies for different Activity Executions — payment vs. notifications have different retry needs.

### ❌ DON'T

- **Don't leave `maximum_attempts` at 0 (unlimited)** for Activities calling external services without also setting `schedule_to_close_timeout` — this can cause infinite retries.
- **Don't use identical retry settings for all Activities** — a short timeout appropriate for a fraud check is wrong for a file upload.

---

## 4. Timeouts Reference

| Timeout | What It Limits | Recommendation |
|---|---|---|
| `start_to_close_timeout` | Single attempt max duration | **Always set this.** Slightly longer than slowest expected success. |
| `schedule_to_close_timeout` | Total time including all retries | Set when you need a hard deadline across all attempts. |
| `heartbeat_timeout` | Max time between heartbeats | Set for long-running activities. Keep short (seconds/minutes). |
| `schedule_to_start_timeout` | Time sitting in Task Queue | Rarely needed. Only for host-specific routing. |

---

## 5. Saga Pattern / Compensation

### ✅ DO

- Register compensations **after** the forward step succeeds — only undo something that actually happened.
- Execute compensations in **LIFO order** (last registered = first to run).
- Make each compensation Activity **idempotent** — it may be retried.
- Continue running remaining compensations even if one fails — log the failure but don't block others:
  ```python
  # CORRECT: continue on compensation failure
  while self._compensations:
      comp = self._compensations.pop()
      try:
          await workflow.execute_activity(comp["activity"], comp["input"], ...)
      except Exception as e:
          workflow.logger.error("Compensation failed: %s", e)
          # Do NOT re-raise — continue remaining compensations
  ```

### ❌ DON'T

- **Don't re-raise inside a compensation loop** — this blocks all remaining compensations from running.
- **Don't register compensations before the forward step runs** — if the forward step never ran, there's nothing to undo.

---

## 6. Signals, Updates, and Queries

| Feature | Async? | Returns Value? | Use For |
|---|---|---|---|
| Signal | Yes | No | Fire-and-forget state mutations (cancel, proceed) |
| Update | No | Yes | Synchronous validated state changes with response |
| Query | Read-only | Yes | Snapshot current state without side effects |

### ✅ DO

- Use **Queries** for read-only state inspection — they work on both running and completed Workflows.
- Use **Updates** when the caller needs confirmation or a return value.
- Use **Signals** for asynchronous events where the caller doesn't need to wait.
- Pre-check workflow status before sending signals (return 400 if not RUNNING).

### ❌ DON'T

- **Don't mutate Workflow state inside a Query handler** — Queries are read-only.
- **Don't send Updates to completed Workflows** — Temporal rejects them automatically, but handle the error gracefully.

---

## 7. Worker Deployment

### ✅ DO

- Treat Workers as **long-running services** produced by a CI/CD pipeline.
- Inject all configuration (`TEMPORAL_ADDRESS`, `TEMPORAL_NAMESPACE`, `TEMPORAL_TASK_QUEUE`) via **environment variables** at runtime.
- Use **Worker Versioning** (`VersioningBehavior.PINNED` or `AUTO_UPGRADE`) for production deployments — this is the recommended default.
- Use **Kubernetes ConfigMaps** for non-sensitive config and **Secrets** for mTLS certs and API keys.
- Use the **Temporal Worker Controller** on Kubernetes for progressive, safe rollouts with automatic rollback.
- Run **replay tests in CI** before deploying new Workflow code:
  ```python
  replayer = Replayer(workflows=[OrderWorkflow])
  await replayer.replay_workflow(WorkflowHistory.from_json(...))
  ```
- Emit **Prometheus metrics** from the Worker by configuring `PrometheusConfig` on `Runtime`.
- Scale Workers based on **`schedule_to_start_latency`**, not CPU/memory.

### ❌ DON'T

- **Don't use `temporalio/auto-setup` in production** — it runs schema migrations on every startup. Use a one-time migration Job instead.
- **Don't rely on default Worker options** — they are tuned for development, not production.
- **Don't scale Workers on CPU/memory alone** — Workers can be idle CPU-wise while task queues are backed up.
- **Don't deploy new Workflow code without versioning** if Workflows are currently running — this causes non-determinism errors on replay.
- **Don't run your Temporal database (RDS/PostgreSQL) inside Kubernetes** alongside the Temporal server — use a managed external database.

---

## 8. Observability

### ✅ DO

- Set up **Prometheus metrics** scraping from both the Temporal Server and the Python Worker SDK.
- Alert on these key metrics:
  - `activity_schedule_to_start_latency` p95 > 150ms → Workers can't keep up
  - `workflow_task_schedule_to_start_latency` p95 > 150ms → Workflow pollers insufficient
  - `worker_task_slots_available` = 0 → Workers saturated
  - Poll Sync Rate < 99% → Tasks being flushed to DB (inefficient)
- Use **OpenSearch/Elasticsearch** for Workflow visibility and Search Attribute queries in production.
- Register **Search Attributes** (like `OrderStatus`) as a one-time automated Job — not a manual step.
- Add **OpenTelemetry tracing** via `TracingInterceptor` for distributed trace across Workflow and Activity calls.

### ❌ DON'T

- **Don't use bundled Elasticsearch/Prometheus/Grafana from the Helm chart in production** — they are dev-only configurations.
- **Don't rely solely on CloudWatch or container logs** for Temporal health — Temporal-specific metrics give much richer signals.

---

## 9. Namespaces

### ✅ DO

- Use **separate namespaces** for `dev`, `staging`, and `prod` environments.
- Register Search Attributes **per namespace** — they are namespace-scoped.
- Set the **Retention Period** appropriately per namespace (default 30 days; Cloud allows 1–90 days).
- Use Namespace isolation to prevent noisy-neighbor problems between teams or applications.

### ❌ DON'T

- **Don't share a production namespace with development or test workloads.**
- **Don't increase the Retention Period unnecessarily** — it increases storage costs. Data for running Workflows is always available regardless of retention.

---

## 10. Data and Serialization

### ✅ DO

- Use **dataclasses** (not Pydantic models) for Workflow and Activity input/output in the Python SDK — they serialize reliably with Temporal's codec.
- **Model inputs and outputs as objects/structs**, not positional arguments — this enables backwards-compatible evolution (add optional fields without breaking existing callers).
- Use a **Codec Server** if Workflow payloads contain sensitive data — encrypt payloads before they reach Temporal Server.

### ❌ DON'T

- **Don't use raw primitives or untyped dicts as Workflow inputs** — they're hard to evolve safely.
- **Don't log sensitive data** from Workflow payloads — Temporal stores event history, and logs may expose it.
- **Don't pass mutable global state** into Workflow or Activity functions.

---

## Quick Reference Checklist

Before calling code production-ready, verify:

- [ ] Every Activity has `start_to_close_timeout` set
- [ ] Write Activities are idempotent (have idempotency keys)
- [ ] Long-running Activities heartbeat and have `heartbeat_timeout` set
- [ ] Saga compensations continue on individual failure (no re-raise in loop)
- [ ] Workflow code has no direct I/O (DB, HTTP, file system)
- [ ] No `datetime.datetime.now()` or raw random numbers in Workflow code
- [ ] `run_id` is not stored or used in conditional logic
- [ ] Worker configuration injected via environment variables
- [ ] Prometheus metrics endpoint enabled on Worker
- [ ] Replay tests exist in CI for all Workflow definitions
- [ ] Worker Versioning (`PINNED` or `AUTO_UPGRADE`) configured
- [ ] Separate namespaces for dev/staging/prod
- [ ] Search Attributes registered via automated Job (not manual CLI)
- [ ] External database (RDS) used — not bundled Helm DB
