# Temporal Week 4 Testing Suite — Complete Guide

**Script Location:** `temporal_test_suite.py`  
**Run:** `python3 temporal_test_suite.py`

---

## Menu Overview

### 🔍 INFRASTRUCTURE TESTING (Options 1-5)

Verify that your infrastructure is healthy and all components are connected.

| Option | What It Does | Expected Result |
|--------|---|---|
| **1. Check service health** | Query ECS: Are all services running 1/1? | `temporal-server: 1/1`, `api: 1/1`, `worker: 2/2` |
| **2. Check CloudWatch alarms** | List all alarms; show state (OK, ALARM, INSUFFICIENT_DATA) | No alarms in ALARM state (OK state = good) |
| **3. Check Prometheus targets** | Query Prometheus API for active scrape targets | `temporal-worker: UP`, `temporal-server: UP`, `node_exporter: UP` (7 instances) |
| **4. Validate Grafana queries** | Test the 4 main dashboard queries | `temporal:workflow_success_rate:ratio_rate5m` and others return data or "No data" (if idle) |
| **5. Check SNS email subscriptions** | Verify email alerts are configured | `daniyal.tufail@xgrid.co` with status `Confirmed` |

**Demo Script: "Check if everything is up"**
```bash
python3 temporal_test_suite.py
# Choose: 1, 2, 3, 4, 5 in sequence
```

---

### ⚡ FAILURE SIMULATION (Options 6-10)

Test infrastructure resilience by shutting down services and watching them recover automatically.

| Option | What It Does | What Happens |
|--------|---|---|
| **6. Shutdown Temporal Server** | Stop the server task; watch ECS restart it | T+0: Task killed → T+30s: New task running → NLB health check passes → Workflows resume |
| **7. Shutdown API Service** | Stop the API task | API returns 503 for 30s → Recovers → Clients can submit orders again |
| **8. Shutdown Worker Service** | Stop all worker tasks | In-flight activities stall → ECS replaces workers → Activities resume |
| **9. Kill a single worker task** | Randomly kill one worker | ECS immediately replaces it → 2/2 running within 20s |
| **10. Simulate high latency** | Add delay to mock service | Activity schedule-to-start latency spikes → Dashboard shows > 150ms → Alert fires |

**Demo Script: "Show infrastructure resilience"**
```bash
python3 temporal_test_suite.py
# Choose: 29 (check status)
# Choose: 6 (shutdown server)
# Wait 30s, choose: 29 again to see it recovered
```

---

### 📊 TRAFFIC & LOAD TESTING (Options 11-15)

Generate orders to populate metrics, trigger alarms, and stress-test the platform.

| Option | Orders | What It Does |
|--------|--------|---|
| **11. Light traffic** | 5 | Submits 5 orders, proceeds them; metrics populate in ~45s |
| **12. Medium traffic** | 20 | Realistic load; all 5 mock services hit; worker slots ~30% utilized |
| **13. Heavy traffic** | 100 | Stress test; worker may scale to 10 tasks; CPU alarms may fire |
| **14. Different outcomes** | Mixed | Submit orders that succeed/fail/timeout to test failure handling |
| **15. Cancel workflows** | In-flight | Send cancel signals; test cancellation propagation |

**Demo Script: "Generate traffic to populate dashboard"**
```bash
python3 temporal_test_suite.py
# Choose: 11 (5 orders)
# Choose: 30 (show URLs, open Grafana in browser)
# Wait 45s and refresh Grafana → See success rate 100%, throughput 5/min
```

---

### ⏱️ TEMPORAL-SPECIFIC TESTS (Options 16-20)

Test Temporal-specific features and behaviors.

| Option | What It Tests |
|--------|---|
| **16. Workflow timeout** | Submit order without proceed signal; watch it timeout after 30s → appears in Temporal UI as TIMED_OUT |
| **17. Activity retry** | Activity fails 3x → watch retry backoff (5s, 10s, 20s) → manual test, monitor logs |
| **18. Workflow versioning** | Verify PINNED version behavior (new workflows go to new version) → manual check in Temporal UI |
| **19. Search attributes** | Query OrderStatus search attribute in Temporal UI → filter workflows by status |
| **20. Replay test** | Run Python test: `pytest Temporal/python/tests/test_replay.py` → verify determinism |

**Demo Script: "Test Temporal features"**
```bash
python3 temporal_test_suite.py
# Choose: 16 (timeout test)
# Wait 35s, open Temporal UI (option 30 for URL)
# Search for the order, confirm it shows TIMED_OUT
```

---

### 📈 OBSERVABILITY VALIDATION (Options 21-25)

Verify that monitoring, alerting, and observability are working.

| Option | What It Does | Expected Output |
|--------|---|---|
| **21. Check recording rules** | Query Prometheus for the 4 recording rules | Rules: `temporal_slo_recording`, `temporal:workflow_success_rate:ratio_rate5m`, etc. |
| **22. Query SLO metrics** | Fetch latest SLO values | Success Rate, Error Rates, Poll Sync Rate (or "No data" if idle) |
| **23. Trigger fast-burn alert** | Generate many failures; check if alert fires | After 50+ failures in 1 hour, alert should fire → email sent |
| **24. Check fired alarms** | Query CloudWatch for alarms in ALARM state | Lists any active alarms (should be empty under normal load) |
| **25. Verify metrics flowing** | Check if Prometheus is scraping and recording | Prometheus up, targets healthy, time series incrementing |

**Demo Script: "Test observability end-to-end"**
```bash
python3 temporal_test_suite.py
# Choose: 12 (20 orders)
# Choose: 21 (check recording rules → should show 4 rules)
# Choose: 22 (query SLO metrics → should show ~100% success rate if orders succeeded)
# Choose: 24 (check alarms → should be OK or INSUFFICIENT_DATA, not ALARM)
```

---

### 🚀 END-TO-END SCENARIOS (Options 26-28)

Pre-scripted demo scenarios that combine multiple features.

| Option | What It Does | Duration | Best For |
|--------|---|---|---|
| **26. Full demo scenario** | Traffic → dashboard → shutdown → recovery | 10 min | **Live demos, investor/stakeholder meetings** |
| **27. Chaos test** | Random failures, random traffic, random recoveries | 5 min | **Stress testing, proving resilience** |
| **28. Production readiness checklist** | Verify all 28 requirements for prod deployment | 2 min | **Pre-launch validation** |

**Use Case: "I need to demo the whole platform to my team"**
```bash
python3 temporal_test_suite.py
# Choose: 26 (Full Demo)
# Follow prompts:
#   Phase 1: Generates 10 orders
#   Phase 2: Waits 45s (refresh Grafana dashboard, watch it populate)
#   Phase 3: Prompts you to choose a failure (shutdown server/api/worker)
#   Phase 4: Shows auto-recovery and email alerts
```

---

### 📋 UTILITIES (Options 29-32)

Quick status checks and information.

| Option | Output |
|--------|--------|
| **29. Platform status** | ECS service status (running/desired count, deployment state) |
| **30. Access URLs** | Links to Temporal UI, API, Grafana, Prometheus |
| **31. Watch live metrics** | Stream Prometheus scrapes (real-time metric flow) |
| **32. View logs** | Recent logs from server/worker/API services |

---

## Quick Demo Scripts

### Demo 1: "Everything Works" (5 minutes)
```
1. Show platform status (option 29)
2. Check URLs and open in browser (option 30)
3. Show Prometheus targets (option 3)
4. Show Grafana dashboard (screenshots)
Result: "All systems operational"
```

### Demo 2: "Generate Traffic & Populate Dashboard" (10 minutes)
```
1. Generate light traffic (option 11)
2. Wait 45 seconds
3. Refresh Grafana
4. Point out populated panels: Success Rate 100%, Throughput 5 ops/min
Result: "Observability is working, metrics flowing end-to-end"
```

### Demo 3: "Infrastructure Resilience" (15 minutes)
```
1. Check status (option 29)
2. Shutdown server (option 6)
3. Wait 30 seconds, show status again (option 29) → STOPPED task
4. Wait 30 more seconds, show status → RUNNING, 1/1
5. Point out: ECS auto-recovered, no data loss
Result: "Self-healing infrastructure, zero manual intervention"
```

### Demo 4: "Full End-to-End" (20 minutes)
```
1. Run full demo (option 26)
2. Follow all 4 phases
3. Point out:
   - Traffic generation and submission (10 orders)
   - Metrics flowing (Grafana dashboard populates in real-time)
   - Auto-recovery (service failure → auto-restart)
   - Email alerts (SNS → daniyal@xgrid.co)
Result: "Production-ready Temporal platform with full observability"
```

---

## Common Testing Workflows

### "I want to verify SLO monitoring is working"
```bash
python3 temporal_test_suite.py
# 21: Check recording rules (4 rules loaded)
# 11: Generate light traffic (5 orders)
# 22: Query SLO metrics (should show 100% success rate after 45s)
# 24: Check alarms (should be OK)
```

### "I want to show that alarms work"
```bash
python3 temporal_test_suite.py
# 13: Heavy traffic (100 orders to stress system)
# 24: Check alarms (may see ASG scale alarm or latency alarm)
# Check email: daniyal.tufail@xgrid.co (SNS email from CloudWatch)
```

### "I want to verify Temporal handles failures gracefully"
```bash
python3 temporal_test_suite.py
# 11: Generate traffic (5 orders)
# 6: Shutdown server (mid-flight)
# 29: Check status (shows recovery in progress)
# 16: Test timeout (order without proceed → times out after 30s)
```

### "I want to check observability from scratch"
```bash
python3 temporal_test_suite.py
# 1: Check service health
# 3: Check Prometheus targets
# 4: Validate Grafana queries
# 5: Check SNS subscriptions
# 21: Check recording rules
# 22: Query SLO metrics
```

---

## Interpreting Results

### "No data" in dashboard metrics
- **Cause:** No traffic yet, no workflow executions
- **Solution:** Generate traffic (option 11), wait 45s, refresh
- **Expected:** After traffic, success rate and throughput should populate

### Alarm in INSUFFICIENT_DATA state
- **Cause:** Not enough data points to evaluate (typical for new alarms)
- **Solution:** Generate traffic; after 15+ minutes of metrics, alarm evaluates
- **Expected:** Status changes to OK or ALARM

### Prometheus target DOWN
- **Cause:** Service unhealthy, misconfigured security group, or service stopped
- **Solution:** Check service health (option 1), verify security group rules, restart service
- **Expected:** All targets UP (green)

### No email from SNS
- **Cause:** Subscription still `PendingConfirmation` (user hasn't clicked confirmation link)
- **Solution:** Check email for confirmation link from AWS SNS, click it
- **Expected:** Subscription status changes to `Confirmed`

---

## Architecture Diagram (What Gets Tested)

```
┌─────────────────────────────────────────────────────────────────┐
│ TEMPORAL PLATFORM (EC2 × 6, ECS, RDS, NLB, ALB)                │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ECS Services (Tested by options 1-9):                          │
│  ├─ Temporal Server (1/1) ─→ Failure test: shutdown (option 6) │
│  ├─ API (1/1) ─→ Failure test: shutdown (option 7)             │
│  ├─ Worker (2/2) ─→ Failure test: shutdown (option 8)          │
│  ├─ 5 Mock Services (1/1 each) ─→ Load test (option 13)        │
│  └─ Prometheus + Grafana (observability) ─→ Validate (option 4)│
│                                                                   │
│  Load Balancing (Tested by options 11-15):                      │
│  ├─ NLB:7233 ─→ Temporal gRPC (tested via traffic)            │
│  ├─ ALB:8000 ─→ API (tested via /orders endpoint)             │
│  ├─ ALB:8080 ─→ Temporal UI                                    │
│  └─ ALB:8443 ─→ Grafana dashboard                              │
│                                                                   │
│  Observability (Tested by options 21-25):                       │
│  ├─ Prometheus recording rules ─→ Check (option 21)            │
│  ├─ SLO metrics (success rate, error budget) ─→ Query (22)     │
│  ├─ CloudWatch alarms ─→ Check (options 2, 24)                │
│  └─ SNS email ─→ Verify (option 5)                             │
│                                                                   │
│  Temporal Features (Tested by options 16-20):                   │
│  ├─ Workflow execution + completion                             │
│  ├─ Timeout handling (option 16)                                │
│  ├─ Activity retries (option 17)                                │
│  ├─ Search attributes (option 19)                               │
│  └─ Worker versioning (PINNED behavior)                         │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Tips for Using the Script in Live Demos

1. **Pre-flight checks (2 min)**
   - Run option 29 (status)
   - Run option 30 (URLs)
   - Open Grafana in browser to show baseline

2. **Generate traffic (5 min)**
   - Run option 11 (light traffic)
   - Wait for metrics (show a timer on screen)

3. **Point out dashboard (3 min)**
   - Refresh Grafana
   - Highlight: Success Rate, Throughput, Active Workers
   - Explain what each panel means

4. **Show failure recovery (5 min)**
   - Run option 6 or 7 (shutdown service)
   - Explain: "Watch as ECS automatically restarts this"
   - Refresh status after 30s (option 29) to show recovery

5. **Wrap up (2 min)**
   - Show Temporal UI (option 30) with completed workflows
   - Explain: "All these workflows are stored, queryable, auditable"

---

## Troubleshooting the Script

**"Command failed: curl"**
- Cause: Can't reach ALB from your machine (firewall)
- Solution: Run script from inside VPC via SSM, or use Prometheus IP directly

**"No targets UP in Prometheus"**
- Cause: Security group rules missing egress for Prometheus to scrape
- Solution: Run option 3 (check targets) to diagnose; fix SG rules if needed

**"Recording rules show 'No data'"**
- Cause: No workflow executions yet
- Solution: Run option 11 (traffic), wait 45s, re-check (option 22)

**"Alarms not firing"**
- Cause: Not enough data points, or thresholds not breached
- Solution: Generate more traffic (option 13), wait 15 minutes for alarm evaluation

---

## Next Steps After Demo

1. **For Production:** Review the checklist (option 28)
2. **For Documentation:** Cite which tests passed (e.g., "All 32 tests pass")
3. **For Monitoring:** Export dashboard JSON and SLO rules to version control
4. **For Runbooks:** Document failure-recovery procedures (based on options 6-10)

---

**Script Version:** 1.0  
**Last Updated:** 2026-06-04  
**Status:** Ready for production demos
