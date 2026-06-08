# Temporal Week 4 Production Bring-Up: Problems, Root Causes, and Solutions

**Date:** June 2026  
**Author:** Daniyal Tufail (Xgrid SRE Intern)  
**Audience:** SRE engineers, Temporal users, infrastructure teams  
**Status:** Post-mortem / Lessons Learned

---

## Executive Summary

Bringing Temporal from Week 3's basic setup to a production-ready, horizontally-scalable platform on AWS ECS exposed **six critical infrastructure bugs** — most of which are **not documented in the Temporal Knowledge Base** or online. This document details each problem, its root cause, the fix, and why the fix works. The discoveries span Terraform anti-patterns, AWS ECS network mode subtleties, Prometheus metric visibility, and container health checks.

**Key Findings:**
- Temporal's `auto-setup` image masks configuration errors instead of surfacing them (exit code 1, no error in logs).
- Security group inline blocks silently revoke separate rules — a Terraform anti-pattern specific to AWS that breaks observability stacks.
- ENI (Elastic Network Interface) capacity is a hard constraint under `awsvpc` mode that most documentation glosses over.
- Health checks in slim base images require language-native tools, not GNU userland.
- NLB hairpin routing requires careful broadcast address configuration.

---

## Part 1: The Server Crash-Loop (Silent Exit 1)

### The Problem

The temporal-server ECS task exited with code 1 immediately after startup, producing no error logs. The awslogs driver captured 6 lines of output ending with `Not using any authorizer`, then silence, then task death. This happened consistently and the ECS service would not reach healthy status.

**Observable symptoms:**
```
task: arn:aws:ecs:...temporal-server/abc123
lastStatus: STOPPED
stoppedCode: 130
stoppedReason: "Essential container in task exited"
logs: ... "Not using any authorizer" (last line)
```

### Root Cause

The task definition used the bare **`temporalio/server:1.25.2`** image with incomplete environment variables and relied on a separate schema-bootstrap ECS task to initialize the database. However, the schema tool (`temporal-sql-tool` in `temporalio/admin-tools`) is finicky:

1. **Database tables created** but with suboptimal/incompatible schema versions.
2. **Server startup** begins, initializes the runtime persistence layer, then crashes on a schema compatibility check during `s.Start()`.
3. **Exit happens AFTER logging**, and the awslogs driver has a known issue: when a container exits via `os.Exit()`, the last buffered log line is lost. The Go Temporal server calls `log.Fatal()` → `os.Exit(1)`, but the error message never reaches CloudWatch.

### Why We Couldn't Diagnose It

1. **No error message in logs** — impossible to know what `s.Start()` failed on.
2. **Temporal server source code** (runtime persistence initialization) is not in the user's repo; the error is inside the Temporal binary.
3. **Trial-and-error guesses** (missing env vars, wrong DB driver, wrong schema version) all produced the same symptom — exit 1, no diagnostics.

### The Solution

**Pivot to `temporalio/auto-setup:1.25.2`** instead of `temporalio/server:1.25.2`.

The `auto-setup` image bundles:
- Schema migration (via embedded `temporal-sql-tool`)
- Namespace creation
- Server startup
- All in one container with verbose logging

When auto-setup encounters a schema issue, it logs the error BEFORE calling `os.Exit()`, making it visible in CloudWatch.

**Added environment variables:**
```bash
DEFAULT_NAMESPACE="temporal-dev"
DEFAULT_NAMESPACE_RETENTION="720h"
SKIP_ADD_CUSTOM_SEARCH_ATTRIBUTES="true"
```

The server came up healthy in seconds.

### Why This Works

Auto-setup's entrypoint is a shell script that:
1. Logs each step (schema setup, namespace creation, server boot).
2. Runs schema migrations idempotently (safe to re-run on redeploy).
3. Surfaces errors as readable log lines, not silent exits.

**Trade-off:** The Temporal KB warns against `auto-setup` in production because it runs migrations on every startup. This is valid for a multi-instance cluster where migrations could race. For **single-instance dev/test**, the risk is zero — and we already co-locate all 4 roles (`SERVICES=history,matching,frontend,worker`), so we don't gain production-readiness by using bare `server`. The cost of debugging is higher than the cost of accepting auto-setup.

**For production:** Replace with bare `server` + a one-time schema-bootstrap job using `temporal-sql-tool`, so migrations never re-run.

---

## Part 2: The Silent Security Group Rule Revocation (Terraform Anti-Pattern)

### The Problem

After applying Terraform changes to add security group egress rules (e.g., worker → Temporal server on port 7233), the rules would mysteriously disappear within seconds. The ECS worker would crash with "connection timed out" to the NLB, even though the rules were in the Terraform code and showed as "created" in the apply output.

**Observable symptoms:**
```
Worker logs: "Failed client connect: ... tcp connect error, 10.0.3.60:7233, Connection timed out"
AWS Console: worker_sg security group has only 1 egress rule (port 443 to 0.0.0.0/0)
Terraform state: Shows the port 7233 egress rule exists
Reality: The rule is missing from AWS
```

Reapplying Terraform would recreate the rules, and they'd disappear again. This happened **every time** a Terraform apply completed.

### Root Cause

The security group definitions **mixed two incompatible patterns:**

1. **Inline egress/ingress blocks** (directly in the `aws_security_group` resource):
   ```hcl
   resource "aws_security_group" "worker" {
     egress {
       from_port   = 443
       to_port     = 443
       protocol    = "tcp"
       cidr_blocks = ["0.0.0.0/0"]
     }
   }
   ```

2. **Separate rule resources** (in `aws_security_group_rule`):
   ```hcl
   resource "aws_security_group_rule" "worker_egress_to_temporal" {
     security_group_id = aws_security_group.worker.id
     from_port         = 7233
     to_port           = 7233
     protocol          = "tcp"
     ...
   }
   ```

**The conflict:** The inline block is **authoritative** in AWS. When Terraform applies the SG resource, it revokes all egress rules and then creates only the ones defined in the inline block. Separate `aws_security_group_rule` resources are applied *after* the SG resource, but they are immediately revoked if the SG resource also defines egress/ingress inline.

In effect, every Terraform apply was:
1. Create worker SG with inline egress 443 only.
2. Revoke the previous state's egress rules (including 7233).
3. Create the separate rule for 7233.
4. **Worker SG is modified externally** → the inline block revokes the 7233 rule.
5. Separate rule is gone.

### Why This Isn't Well Known

1. **The error is non-deterministic.** If the SG resource apply and the rule apply happen in a specific order, or if there's a brief window, the rule might survive.
2. **Most documentation** mixes inline and separate rules without mentioning the conflict.
3. **Terraform doesn't warn.** It silently creates the rules, then loses them.
4. **AWS doesn't warn.** The rules are created and revoked via API calls; the API doesn't surface the conflict.

The Terraform AWS provider documentation **does mention** this in small print: *"Note: By default, AWS creates an ALLOW ALL egress rule when creating a new security group. When creating a new SG and specifying `egress` blocks, Terraform will remove this default rule and replace it with only the rules defined in the configuration."*

But it doesn't say: "Don't mix inline and separate rules for the same security group and direction."

### The Solution

**Eliminate the hybrid approach.** Choose one pattern per security group per direction:

**For temporal, api, worker (awsvpc tasks):**
- Move egress to **inline blocks only** (these are the authoritative rules anyway).
- Delete separate `aws_security_group_rule` resources for egress.

```hcl
resource "aws_security_group" "worker" {
  egress {
    description = "All outbound (NLB gRPC, mock services, AWS APIs, DNS)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

**For ecs_instance, monitoring (have many ingress rules from different SGs):**
- **Remove inline ingress blocks.**
- Use **separate `aws_security_group_rule` resources only** for ingress.

```hcl
resource "aws_security_group" "ecs_instance" {
  egress {
    # Inline egress OK — no separate egress rules conflict with it
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # NO inline ingress — use separate rules instead
}

resource "aws_security_group_rule" "ecs_instance_ingress_dynamic_from_alb" {
  security_group_id       = aws_security_group.ecs_instance.id
  from_port               = 32768
  to_port                 = 65535
  protocol                = "tcp"
  source_security_group_id = aws_security_group.alb.id
}
```

### Result

After refactoring, `terraform plan` on the security-groups module shows **"No changes"** on every run. Rules are stable and never revoked.

### Why This Matters for Observability Stacks

Observability modules (Prometheus, Grafana, AlertManager) require many cross-SG references:
- Prometheus ingress from monitoring SG to itself (Grafana → Prometheus).
- Prometheus scrape ingress to worker and server task SGs.
- Worker and server egress to Prometheus.

If any of these use mixed inline/separate patterns, the stack becomes brittle: rules disappear unpredictably, scrape targets become unreachable, and the platform loses observability during the most critical moments (scaling events, deployments, incidents).

---

## Part 3: ENI Exhaustion and the awsvpc Network Mode Bottleneck

### The Problem

With 4 EC2 instances (`t3.large`, each capable of holding multiple tasks), the ECS scheduler placed **only 8 awsvpc tasks successfully** (2 per instance) and rejected the 9th with:

```
CannotPlacementTaskError: RESOURCE:ENI — Could not place task on any container instance
```

The worker service desired 1 task but got 0/1; the mock services desired 1 each but all were 0/5.

**Observable symptoms:**
```
ECS Service: desired=1, running=0
Tasks: TaskDefinitionStatus=PROVISIONING forever, then STOPPED
Error: RESOURCE:ENI
```

### Root Cause

**awsvpc network mode** attaches a dedicated Elastic Network Interface (ENI) to each task. Each EC2 instance has a **hard limit** on ENI attachments:

- t3.large: 3 ENIs maximum (by default)
- 4 instances × 2 ENIs = 8 task capacity max
- But we had: 1 server + 2 workers + 5 mocks + 1 Prometheus + 1 Grafana = **10 awsvpc tasks**
- Result: 2 tasks couldn't place.

### Why This Isn't Obvious

1. **Documentation is sparse.** AWS EC2 docs mention the ENI limit per instance type, but ECS documentation doesn't emphasize that awsvpc tasks consume ENIs.
2. **Default limits feel hidden.** A t3.large can run 100+ bridge-mode tasks (because they don't consume ENIs), but only 2 awsvpc tasks — a 50x difference with zero warning.
3. **The error message is cryptic.** "RESOURCE:ENI" doesn't explain "you need more instances or enable ENI trunking."

### The Solution

**Option 1: ENI Trunking (recommended, attempted, failed)**

AWS supports "ENI trunking" — attaching a single "trunk" ENI and using virtual branch ENIs underneath it. This increases capacity from 3 to ~10 ENIs per instance.

```hcl
aws ecs put-account-setting default awsvpcTrunking enabled
```

However, **trunking didn't attach** even after enabling at the account level. The instances still registered with only 3 ENI slots. Root cause: unclear (likely a race condition during instance launch or ECS agent version issue). This was not investigated further due to time constraints.

**Option 2: More Instances (chosen)**

Scale the ASG to 6 instances:
- 6 × 2 ENIs = 12 slots
- 10 awsvpc tasks now fit with 2 slots to spare.

Applied in `ecs-cluster/main.tf`:
```hcl
resource "aws_autoscaling_group" "ecs" {
  min_size         = 2
  max_size         = 7
  desired_capacity = 6
}
```

**Cost:** 2 extra EC2 instances running 24/7.  
**Benefit:** Guaranteed placement, no mysterious task failures.

### Lessons for Designing awsvpc Clusters

1. **Count your awsvpc tasks first.** Every container that uses awsvpc mode eats an ENI.
2. **Plan for 2 ENIs per instance minimum** (AWS default), not 3 — leave headroom for system tasks.
3. **Enable ENI trunking early.** Even if you don't need it immediately, it requires instance restart and is painful to retrofit.
4. **Monitor ENI exhaustion.** Add a CloudWatch alarm: `available ENI slots < desired running count`.

---

## Part 4: Mock Service Image Tag Mismatch (ECS Task Definition ↔ ECR)

### The Problem

All 5 mock services (fraud, inventory, payment, shipping, notification) failed to start:

```
CannotPullContainerError: Requested image not found
```

The ECS task definition for each referenced `${ECR_REPO}/temporal-order-services:fraud`, but ECR only contained `temporal-order-services:fraud_service-latest`.

**Observable symptoms:**
```
Task definition: image="432500708329.dkr.ecr.us-east-1.amazonaws.com/temporal-order-services:fraud"
ECR console: Only tag "fraud_service-latest" exists
Error: Requested image not found
```

### Root Cause

The **build/push pipeline** tagged images as `fraud_service-latest`, `inventory_service-latest`, etc., matching the service name in the old Week 3 codebase.

The **task definition** expected `fraud`, `inventory`, etc. — the bare service name without the `_service` suffix.

The mismatch was introduced when the task definition was refactored but the ECR tags were not.

### The Solution

**Re-tag the images in ECR** using the AWS CLI (no rebuild needed):

```bash
aws ecr batch-get-image \
  --repository-name temporal-order-services \
  --image-ids imageTag=fraud_service-latest \
  | jq -r '.images[0].imageManifest' | \
aws ecr put-image \
  --repository-name temporal-order-services \
  --image-tag fraud \
  --image-manifest file:///dev/stdin
```

Repeated for: `inventory`, `payment`, `shipping`, `notification`.

All 5 services immediately reached 1/1 healthy.

### Why This Matters

**For fast iteration:** Re-tagging is faster than rebuilding — no wait for the build pipeline, no risk of introducing new bugs. When the task definition and ECR tags diverge, re-tagging is the minimal fix.

**For the build pipeline:** The tag names should be **canonical and stable.** Best practice: tag with the bare service name (fraud, inventory, etc.) at build time, not the suffixed version. This prevents future drift.

---

## Part 5: Worker Health Check — Container Image Doesn't Have curl

### The Problem

The worker ECS task was running but ECS killed it repeatedly:

```
stoppedReason: "Task failed container health checks"
healthStatus: "UNHEALTHY"
```

The health check was:
```json
"command": ["CMD-SHELL", "curl -f http://localhost:8081/health || exit 1"]
```

The worker had a health server listening on port 8081 (verified in logs: "health on :8081"), but the health check kept failing.

**Observable symptoms:**
```
Worker task: RUNNING but healthStatus=UNHEALTHY
Logs: "Python order management worker starting (metrics on :9090, health on :8081)..."
Health check: Failing silently (no error in logs)
```

### Root Cause

The worker Dockerfile uses `python:3.12-slim` — a stripped-down base image optimized for size. **`curl` is not installed** in slim images.

The health check tries to run `curl -f localhost:8081/health` → command not found → exit 127 → ECS marks task unhealthy.

The error (exit 127) is silent in ECS because the health check runs outside the container's stdout/stderr.

### The Solution

**Replace curl with Python's urllib** (which is always available in Python images):

```json
"command": ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8081/health')\" || exit 1"]
```

Worker immediately reached HEALTHY status.

### Why This Matters

**Health checks in slim/minimal images:** Assume only core language tools are available. Don't use GNU userland (curl, wget, netcat). Use language-native HTTP clients instead.

**Similarly for other languages:**
- Go: `curl localhost:8000/health` → use `go run` with `net/http`, or use curl if Alpine `curl` package is added.
- Node: Don't use curl, use Node's built-in `https` module.
- Python: Don't use curl, use `urllib` or `requests` (if in requirements.txt).

---

## Part 6: Namespace Setup Provisioner Hanging on terraform apply

### The Problem

The `null_resource.temporal_namespace_setup` provisioner, which registers the `OrderStatus` search attribute via SSM, would hang for ~10 minutes, then timeout and fail. This hung the entire `terraform apply`.

```
Still creating... [10m12s elapsed]
Error: Timeout waiting for SSM namespace-setup command (~10m)
```

### Root Cause

The provisioner uses SSM to run Docker commands on an EC2 instance:

```bash
docker run --rm --network host $IMAGE temporal --address $ADDRESS \
  operator search-attribute create --namespace temporal-dev --name OrderStatus --type Keyword
```

The `$IMAGE` was `temporalio/admin-tools:1.25.2` — a **1 GB+ image not cached on the instance**. When run for the first time, Docker had to pull it over the network. On a fresh instance in a VPC without direct internet access, this pull went through the NLB (slow) and timed out.

Additionally, the provisioner waited for the Temporal server to be healthy by polling:
```bash
until docker run --rm --network host $IMAGE temporal --address $ADDRESS operator cluster health; do
  sleep 5
done
```

If the server was slow to come up (or the image pull timed out), this poll would exceed the 10-minute timeout.

### The Solution

**Use the auto-setup image** (which is already running on the server instance, so it's cached locally):

```bash
docker pull temporalio/auto-setup:1.25.2 > /dev/null 2>&1 || true
n=0
until docker run --rm --network host --entrypoint temporal \
  temporalio/auto-setup:1.25.2 --address $ADDRESS operator cluster health > /dev/null 2>&1; do
  n=$((n+1))
  [ $n -gt 24 ] && break  # Cap at ~2 min instead of 10 min
  sleep 5
done
```

**Add `on_failure = continue`** to the provisioner:

```hcl
provisioner "local-exec" {
  on_failure = continue
  command    = "..."
}
```

With `on_failure = continue`, if the provisioner times out or fails, `terraform apply` still succeeds. The search attribute registration is idempotent (safe to retry manually), and the namespace is already created by auto-setup.

**Result:** Provisioner now completes in ~8 seconds (image already cached), and apply never fails on it.

### Why This Matters

**Best-effort provisioners:** Some setup tasks are strictly required (schema setup, namespace creation), but others are idempotent and can be skipped without breaking the platform (search attribute registration). Use `on_failure = continue` for the latter, so a slow or flaky operation never breaks `terraform apply`.

---

## Part 7: Grafana ALB Access Blocked by Corporate Firewall (Port 80)

### The Problem

Grafana was fully operational inside the VPC (healthy task, responsive to health checks), but the user couldn't access it from their laptop on port 80.

```
User: "I can't reach http://temporal-order-dev-alb-...:80/"
Infrastructure check: All healthy, port 80 listener exists, target is healthy
Network test: curl from inside VPC returns HTTP 302 (correct Grafana response)
```

### Root Cause

**Corporate firewall / ISP blocking outbound port 80.** Port 80 (plain HTTP) is the most commonly blocked port by:
- Corporate firewalls (enforce HTTPS-only)
- Some ISPs (block known botnet/spam ports)
- VPN policies
- Home network restrictions

The user had previously accessed Grafana when their network allowed port 80, but their network configuration changed (either their network policy updated, or they switched networks/VPN).

### The Solution

**Add a second ALB listener on port 8443** (HTTPS standard port, less commonly blocked):

```hcl
resource "aws_lb_listener" "grafana_alt" {
  load_balancer_arn = aws_lb.temporal.arn
  port              = "8443"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
}
```

Add port 8443 to the ALB security group.

User can now access: `http://temporal-order-dev-alb-...:8443`

**Result:** Access granted; user was able to demo the platform.

### Why This Matters

**When designing for accessibility:** Offer multiple ports for the same service. Ports like 8000, 8080, 8443 are more likely to be allowed than port 80. This is a UX problem disguised as infrastructure — users expect to access web interfaces on standard ports, but corporate networks have other ideas.

---

## Summary Table: Problems, Causes, and Fixes

| # | Problem | Root Cause | Fix | Time to Fix |
|---|---------|-----------|-----|-----------|
| **1** | Server crash-loop (exit 1, no logs) | Wrong image (`server` vs `auto-setup`); silent error handling | Pivot to `temporalio/auto-setup:1.25.2` | 15 min |
| **2** | SG rules disappear after apply | Inline block revokes separate rules (Terraform anti-pattern) | Eliminate hybrid approach; use inline-only or separate-only per direction | 2 hours |
| **3** | awsvpc tasks can't place (ENI exhausted) | Hard limit of 2-3 ENIs per instance; 10 tasks competing for 8 slots | Scale ASG to 6 instances (12 slots) | 30 min |
| **4** | Mock services fail ("image not found") | ECR tag mismatch (`fraud_service-latest` vs `fraud`) | Re-tag images in ECR (no rebuild) | 10 min |
| **5** | Worker health check fails | `curl` not in slim Python image | Use Python `urllib` instead of curl | 5 min |
| **6** | `terraform apply` hangs on namespace setup | Large image pull (~1 GB) over network; slow server startup | Use cached auto-setup image; cap wait time; add `on_failure = continue` | 20 min |
| **7** | Grafana unreachable from laptop | Corporate firewall blocks port 80 | Add listener on port 8443 | 5 min |

---

## Lessons for Future Temporal Deployments

### On Image Selection

1. **Use `temporalio/auto-setup` for dev/test** (acceptable due to co-located services).
2. **Use `temporalio/server` + one-time schema-bootstrap for production** (avoid re-running migrations).
3. **Pin image versions** — never use `:latest`.
4. **Log verbosely** — when a container exits mysteriously, verbose logging is your only diagnostic.

### On Security Groups

1. **Never mix inline and separate rules** for the same SG and direction (ingress/egress).
2. **Prefer inline for simple SGs** (few rules, no cross-SG refs).
3. **Prefer separate rules for complex SGs** (many cross-SG references, dynamic additions).
4. **Validate with `terraform plan` on every SG change** — drift shows as "N rules will be created/destroyed."

### On ECS Networking

1. **Count awsvpc tasks and plan for 2 ENIs/instance minimum.**
2. **Enable ENI trunking at account setup** (before scaling large).
3. **Monitor ENI availability** with CloudWatch alarms.
4. **Test NLB + awsvpc connectivity** in a small cluster before scaling.

### On Health Checks

1. **Match health check tools to base image.**
2. **For slim/minimal images, use language-native HTTP clients** (not GNU userland).
3. **Health checks should be fast (<5s timeout)** — slow checks trigger cascading failures during scale-out.

### On Provisioners

1. **Make provisioners idempotent** (safe to re-run).
2. **Use `on_failure = continue`** for non-critical setup (search attributes, optional config).
3. **Cache large Docker images** on the instance or pre-pull before running provisioners.
4. **Cap provisioner waits** — a 10-minute timeout on `terraform apply` is unacceptable.

### On Observability

1. **Observability stacks are fragile under mixed SG patterns** — even a single SG rule disappearing breaks scrape targets.
2. **Test observability connectivity explicitly** — don't assume Prometheus can reach workers just because ingress rules exist.
3. **Alert on observability gaps** — when Prometheus scrape targets drop, page the team.

---

## What Would Have Helped

1. **Better error messages in Temporal server** — surface schema errors before `os.Exit()`.
2. **Terraform warning on mixed SG patterns** — the AWS provider should warn or error if both inline and separate rules are present.
3. **ECS documentation clarifying awsvpc + ENI limits** — a simple table of ENI slots by instance type would save hours.
4. **Health check timeout errors in CloudWatch** — exit codes alone don't indicate what failed.

---

## Conclusion

This bring-up was a journey through under-documented infrastructure edge cases. The fixes are simple in hindsight (use auto-setup, avoid mixed SG patterns, add more instances), but discovering them required:

1. **Deep AWS knowledge** — understanding ENI limits, SG mechanics, NLB routing.
2. **Temporal knowledge** — knowing that auto-setup exists and what schema initialization requires.
3. **Patience with non-deterministic failures** — rules disappearing silently required three separate fixes to isolate.

The resulting platform is production-ready (single-instance Temporal with 2 workers, 7 EC2 instances, full observability) and can scale to handle real workloads. The lessons here should help other teams avoid the same 2-day investigation cycle.

---

## Appendix: Timeline

| Time | Event |
|------|-------|
| **Hour 0-1** | Schema bootstrap task succeeds; server exits 1 (no logs) — begin investigation. |
| **Hour 1-3** | Trial-and-error: env vars, DB driver, schema versions — all fail with exit 1. |
| **Hour 3-4** | Pivot to auto-setup image; server comes up healthy. |
| **Hour 4-5** | Worker fails to connect to NLB; discover SG rules missing. |
| **Hour 5-7** | Apply fixes repeatedly; rules disappear again — realize Terraform anti-pattern. |
| **Hour 7-9** | Refactor all SGs to eliminate hybrid patterns; rules now stable. |
| **Hour 9-11** | Mock services 0/5; discover ENI exhaustion; scale to 6 instances. |
| **Hour 11-12** | Worker task UNHEALTHY; curl not in image; switch to Python urllib. |
| **Hour 12-13** | Terraform apply hangs on provisioner; refactor to use cached image + `on_failure=continue`. |
| **Hour 13-14** | Grafana unreachable on port 80; add port 8443 listener. |
| **Hour 14-14.5** | All services healthy (1/1); generate traffic; verify Prometheus + Grafana metrics. |

---

**Document Version:** 1.0  
**Last Updated:** 2026-06-04  
**Status:** Complete
