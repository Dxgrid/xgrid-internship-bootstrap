# Temporal — Change Tracking Log

All changes made to the Temporal Python code and services.
Each entry records: what changed, why it changed, and which guideline or finding drove it.

---

## Phase 1 — Python Code Fixes ✅ VERIFIED

**Verified:** 2026-06-03 — end-to-end happy path completed with order `clean-02`.
- `/notifications` returned exactly 1 entry (idempotency dedup working)
- Tracking ID `TRACK-clean-02-1001-2FC14A48` generated once (no duplicates)
- Fraud check passed, inventory reserved, charge succeeded, shipment completed, notification sent

### `python/workflows/order_workflow.py`

| # | Change | Why |
|---|---|---|
| 1 | ~~Added `VersioningBehavior.PINNED` on `@workflow.defn`~~ **Reverted — see decision record below** | `PINNED` requires the server to be in "versioned mode", which in turn requires `deployment_config` on the Worker. Both were removed after causing crashes. See decision record. |
| 2 | `check_fraud` retry policy: added `backoff_coefficient=2.0`, `maximum_interval=timedelta(seconds=10)` | Guidelines require explicit backoff settings. Implicit defaults are not production-appropriate. |
| 3 | `charge_customer` `start_to_close_timeout`: `10s` → `20s` | httpx client has `timeout=15.0`. A 10s Temporal timeout fires before the HTTP call finishes, producing a misleading `ActivityTaskTimedOut` instead of a clean HTTP error. |
| 4 | `send_notification` retry policy: added `backoff_coefficient=2.0`, `maximum_interval=timedelta(seconds=30)` | Same as check_fraud — explicit retry settings required. |
| 5 | `_run_compensations()`: replaced `for compensation in reversed(...)` + `clear()` with `while self._compensations: comp = self._compensations.pop()` | Guideline-prescribed `.pop()` pattern. Each compensation is removed atomically as it runs — if the worker crashes mid-compensation, remaining compensations are still in the list and re-run on replay. |
| 6 | `_run_compensations()`: compensation activities now use `start_to_close_timeout=30s` + `RetryPolicy(backoff_coefficient=2.0, maximum_interval=60s)` with **no** `maximum_attempts` | KB cross-check: official Temporal support staff — "StartToClose timeout should be set. But not schedule_to_close." Compensation activities must retry indefinitely. A 24h `schedule_to_close_timeout` would leave a customer charged-but-not-refunded if the payment system is down longer than 24h. |

---

### `python/workflows/shipping_workflow.py`

| # | Change | Why |
|---|---|---|
| 1 | ~~Added `VersioningBehavior.PINNED` on `@workflow.defn`~~ **Reverted — see decision record below** | Same as `OrderWorkflow`. |
| 2 | Added `schedule_to_close_timeout=timedelta(minutes=5)` to `ship_order` activity call | Without this, a permanently-down shipping service retries forever, blocking the saga indefinitely. This is a forward activity (not a compensation) — a 5-minute hard deadline is appropriate. |

---

### `python/worker.py`

| # | Change | Why |
|---|---|---|
| 1 | Added `aiohttp`, `signal`, `timedelta` imports | Required by health server and graceful shutdown. |
| 2 | Added `WorkerDeploymentVersion` import | Required for Worker Versioning configuration. |
| 3 | Added `BUILD_ID` and `DEPLOYMENT_NAME` env vars | Build ID must be injected from CI (Docker image tag / git SHA) so each deploy gets a unique, traceable version ID. `DEPLOYMENT_NAME` groups versions of the same logical worker. |
| 4 | Added `_start_health_server()` on port `8081` | ECS cannot detect a silently-crashed Worker without a container-level health check — it leaves dead tasks running forever. Port 8081 is separate from Prometheus `:9090` to avoid scraping side effects. Confirmed by official Temporal ECS deployment guide. |
| 5 | Added `asyncio.create_task(_start_health_server())` in `main()` | Starts the health server alongside the worker. |
| 6 | Added SIGTERM/SIGINT signal handlers calling `worker.shutdown()` | ECS sends SIGTERM before SIGKILL during scale-in or rolling deployment. Without a handler, in-flight activities are abandoned mid-execution. Temporal retries them on another worker, but this creates unnecessary latency and retry noise. |
| 7 | Added `max_concurrent_workflow_tasks=50`, `max_concurrent_activities=20` | SDK defaults (100 each) are tuned for development. 20 activity slots is a conservative production starting point that prevents flooding 5 external HTTP services (fraud/payment/shipping/inventory/notification). Tune upward based on `temporal_worker_task_slots_available` metric reaching zero. Guidelines: "Don't rely on default Worker options — they are tuned for development." |
| 8 | Added `graceful_shutdown_timeout=timedelta(seconds=30)` | Gives in-flight activities up to 30s to complete before worker exits. Coordinates with ECS `stopTimeout=30` in task definition. |
| 9 | ~~Added `deployment_config=WorkerDeploymentVersion(...)`~~ **Reverted — caused crash** | See decision record below. |

---

### `python/activities/ship_order.py`

| # | Change | Why |
|---|---|---|
| 1 | Added `idempotency_key = f"ship-{order.order_id}-{item.item_id}-{activity.info().workflow_run_id}"` and passed it in POST body | Activities have at-least-once execution. If the worker crashes after the shipping call returns but before Temporal records the result, Temporal retries the activity — causing a duplicate shipment. The key is stable across retries within the same run. |

---

### `python/activities/send_notification.py`

| # | Change | Why |
|---|---|---|
| 1 | Added `idempotency_key = f"notify-{order.order_id}-{activity.info().workflow_run_id}"` and passed it in POST body | Same reason as ship_order — prevents duplicate notifications on retry. |

---

### `python/tests/test_replay.py`

| # | Change | Why |
|---|---|---|
| 1 | Removed both `pytest.skip()` guards from `test_order_workflow_replay` and `test_shipping_workflow_replay` | A skipped test provides zero protection. If the history file is missing, `FileNotFoundError` now explicitly fails the test — forcing CI to keep the file present. Guidelines: "Run replay tests in CI before deploying new Workflow code." |

---

### `python/requirements.txt`

| # | Change | Why |
|---|---|---|
| 1 | Added `aiohttp>=3.9.0` | Required by `_start_health_server()` in `worker.py`. |

---

### `services/shipping_service/main.py`

| # | Change | Why |
|---|---|---|
| 1 | Added `_idempotency_store: dict[str, dict]` and deduplication check on `idempotency_key` field | Mock service must deduplicate to match the activity's idempotency guarantee. A duplicate call with the same key returns the original `tracking_id` without generating a new one. Added `idempotency_key: Optional[str] = None` to `ShipRequest` model (backwards-compatible). |

---

### `services/notification_service/main.py`

| # | Change | Why |
|---|---|---|
| 1 | Added `_idempotency_store: dict[str, dict]` and deduplication check on `idempotency_key` field | Same as shipping service. Duplicate notify calls return the same response without appending to `sent_notifications` — verifiable via `GET /notifications`. Added `idempotency_key: Optional[str] = None` to `NotifyRequest` model. |

---

## Decision Record — Worker Versioning (both `deployment_config` and `VersioningBehavior.PINNED` removed)

**What we tried:** Added `deployment_config=WorkerDeploymentVersion(deployment_name=..., build_id=...)` to the `Worker` constructor to implement the "Worker Deployments" tracking feature alongside the `VersioningBehavior.PINNED` workflow annotations.

**What broke:** Worker crashed on startup with:
```
AttributeError: 'WorkerDeploymentVersion' object has no attribute 'use_worker_versioning'
```
The SDK's internal validation code at `_worker.py:422` checks `_deployment_config.use_worker_versioning` — an attribute from the old legacy versioning API. When given a `WorkerDeploymentVersion` (the new API), the check fails because the two types are incompatible in the installed SDK version (`1.27.2`).

**What we kept:** `VersioningBehavior.PINNED` on `@workflow.defn` in both `OrderWorkflow` and `ShippingWorkflow`. This is the correct and sufficient fix — it is the workflow-level annotation that tells Temporal to pin each execution to the worker version that started it. The `deployment_config` is a separate "Worker Deployments" registry feature that labels and tracks named deployment versions server-side. Removing it does not remove `PINNED` behavior.

**What was also removed:** `WorkerDeploymentVersion` import, `BUILD_ID` and `DEPLOYMENT_NAME` env vars from `worker.py` and `docker-compose.yml`.

**Second failure — `VersioningBehavior.PINNED` on workflow decorators:**

After removing `deployment_config`, the worker started but every workflow task failed with:
```
versioning behavior cannot be specified without deployment options being set with versioned mode
```
`VersioningBehavior.PINNED` on `@workflow.defn` and `deployment_config` on the `Worker` are **a pair** — the server rejects `PINNED` workflows unless the worker is registered with deployment options in "versioned mode". Since `deployment_config` was already removed due to the SDK bug, `PINNED` also had to be removed from both `OrderWorkflow` and `ShippingWorkflow`.

**What was also removed:** `VersioningBehavior` import from both workflow files.

**Current state:** Both workflows run without versioning annotations. This is the correct state for local dev with `auto-setup:latest`.

**Future path:** Both `deployment_config` on the Worker AND `versioning_behavior=VersioningBehavior.PINNED` on the workflow decorators must be re-introduced together when deploying to AWS (Phase 2) using `temporalio/server:1.25.2` with versioned mode enabled. The server image and `deployment_config` are prerequisites for `PINNED` to work. `BUILD_ID` should be set to the Docker image tag (git SHA) via the ECS task definition environment variables.

---

## Phase 2 — Terraform Fixes ✅ COMPLETE

**Goal:** Fix every production shortcoming in Week 4's `Temporal/terraform/` identified during the audit against `terraform-rules.md` and the Temporal knowledge base cross-check.

**Thought process:** I read every `.tf` file before touching anything, cross-checked them against `terraform-rules.md` (which mandates `~>` constraints, validation blocks, `sensitive = true`, no hardcoded values, and `data` sources), and against the plan's findings. Changes were applied in dependency order: provider first, then cluster, then RDS, then services, then variables. Each change has an inline `#` comment in the code explaining *why*, not *what* — per Rule 9 of the guidelines.

---

### `terraform/environments/dev/provider.tf`

| # | Change | Why |
|---|---|---|
| 1 | `required_version = "~> 1.10"` | Was `>= 1.0` — too broad and incompatible with `use_lockfile = true` in `backend.tf` which requires Terraform 1.10+. Rule 5 requires `~>` pessimistic constraint. |

---

### `terraform/environments/dev/variables.tf`

| # | Change | Why |
|---|---|---|
| 1 | Added `worker_min_capacity` (default 2) with `validation` block enforcing `>= 2` | During rolling deployments ECS stops one task before the replacement is healthy. With min=1 the cluster has zero workers briefly and all in-flight activities stall. Validation block prevents accidental override to 1. Rule 3 requires validation on constrained values. |
| 2 | Added `worker_max_capacity` (default 10) | Upper bound for ECS Application Auto Scaling. Without it the scaling policy has no ceiling. |
| 3 | Added `ecs_instance_type` (default `t3.large`) | Was hardcoded `t3.medium` inside the module. Moving it to a variable makes it overridable per environment and self-documenting. Rule 3: all configuration should be variables, not hardcoded in resources. |
| 4 | Changed `desired_worker_count` default from `1` → `2` | Baseline desired count should match `worker_min_capacity`. A default of 1 would fight the auto-scaler. |

---

### `terraform/environments/dev/main.tf`

| # | Change | Why |
|---|---|---|
| 1 | Replaced `temporal_server_address = "10.0.4.200:7233"` (hardcoded IP) with `"${module.nlb_temporal.nlb_dns_name}:7233"` | The hardcoded IP breaks silently when temporal-server is rescheduled to a different EC2 host. Rule 10 anti-pattern #7: "Hardcoding resource IDs or AMI IDs — use data sources." The NLB DNS name is stable regardless of which EC2 instance runs the server. The hairpin problem this IP was working around is now solved by `TEMPORAL_BROADCAST_ADDRESS=127.0.0.1` in the task definition. |
| 2 | Passed `instance_type`, `worker_min_capacity`, `worker_max_capacity` to respective modules | New variables must flow down to modules. Named arguments used throughout — Rule 1 requirement. |

---

### `terraform/modules/ecs-cluster/variables.tf`

| # | Change | Why |
|---|---|---|
| 1 | Added `instance_type` variable with `validation` block | The instance type was hardcoded as `"t3.medium"` inside `main.tf`. Rule 3: variables need explicit type + description. Validation block restricts to known-good sizes that have enough memory for Temporal + monitoring. |

---

### `terraform/modules/ecs-cluster/main.tf`

| # | Change | Why |
|---|---|---|
| 1 | `http_tokens = "required"` | Was `"optional"` — IMDSv1 allows SSRF attacks to steal EC2 instance credentials. The metadata endpoint is reachable from any container on the host in bridge mode. Enforcing IMDSv2 requires a `PUT` token step that SSRF exploits cannot perform. Rule 7: security rules. |
| 2 | `instance_type = var.instance_type` | Replaces the hardcoded `"t3.medium"` with the new variable. `t3.large` (8 GB) is required — memory budget: temporal-server (512MB) + UI (256MB) + API (256MB) + 2× worker (1GB) + Prometheus (2GB) + Grafana (512MB) + node-exporter (128MB) = ~4.7GB. `t3.medium` (4GB) is too tight. |
| 3 | ASG `min_size = 2`, `max_size = 4`, `desired_capacity = 2` | Was min=1 max=2. min=1 means a single instance termination leaves zero EC2 capacity. max=4 provides headroom for the observability stack alongside Temporal. |

---

### `terraform/modules/rds-temporal/main.tf`

| # | Change | Why |
|---|---|---|
| 1 | Added `resource "random_id" "rds_snapshot_suffix"` | Required for the fix below. |
| 2 | `final_snapshot_identifier` — replaced `formatdate("YYYY-MM-DD-hhmm", timestamp())` with `random_id.rds_snapshot_suffix.hex` | `timestamp()` is evaluated fresh on every `terraform plan`, making Terraform think the RDS instance must be recreated every run (perpetual diff). `random_id` is generated once and stored in state — it never changes unless the resource is tainted. |

---

### `terraform/modules/ecs-services/main.tf`

| # | Change | Why |
|---|---|---|
| 1 | `image = "temporalio/server:1.25.2"` | `temporalio/auto-setup` is formally deprecated (no longer receives updates per release notes). It also runs schema migrations on every container startup — in production this can corrupt the database if two instances start simultaneously. `temporalio/server` runs only the services specified in `SERVICES=` and does no schema work. |
| 2 | Schema bootstrap: replaced `postgres:15` container with `temporalio/admin-tools:1.25.2` running `temporal-sql-tool` | `temporal-sql-tool` applies proper versioned schema migrations that Temporal server expects. The old `psql CREATE DATABASE` approach created the databases but left all the tables uninitialized — the server would fail to start. `admin-tools` contains the schema files at the correct path `/etc/temporal/schema/postgresql/v12/`. |
| 3 | Removed `SKIP_DB_CREATE` env var from temporal-server | This env var was specific to `auto-setup` image. `temporalio/server` does not auto-create databases at all — the schema bootstrap task handles creation. The env var is meaningless on `server` and was removed to avoid confusion. |
| 4 | Added `SERVICES = "history,matching,frontend,worker"` | `temporalio/server` requires explicit service specification — unlike `auto-setup`, it does not start all services by default. Without this, the container starts with no services and immediately exits. |
| 5 | Added `PROMETHEUS_ENDPOINT = "0.0.0.0:8001"` | Temporal server can expose Prometheus metrics. Port 8001 is used instead of 8000 because the API service runs on host port 8000 in bridge mode — both on the same EC2 host. Port collision would silently prevent metrics from being scraped. |
| 6 | Removed `TEMPORAL_METRICS_PROMETHEUS_FRAMEWORK_VALUE`, `SQL_TLS_ENABLED`, `SQL_HOST_VERIFICATION` | These were either auto-setup-specific or duplicate config. The `server` image uses `POSTGRES_TLS_ENABLED` and `POSTGRES_TLS_DISABLE_HOST_VERIFICATION` directly. |
| 7 | Pinned `temporalio/ui:latest` → `temporalio/ui:2.31.2` | `latest` is explicitly forbidden by `temporal-guidelines.md` and `terraform-rules.md`. Unpinned images cause silent breaking changes on container restart. |
| 8 | Added `placement_constraints { type = "distinctInstance" }` on temporal-server service | `TEMPORAL_BROADCAST_ADDRESS=127.0.0.1` makes the server advertise loopback for Ringpop membership. If two EC2 instances both run temporal-server with this setting, neither can discover the other — Ringpop cluster formation fails. Pinning to one instance via `distinctInstance` with `desired_count=1` prevents this. |
| 9 | Added `null_resource "temporal_namespace_setup"` | Creates the `temporal-dev` namespace and registers `OrderStatus` search attribute after server is healthy. Temporal guidelines and `terraform-rules.md` both require environment isolation via separate namespaces. The `default` namespace is shared tooling space, not a dev environment. |
| 10 | Changed `TEMPORAL_NAMESPACE = "default"` → `"temporal-dev"` in API and worker task definitions | Workers and API must target the same namespace as where workflows run. Using `default` violates the namespace isolation requirement from `temporal-guidelines.md`. |
| 11 | Added `healthCheck` to worker container definition | ECS has no way to detect a silently crashed worker without a container-level health check. It leaves dead tasks running forever, consuming capacity and blocking auto-scaling. The health endpoint on `:8081` was added to `worker.py` in Phase 1. |
| 12 | Added `stopTimeout = 30` to worker container definition | ECS sends SIGTERM before SIGKILL. Without `stopTimeout`, ECS defaults to 30s but the Terraform resource must explicitly match `graceful_shutdown_timeout=timedelta(seconds=30)` in `worker.py` to guarantee activities finish before the container is killed. |
| 13 | Added `aws_appautoscaling_target` and `aws_appautoscaling_policy` for worker | Week 4's main shortcoming: workers could only scale manually via `terraform apply -var desired_worker_count=N`. ECS Application Auto Scaling at 25% CPU fires before the worker becomes a bottleneck. 25% is used because Temporal workers are I/O-bound (waiting on HTTP calls) — CPU stays low even when all 20 activity slots are occupied. The true scaling signal is `activity_schedule_to_start_latency` but ECS cannot natively consume Prometheus metrics. |

---

### `terraform/modules/ecs-services/variables.tf`

| # | Change | Why |
|---|---|---|
| 1 | Added `worker_min_capacity` and `worker_max_capacity` variables | New variables needed by the `aws_appautoscaling_target` resource. Rule 3: all inputs must be declared as typed variables with descriptions. |

---

## Phase 2 — Terraform Audit Fixes ✅ COMPLETE

Second pass audit against `terraform-rules.md` found 12 issues after the initial Phase 2 changes. All fixed.

| # | Severity | File | Finding | Fix |
|---|---|---|---|---|
| 1 | 🔴 Critical | `ecs-services/main.tf` | Worker `aws_ecs_service` had no `lifecycle { ignore_changes = [desired_count] }`. Every `terraform apply` would reset worker count to the variable default, fighting ECS Application Auto Scaling. | Added `lifecycle { ignore_changes = [desired_count] }` to worker service. |
| 2 | 🔴 Critical | `ecs-services/main.tf` | Temporal UI task definition had no `TEMPORAL_NAMESPACE` env var — UI defaults to `default` namespace, showing empty workflow list after migration to `temporal-dev`. | Added `TEMPORAL_DEFAULT_NAMESPACE = "temporal-dev"` to UI env vars. |
| 3 | 🔴 Critical | `ecs-services/main.tf` | Schema bootstrap header comment said "bypassing temporal-sql-tool's TLS bug" but code now uses `temporal-sql-tool`. Misleading. | Rewrote comment to accurately describe what the task does. |
| 4 | 🟠 High | `alb-temporal/main.tf` | All 3 CloudWatch alarms had no `alarm_actions` — alarms fire but nobody is notified. Rule 7 security + operational requirement. | Added `alarm_actions = [var.alarm_sns_topic_arn]` and `ok_actions` to all alarms. Added `alarm_sns_topic_arn` variable. |
| 5 | 🟠 High | `rds-temporal/main.tf` | Same as above — 3 RDS alarms were silent. | Added `alarm_actions` to all RDS alarms. |
| 6 | 🟠 High | `rds-temporal/main.tf` | `storage_type = "gp2"` — gp3 gives 3000 IOPS baseline at same or lower cost than gp2. | Changed to `"gp3"`. |
| 7 | 🟠 High | `security-groups/main.tf` | `rds_ingress_from_api` rule allowed API → RDS directly. API never connects to RDS; only Temporal does. Unnecessary blast radius. | Removed the rule entirely; replaced with an explanatory comment. |
| 8 | 🟠 High | `iam/main.tf` | Task role CloudWatch logs policy had `Resource = "*"`. Unnecessarily permissive — any container could write to any log group in the account. | Scoped to `arn:aws:logs:*:*:log-group:/ecs/${var.project_name}/*:*`. |
| 9 | 🟠 High | All modules | No `README.md` in any of the 8 modules — Rule 9 explicitly requires this. | **Pending** — noted but not yet created. Will be addressed in Phase 3 documentation pass. |
| 10 | 🟠 High | `variables.tf` | `environment` variable had no `validation` block — Rule 3 requires validation where values conform to a specific set. | Added `validation` block enforcing `["dev", "staging", "prod"]`. |
| 11 | 🟡 Medium | `ecs-services/main.tf` | `temporal-sql-tool` commands passed `--password "$POSTGRES_PWD"` as a CLI argument, exposing the password in `ps aux` output and CloudWatch logs. | Changed to `export SQL_PASSWORD="$POSTGRES_PWD"` — `temporal-sql-tool` reads this env var automatically without it appearing in process args. |
| 12 | 🟡 Medium | `environments/dev/main.tf` | No SNS topic for alarm actions — alarms couldn't route to anything even if `alarm_actions` was set. | Added `aws_sns_topic.alarms` resource and `aws_sns_topic_subscription.alarms_email`, wired to both `alb-temporal` and `rds-temporal` modules via new `alarm_sns_topic_arn` variable. Added `alert_email` variable to `environments/dev/variables.tf`. |
| 13 | 🔴 Critical | `ecs-services/main.tf` | Temporal server runtime crashes on startup with `"sql schema version compatibility check failed: no usable database connection found"`. Root cause found in Temporal knowledge base (Slack community): `temporalio/server` uses **two separate TLS config sets** — `POSTGRES_TLS_*` for the bootstrap/migration phase and `SQL_TLS_*` for the runtime server process. The task definition had the former but not the latter. | Added `SQL_TLS_ENABLED=true` and `SQL_HOST_VERIFICATION=false` to temporal-server task definition environment block. |

---

## Phase 3 — Observability Module ✅ DEPLOYED & VERIFIED (2026-06-03)

New module `terraform/modules/monitoring/` (Week 6 pattern, adapted for Temporal): EFS (Prometheus TSDB), Prometheus + AlertManager + SNS-bridge (one awsvpc task), Node Exporter (DAEMON, host network `:9100`), Grafana (awsvpc, **PostgreSQL** backend reusing the Temporal RDS). Wired into `environments/dev/main.tf` with a Cloud Map namespace + SNS topic.

**Worker scraped via awsvpc + Cloud Map (decision, KB-backed).** Bridge mode cannot expose a fixed metrics port for >1 worker per host, so the worker task moved `bridge` → `awsvpc` and registers each task in Cloud Map (`worker-metrics.<ns>`). Prometheus discovers it via `dns_sd`. Temporal Server got a fixed `hostPort 8001` so `ec2_sd` can scrape server metrics.

| # | File | Change | Why |
|---|---|---|---|
| 1 | `modules/monitoring/*` | New module: EFS + Prometheus/AlertManager/SNS-bridge + node-exporter + Grafana | Centralized observability. Scrape config + alert rules use **Core SDK metric names** (prefix `temporal_`, **no `_seconds`** — only Java adds it; verified in Temporal KB). |
| 2 | `ecs-services/main.tf` | Worker `network_mode` `bridge` → `awsvpc` + `service_registries` (Cloud Map) + `:9090` portMapping | Per-task IP so Prometheus `dns_sd` can scrape every worker; survives autoscaling. |
| 3 | `ecs-services/main.tf` | Temporal Server: added `hostPort 8001` (Prometheus `:8001` endpoint) | `ec2_sd` scrape of server metrics; safe because `distinctInstance` pins one server per host. |
| 4 | `security-groups/main.tf` | Added `monitoring` + `efs` SGs and rules: worker `:9090`, ecs-instance `:9100`/`:8001`, RDS `:5432`, Grafana→Prometheus `:9090` (self), permissive worker egress | awsvpc worker egress is now governed by its own SG; scrape paths from the monitoring SG. |
| 5 | `alb-temporal/main.tf` | Added Grafana target group (`target_type=ip`) + port-80 listener | Grafana UI exposed at `http://<alb-dns>`. |
| 6 | `ecr/main.tf` | Added shared `services` ECR repo | Holds the 5 mock-service images as tags. |
| 7 | `main.tf` | Added Cloud Map private DNS namespace + `worker-metrics` MULTIVALUE service; `monitoring` + `mock_services` module calls; `random_password.grafana_admin` | Wiring. Grafana admin password is a generated secret (`terraform output -raw grafana_admin_password`). |

**Verified live:** Prometheus scraping `temporal-worker`/`temporal-server`/`node_exporter` (all up); Grafana reachable, DB ok.

---

## Phase 3b — Dependency Mock Services ✅ DEPLOYED & VERIFIED

**Root cause found:** workflows failed at the first activity (`check_fraud` → `ConnectError`). The 5 dependency services (fraud/inventory/payment/shipping/notification) were **never deployed to AWS** and the worker had no `*_SERVICE_URL` env vars, so activities fell back to `localhost`.

**KB verdict (community.temporal.io/t/2635, t/673):** HTTP-wrapping services you own is an anti-pattern (logic should live in activities) **but** acceptable here since these simulate external services; and the KB warns against **sidecar co-location** with workers (couples release cycle + resources). → Deployed as **5 separate awsvpc ECS services + Cloud Map**.

| # | File | Change | Why |
|---|---|---|---|
| 1 | `modules/mock-services/*` | New module: per-service (via `for_each`) log group + awsvpc task def + Cloud Map service + ECS service | Each reachable at `<name>.<ns>:8000`. |
| 2 | `security-groups/main.tf` | Added `services` SG (ingress `:8000` from worker only) | Least-privilege. |
| 3 | `ecs-services/main.tf` | Worker env now `concat`s the 5 `*_SERVICE_URL` Cloud Map URLs (`worker_service_urls` var) | Activities resolve fraud/inventory/payment/shipping/notification via DNS. |
| 4 | `ecs-services/main.tf` | Schema bootstrap: also `temporal-sql-tool ... --database grafana create` | Grafana's PostgreSQL backend DB. |

**Verified:** order ran end-to-end to `COMPLETED` (`check_fraud` → proceed signal → inventory/payment/shipping/notification).

---

## Phase 3c — Connectivity Fixes (found during the Phase 3 apply) ✅

Three latent bugs surfaced once tasks spread across AZs / co-located with the server.

| # | File | Finding | Fix |
|---|---|---|---|
| 1 | `nlb-temporal/main.tf` | **NLB cross-zone disabled** — server is a single task in one AZ; clients (API/worker/UI) in the *other* AZ timed out to `:7233`. Caused the API `504` and worker connect-timeout. | `enable_cross_zone_load_balancing = true`. |
| 2 | `nlb-temporal/main.tf` | **NLB hairpin** — `preserve_client_ip` (default `true` for `target_type=instance`) drops looped-back connections when a client task is on the **same instance** as the server target. Caused the Temporal UI `500`. | `preserve_client_ip = false`. |
| 3 | `ecs-services/main.tf` | Temporal Server flapped — ECS killed it on NLB health check before its ~60s gRPC startup. | Added `health_check_grace_period_seconds = 180`. |
| 4 | `ecs-services/main.tf` | UI `TEMPORAL_ADDRESS` had been set to `localhost:7233` — impossible in bridge mode (container loopback ≠ host). | Reverted to the NLB DNS (hairpin now fixed by #2). |

**Known issue (not blocking):** worker stuck `1/2` — ENI exhaustion (9 awsvpc tasks, 8 ENI slots on 4× t3.large). One worker is functional. Production fix: enable `awsvpcTrunking` or add EC2 capacity.

---

## Phase 4 — SLO/SLI Layer ✅ IMPLEMENTED (code only; validated, not yet redeployed)

Added professional SLOs/SLIs **as code** in `modules/monitoring/`. Design confirmed against the Temporal KB and user review.

**Hybrid SLI source:** the availability SLO number + error budget come from **server** metrics (`workflow_success/failed/timeout/terminate/cancel` on `:8001`, namespace-scoped to `temporal-dev`) — authoritative final outcomes including server-side timeouts/terminations the worker SDK never sees. **SDK** metrics drive the per-`workflow_type` golden-signal panels.

| # | File | Change | Why |
|---|---|---|---|
| 1 | `monitoring/main.tf` | New `recording_rules_yml` → `/etc/prometheus/recording_rules.yml`: `workflow_success_rate:5m`, `workflow_error_rate:1h`/`:6h`, `poll_sync_rate:5m` | Burn-rate windows must be precomputed, decoupled from the dashboard time range. `or vector(1)` so idle ≠ false alarm. |
| 2 | `monitoring/main.tf` | New alert groups: SLO **fast/slow burn** (1h@14.4× / 6h@6×, multi-window Google-SRE), **HighWorkflowTaskExecutionFailure** (non-determinism canary), activity-failure, `request_failure`/`long_request_failure`, **poll-sync-rate** (<95%/<90%), `service_errors_resource_exhausted` | Closes the gaps the first-draft dashboard missed (failure-rate + leading indicators). |
| 3 | `monitoring/main.tf` | **Bug fix:** schedule-to-start alerts `> 0.15` → `> 150` | Core/Python histograms are in **milliseconds**, so 150ms = `150` (0.15 meant 0.15ms → always firing). The seconds-based "Scaling Temporal" blog value is wrong for this SDK. |
| 4 | `monitoring/dashboards/temporal-slo.json` | New 6-row dashboard (SLO Overview, Golden Signals, Worker Health, Server Health [self-hosted-only], Infrastructure, SLO Burn Rate), provisioned via a Grafana file provider | Single SLO/golden-signals view. |
| 5 | `monitoring/main.tf` | Grafana container command now also writes the dashboard provider + dashboard JSON (`base64encode(file(...))`); Prometheus command writes the recording-rules file | Provisioning wiring. |

**Caveats noted in-code:** the error-budget gauge is a *current* burn proxy (TSDB retention is 15d, not 30d) — the burn-rate **alerts** are the real SLO mechanism. `terraform validate` passes; live verification pending redeploy.

---

## Phase 4b — SLO/SLI Audit ✅ (findings + fixes)

Audited Phases 3 & 4 against the code + Temporal KB. Outcome:

**Verified correct (no change):**
- **SDK metric naming** — Python `PrometheusConfig` defaults (`counters_total_suffix=False`, `unit_suffix=False`, `durations_as_seconds=False`, per the official Python SDK docs) confirm worker counters have **no `_total`**, no `_seconds`, and histograms are **milliseconds**. The `> 150` thresholds and `ms` dashboard units are right.
- **Server counter names** — checked the original `_total` concern: Temporal **server** defines these as bare counters (`metric_defs.go`: `NewCounterDef("workflow_success")`, …) and its default Tally→Prometheus reporter does **not** append `_total` (the official cluster-metrics docs query `rate(poll_success{}…)` bare). → The availability SLI, `poll_sync_rate`, and `ServerResourceExhausted` recording rules/alerts are **correct as written**.

**Two alert-logic bugs fixed** (`monitoring/main.tf`, `alert_rules_yml`):

| # | Alert | Before (buggy) | After (fixed) | Why |
|---|---|---|---|---|
| 1 | `TemporalServerDown` | `up{job="temporal-server"} == 0` | `max(up{job="temporal-server"}) == 0` | `ec2_sd` scrapes `:8001` on **all** hosts but only one runs the server (`distinctInstance`), so per-target `up==0` fires constantly on the 3 server-less hosts. `max()` fires only when no instance serves it. |
| 2 | `TemporalWorkerDown` | `up{job="temporal-worker"} == 0` | `absent(up{job="temporal-worker"} == 1)` | Workers are Cloud Map `dns_sd`; if **all** die the DNS record empties and the `up` series disappears, making `up==0` vacuous. `absent()` catches a total outage. |

**Remaining (documented robustness polish, not blocking):** coarse default histogram buckets (consider `histogram_bucket_overrides` in `worker.py` for accurate p95 near 150ms); single-window burn-rate (vs Google dual-window long+short); mock-service container healthchecks; ENI exhaustion (worker `1/2` — needs `awsvpcTrunking` or more EC2 capacity).

---

## Teardown prep ✅

| # | File | Change | Why |
|---|---|---|---|
| 1 | `ecr/main.tf` | `force_delete = true` on all repos | `terraform destroy` fails on non-empty ECR repos otherwise. |
| 2 | `rds-temporal/main.tf` | `skip_final_snapshot = true` | IAM user lacks `rds:CreateDBSnapshot`; also enables a clean `$0` teardown. |
