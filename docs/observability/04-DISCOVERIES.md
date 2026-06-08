# Observability Gotchas When Running Temporal (and any app) on AWS ECS — Field Notes Not in the Docs

> Self-contained write-up of non-obvious issues hit while building a Prometheus/Grafana observability stack for a Temporal-on-ECS platform. Each entry: **symptom → root cause → fix**. These are AWS-ECS + Prometheus integration gotchas; most apply to *any* awsvpc workload, not just Temporal. Shared for the community.

---

## 1. `awsvpc` ECS tasks **cannot** be scraped via EC2 service discovery

**Symptom:** Prometheus `ec2_sd_configs` is configured, the EC2 IAM permission is present, instances carry the tag filter — yet the target list is empty / unreachable, and server & worker metrics never appear. Node-exporter (also EC2-SD) works fine.

**Root cause:** EC2 service discovery returns the **EC2 host's** private IP. That is correct for a `host`-network container (its ports live on the host NIC). But an **`awsvpc`** task gets its **own ENI with its own private IP** — its metrics port is bound there, *not* on the host. So Prometheus dutifully scrapes `hostIP:8001`, where nothing is listening.

**Fix:** discover awsvpc tasks via **AWS Cloud Map DNS service discovery**, not EC2-SD. Register the ECS service in Cloud Map; ECS auto-publishes each task's ENI IP as an A-record. Point Prometheus at the DNS name:

```yaml
- job_name: temporal-server
  dns_sd_configs:
    - names: ['server-metrics.my-namespace.local']
      type: A
      port: 8001
      refresh_interval: 15s
```

Choose the **routing policy** by workload shape:
- **MULTIVALUE** for horizontally-scaled services (workers) — the A-record returns *every* task IP, so Prometheus scrapes all replicas.
- **WEIGHTED** for singletons (the server) — one record.

**Rule of thumb:** `host` network → EC2-SD. `awsvpc` network → Cloud Map DNS-SD.

---

## 2. Adding `service_registries` to a running ECS service does **nothing** until you redeploy

**Symptom:** You add Cloud Map registration to the ECS service, `terraform apply` succeeds, but DNS returns no records and Prometheus still finds no targets.

**Root cause:** Cloud Map registration happens at **task launch**. Already-running tasks are *not* retroactively registered when you attach a service registry.

**Fix:** force new tasks so they register:
```bash
aws ecs update-service --cluster <c> --service <s> --force-new-deployment
```
Verify with `getent hosts <service>.<namespace>.local` from inside the VPC — you should see one A-record per task.

---

## 3. Grafana provisioned-dashboard JSON: over-escaped quotes silently break label-matcher queries

**Symptom:** Some dashboard panels show **"No data"** while others on the *same datasource* work. The broken ones all have PromQL **label matchers** (e.g. `{job="x"}`); the working ones use bare metrics or recording rules. Running the exact query in the Prometheus UI returns data — so the metric exists.

**Root cause:** In the dashboard JSON, the queries were **triple-backslash-escaped**:
```
"expr": "count(up{job=\\\"temporal-worker\\\"} == 1)"
```
`\\\"` decodes (JSON) to a *literal backslash + quote*, so Grafana sent Prometheus `count(up{job=\"temporal-worker\"} == 1)` — invalid PromQL → matches nothing → "No data". Panels without label matchers had no quotes to mangle, which **masked** the bug.

**Fix:** single-escape the inner quotes so the decoded PromQL is clean:
```
"expr": "count(up{job=\"temporal-worker\"} == 1)"
```
This usually comes from a query being escaped twice (once by hand, once by a templating/HCL layer). Always validate a provisioned dashboard by reading back the rendered `expr` Grafana actually stored.

---

## 4. Mixing inline and standalone Security-Group rules causes perpetual churn / stale SGs

**Symptom:** Every `terraform apply` shows SG rules being revoked and re-added; occasionally a task ends up attached to a *stale* SG missing a rule you "already added," breaking connectivity (e.g. Prometheus → target).

**Root cause:** Defining ingress/egress **inline** in `aws_security_group` *and* as standalone `aws_security_group_rule` resources on the same SG makes Terraform fight itself — the inline block treats the standalone rules as drift to remove, and vice-versa.

**Fix:** pick **one** model. We standardized on **standalone `aws_security_group_rule`** for all cross-SG references (cleaner for breaking circular dependencies between SGs) and kept inline blocks out. Never mix them on one SG.

---

## 5. Server metrics vs SDK metrics: different prefixes, different units

**Symptom:** Queries return nothing because the metric name/label/unit is subtly wrong.

**Root cause / facts:**
- **Temporal Server** emits **unprefixed** metrics: `workflow_success`, `poll_success`, `persistence_latency_*`.
- **The SDK** emits **`temporal_`-prefixed** metrics: `temporal_workflow_completed`, `temporal_activity_schedule_to_start_latency_*`.
- **Core SDK (Python/TS/Go via Core) histograms are in MILLISECONDS with no `_seconds` suffix.** A 150 ms threshold is `150`, not `0.15`. (The **Java** SDK appends `_seconds` and uses seconds.)

**Fix:** for a self-hosted OSS cluster, source the authoritative SLO from **server** metrics (they include server-side timeouts/terminations the SDK never sees) and use **SDK** metrics for per-`workflow_type` golden signals. Mind the ms-vs-seconds unit in thresholds.

To expose server metrics in the first place, set on the server container:
```
PROMETHEUS_ENDPOINT=0.0.0.0:8001
```
(We used `:8001` to avoid colliding with the API's `:8000` on shared hosts.) The worker exposes SDK metrics via the SDK runtime, e.g. Python:
```python
TelemetryConfig(metrics=PrometheusConfig(bind_address="0.0.0.0:9090"))
```

---

## 6. `temporal_worker_task_slots_*` is emitted by **two** sources — server *and* worker

**Symptom:** Worker-capacity panels show wrong/duplicated numbers, or data appears even when your app workers are down.

**Root cause:** The `temporalio/auto-setup` (and the server's internal `worker` role) runs **internal Go system workers** that emit the *same* `temporal_worker_task_slots_*` metric — scraped under `job=temporal-server`, with `client_name=temporal_go` and `task_queue=temporal_sys_*`. Your application worker emits it under `job=temporal-worker` (`service_name=temporal-core-sdk`, `task_queue=<your-queue>`).

**Fix:** always filter app-capacity queries by `job` or `task_queue`:
```promql
sum(temporal_worker_task_slots_available{job="temporal-worker", worker_type="ActivityWorker"})
```

---

## 7. SNS email alerts are silent until the subscription is **confirmed**

**Symptom:** Alerts fire in Prometheus/AlertManager, the SNS publish succeeds, but no email arrives.

**Root cause:** An SNS email subscription starts as **`PendingConfirmation`**. AWS sends a one-time confirmation email; until the recipient clicks the link, SNS drops messages to that endpoint.

**Fix:** check `aws sns list-subscriptions` — if status isn't `Confirmed` (shows `PendingConfirmation` or empty `SubscriptionArn`), open the AWS confirmation email and click through. Then re-test by stopping a worker and waiting for `TemporalWorkerDown` (note: rules with `for: 2m` need ~2 min before firing).

---

## 8. Prometheus TSDB on EFS works but warns "filesystem not supported"

**Symptom:** Prometheus logs `fs_type=NFS_SUPER_MAGIC ... This filesystem is not supported and may lead to data corruption`.

**Root cause:** Prometheus officially supports only local POSIX filesystems for its TSDB; EFS is NFS. We used EFS to persist the TSDB across `awsvpc` task restarts (otherwise every restart wipes history).

**Fix / stance:** acceptable for a dev/single-writer setup (one Prometheus, low write rate). For production high-cardinality/high-write TSDB, use a local/EBS volume and ship to long-term remote storage (Thanos/Mimir/Cortex) instead of EFS.

---

### TL;DR cheat-sheet
- awsvpc → **Cloud Map DNS-SD**, not EC2-SD.
- Service-registry changes need **`--force-new-deployment`**.
- Validate provisioned-dashboard `expr` for **over-escaped quotes**.
- **Never mix** inline + standalone SG rules.
- Server metrics = **unprefixed**; SDK = **`temporal_`** + **milliseconds**.
- `task_slots_*` comes from server *and* worker — **filter by `job`**.
- **Confirm** the SNS email subscription.
- EFS-for-TSDB is a **dev** convenience, not a prod pattern.
