#!/usr/bin/env python3
"""
Temporal Observability — Test & Demo Suite

Focused, reliable, menu-driven. Every option works from your laptop:
  • Alarms        : fire a real CloudWatch DOWN alarm and get the email
  • Failure/recov : kill a task and watch ECS self-heal back to desired count
  • Traffic       : drive Temporal workflows end-to-end
  • Inventory     : reset mock stock when it depletes
  • Observability : SLO metrics via the Grafana datasource proxy (no SSM)

AWS calls use the aws CLI; Prometheus is reached through Grafana's public proxy.
"""

import base64
import json
import os
import subprocess
import time
import urllib.parse
import urllib.request
from datetime import datetime

# ── Config ───────────────────────────────────────────────────────────────────
REGION   = "us-east-1"
CLUSTER  = "temporal-order-dev"
GUSER    = "admin"
PROM_UID = "temporalprom"
INVENTORY_SVC = "temporal-order-dev-inventory"

# The ALB DNS and Grafana password change on every destroy/re-apply. Auto-discover
# them at startup (live AWS) so this suite never breaks on a rebuild. The constants
# below are only used as a fallback if discovery fails (e.g. no AWS creds).
_TF_DIR   = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "Temporal", "terraform", "environments", "dev")
ALB_DNS   = "temporal-order-dev-alb-350685785.us-east-1.elb.amazonaws.com"  # fallback
GPASS     = os.environ.get("GRAFANA_PASSWORD", "")  # discovered at runtime; never hardcode the live password


def _discover():
    """Resolve the live ALB DNS and Grafana password; fall back to constants."""
    global ALB_DNS, GPASS
    try:
        dns = subprocess.run(
            ["aws", "elbv2", "describe-load-balancers", "--region", REGION,
             "--query", "LoadBalancers[?contains(LoadBalancerName,'temporal-order-dev-alb')]|[0].DNSName",
             "--output", "text"],
            capture_output=True, text=True, timeout=30).stdout.strip()
        if dns and dns != "None":
            ALB_DNS = dns
    except Exception:
        pass
    try:
        pw = subprocess.run(
            ["terraform", f"-chdir={_TF_DIR}", "output", "-raw", "grafana_admin_password"],
            capture_output=True, text=True, timeout=30).stdout.strip()
        if pw:
            GPASS = pw
    except Exception:
        pass


_discover()
API_URL  = f"http://{ALB_DNS}:8000"
UI_URL   = f"http://{ALB_DNS}:8080"
GRAFANA  = f"http://{ALB_DNS}"           # also :8443

# logical key -> (ECS service name, CloudWatch DOWN alarm name)
TARGETS = {
    "server":     ("temporal-order-temporal-server", "temporal-order-dev-temporal-server-DOWN"),
    "worker":     ("temporal-order-worker",          "temporal-order-dev-worker-DOWN"),
    "ui":         ("temporal-order-temporal-ui",     "temporal-order-dev-temporal-ui-DOWN"),
    "api":        ("temporal-order-api",             "temporal-order-dev-api-DOWN"),
    "prometheus": ("temporal-order-dev-prometheus",  "temporal-order-dev-prometheus-DOWN"),
    "grafana":    ("temporal-order-dev-grafana",     "temporal-order-dev-grafana-DOWN"),
}


class C:
    HEAD = "\033[95m"; BLUE = "\033[94m"; CYAN = "\033[96m"
    GREEN = "\033[92m"; YEL = "\033[93m"; RED = "\033[91m"; END = "\033[0m"; B = "\033[1m"


class Suite:
    # ── helpers ──────────────────────────────────────────────────────────────
    def log(self, msg, color=C.END):
        print(f"{color}[{datetime.now():%H:%M:%S}] {msg}{C.END}")

    def sh(self, cmd, timeout=60):
        try:
            r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
            return (r.stdout or "").strip()
        except Exception as e:
            self.log(f"cmd error: {e}", C.RED)
            return ""

    def svc(self, name):
        out = self.sh(f"aws ecs describe-services --cluster {CLUSTER} --services {name} "
                      f"--region {REGION} --query 'services[0].[runningCount,desiredCount]' --output text")
        try:
            r, d = out.split()
            return int(r), int(d)
        except Exception:
            return -1, -1

    def alarm_state(self, name):
        return self.sh(f"aws cloudwatch describe-alarms --region {REGION} --alarm-names {name} "
                       f"--query 'MetricAlarms[0].StateValue' --output text") or "?"

    def watch_alarm(self, name, want, timeout=360):
        self.log(f"watching {name} → {want} (CloudWatch alarms evaluate over ~2 min)…", C.CYAN)
        last = None
        for _ in range(timeout // 10):
            st = self.alarm_state(name)
            if st != last:
                col = C.RED if st == "ALARM" else C.GREEN if st == "OK" else C.YEL
                self.log(f"  state: {col}{st}{C.END}", C.CYAN)
                last = st
            if st == want:
                return True
            time.sleep(10)
        return False

    def watch_recovery(self, name, desired, timeout=150):
        self.log(f"watching {name} self-heal to {desired}/{desired}…", C.CYAN)
        for _ in range(timeout // 5):
            r, d = self.svc(name)
            print(f"   running {r}/{d}   ", end="\r")
            if r >= desired and r == d:
                print()
                self.log("✓ recovered by ECS", C.GREEN)
                return True
            time.sleep(5)
        print()
        self.log("still recovering — check option 1", C.YEL)
        return False

    def prom(self, promql):
        url = (f"{GRAFANA}/api/datasources/proxy/uid/{PROM_UID}"
               f"/api/v1/query?query={urllib.parse.quote(promql)}")
        req = urllib.request.Request(url)
        req.add_header("Authorization", "Basic " +
                       base64.b64encode(f"{GUSER}:{GPASS}".encode()).decode())
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                d = json.load(r)
            return d["data"]["result"] if d.get("status") == "success" else []
        except Exception:
            return []

    def prom_scalar(self, promql):
        res = self.prom(promql)
        if not res:
            return None
        v = res[0]["value"][1]
        return None if v in ("NaN", "+Inf", "-Inf") else v

    # ── 1. infrastructure ────────────────────────────────────────────────────
    def status(self):
        self.log("ECS services:", C.HEAD)
        names = [v[0] for v in TARGETS.values()]
        out = self.sh(f"aws ecs describe-services --cluster {CLUSTER} --region {REGION} "
                      f"--services {' '.join(names)} "
                      f"--query 'services[].[serviceName,runningCount,desiredCount,"
                      f"deployments[0].rolloutState]' --output text")
        for line in out.splitlines():
            n, r, d, st = (line.split("\t") + ["", "", "", ""])[:4]
            ok = r == d and st in ("COMPLETED", "")
            mark = f"{C.GREEN}✓{C.END}" if ok else f"{C.YEL}…{C.END}"
            print(f"  {mark} {n:34} {r}/{d}  {st}")

    def alarms(self):
        self.log("CloudWatch alarms (temporal-order-dev):", C.BLUE)
        out = self.sh("aws cloudwatch describe-alarms --region " + REGION +
                      " --alarm-name-prefix temporal-order-dev "
                      "--query 'MetricAlarms[].[AlarmName,StateValue]' --output text")
        firing = 0
        for line in out.splitlines():
            n, s = (line.split("\t") + ["", ""])[:2]
            col = {"OK": C.GREEN, "ALARM": C.RED}.get(s, C.YEL)
            firing += s == "ALARM"
            print(f"  {col}{s:18}{C.END} {n}")
        self.log(f"{firing} firing" if firing else "none firing", C.RED if firing else C.GREEN)

    def sns(self):
        self.log("SNS email subscriptions:", C.BLUE)
        out = self.sh("aws sns list-subscriptions --region " + REGION +
                      " --query \"Subscriptions[?Protocol=='email'].[Endpoint,SubscriptionArn]\" "
                      "--output text")
        seen = set()
        for line in out.splitlines():
            ep, arn = (line.split("\t") + ["", ""])[:2]
            if "temporal-order-dev-alarms" not in arn and not arn.startswith("arn:aws:sns:us-east-1:432500708329:temporal"):
                continue
            key = (ep, arn.startswith("arn:"))
            if key in seen:
                continue
            seen.add(key)
            if arn.startswith("arn:"):
                print(f"  {C.GREEN}✓ CONFIRMED{C.END} {ep}")
            else:
                print(f"  {C.RED}✗ {arn or 'PendingConfirmation'}{C.END} {ep}")
        self.log("If not CONFIRMED, click the AWS SNS link in that inbox — else no emails.", C.YEL)

    # ── 2. alarms & recovery (the focus) ─────────────────────────────────────
    def _pick_target(self, default="ui"):
        keys = list(TARGETS)
        print("  service: " + "  ".join(f"{i+1}={k}" for i, k in enumerate(keys)))
        sel = input(f"  choice [default {keys.index(default)+1}={default}]: ").strip()
        if sel.isdigit() and 1 <= int(sel) <= len(keys):
            return keys[int(sel) - 1]
        return default

    def fire_test_alarm(self):
        """Instant: force a DOWN alarm into ALARM → SNS email in seconds (no downtime)."""
        key = self._pick_target("ui")
        alarm = TARGETS[key][1]
        self.sh(f"aws cloudwatch set-alarm-state --region {REGION} --alarm-name {alarm} "
                f"--state-value ALARM --state-reason 'Test: simulate {key} DOWN'")
        self.log(f"✓ fired {alarm} → ALARM. Check your inbox now (subject 'ALARM: …{key}-DOWN').", C.GREEN)
        self.log("It auto-resets to OK on the next evaluation (you'll also get a recovery email).", C.CYAN)

    def outage_drill(self):
        """Real end-to-end: take a service to 0 tasks → DOWN alarm + email → restore → recovery."""
        key = self._pick_target("ui")
        name, alarm = TARGETS[key]
        r, d = self.svc(name)
        d = d if d > 0 else 1
        if key in ("server", "worker"):
            self.log("NOTE: taking server/worker down pauses workflow processing.", C.YEL)
        if input(f"  take {name} to 0 tasks (was {d})? [y/N]: ").strip().lower() != "y":
            self.log("cancelled", C.YEL)
            return
        self.sh(f"aws ecs update-service --cluster {CLUSTER} --service {name} "
                f"--desired-count 0 --region {REGION} --query 'service.serviceName' --output text")
        self.log("service at 0 tasks — waiting for the DOWN alarm to fire…", C.YEL)
        if self.watch_alarm(alarm, "ALARM"):
            self.log("✓ ALARM fired → SNS email sent (service DOWN).", C.GREEN)
        else:
            self.log("alarm did not reach ALARM in time (check option 2).", C.YEL)
        self.log(f"restoring {name} to {d} task(s)…", C.YEL)
        self.sh(f"aws ecs update-service --cluster {CLUSTER} --service {name} "
                f"--desired-count {d} --region {REGION} --query 'service.serviceName' --output text")
        if self.watch_alarm(alarm, "OK"):
            self.log("✓ recovered → SNS recovery email sent (OK).", C.GREEN)

    def kill_task(self, key):
        """Kill ONE task and watch ECS replace it (auto-recovery; does not fully down the service)."""
        name = TARGETS[key][0]
        r, d = self.svc(name)
        task = self.sh(f"aws ecs list-tasks --cluster {CLUSTER} --service-name {name} "
                       f"--region {REGION} --query 'taskArns[0]' --output text")
        if not task or task == "None":
            self.log(f"no running {key} task", C.RED)
            return
        self.log(f"killing one {key} task {task.split('/')[-1][:12]} (service stays at desired={d})…", C.YEL)
        self.sh(f"aws ecs stop-task --cluster {CLUSTER} --task {task} --region {REGION} "
                f"--query 'task.taskArn' --output text")
        time.sleep(4)
        self.watch_recovery(name, d)

    # ── 3. traffic (Temporal) ────────────────────────────────────────────────
    def traffic(self, count):
        self.log(f"Submitting {count} orders and proceeding each immediately…", C.BLUE)
        items = [1001, 1002, 1003]
        ok, stock_fail, other_fail = 0, 0, 0
        ts = int(datetime.now().timestamp() * 1000)
        for i in range(1, count + 1):
            oid = f"traffic-{ts}-{i}"
            item = items[(i - 1) % 3]
            body = (f'{{"order_id":"{oid}","address":"Demo {i}",'
                    f'"items":[{{"item_id":{item},"description":"Demo","quantity":1}}]}}')
            res = self.sh(f"curl -s -X POST {API_URL}/orders "
                          f"-H 'Content-Type: application/json' -d '{body}'")
            if res and "insufficient stock" in res.lower():
                stock_fail += 1
                print(f"  {i}/{count} {oid[:24]} ✗ insufficient stock (item {item})")
                continue
            try:
                wid = json.loads(res)["workflow_id"]
            except Exception:
                other_fail += 1
                print(f"  {i}/{count} {oid[:24]} ✗ submit")
                continue
            time.sleep(0.4)
            done = False
            for _ in range(2):
                pr = self.sh(f"curl -s -X POST {API_URL}/orders/{wid}/signal/proceed "
                             f"-H 'Content-Type: application/json' -d '{{}}'")
                if pr and "detail" not in pr.lower() and "error" not in pr.lower():
                    done = True
                    break
                time.sleep(0.3)
            ok += done
            print(f"  {i}/{count} {oid[:24]} (item {item}) "
                  f"{'✓ submitted → proceeded' if done else '✓ submitted → ✗ proceed'}")
            time.sleep(0.02)
        self.log(f"{ok}/{count} completed.", C.GREEN)
        if stock_fail:
            self.log(f"{stock_fail} failed on INSUFFICIENT STOCK → run option 15 to reset inventory.", C.YEL)
        if other_fail:
            self.log(f"{other_fail} failed to submit (API/Temporal issue).", C.YEL)
        self.log(f"Metrics populate in ~45s. Grafana: {GRAFANA}", C.CYAN)

    def timeout_test(self):
        oid = f"timeout-{int(time.time())}"
        body = (f'{{"order_id":"{oid}","address":"Timeout test",'
                f'"items":[{{"item_id":1001,"description":"Demo","quantity":1}}]}}')
        res = self.sh(f"curl -s -X POST {API_URL}/orders -H 'Content-Type: application/json' -d '{body}'")
        self.log(f"Submitted {oid} WITHOUT a proceed signal.", C.BLUE)
        self.log("It will sit awaiting 'proceed' and TIME OUT per the workflow timeout. "
                 f"Watch it in the Temporal UI: {UI_URL}", C.CYAN)

    # ── 4. observability (Grafana proxy) ─────────────────────────────────────
    def slo(self):
        self.log("SLO / golden-signal metrics (via Grafana proxy):", C.BLUE)
        rows = [
            ("Workflow success rate %", "temporal:workflow_success_rate:ratio_rate5m * 100"),
            ("Activity p95 (ms)",       "histogram_quantile(0.95, sum(rate("
                                        "temporal_activity_schedule_to_start_latency_bucket[5m])) by (le))"),
            ("Poll sync rate %",        "min(temporal:poll_sync_rate:ratio_rate5m) * 100"),
            ("Active workers",          'count(up{job="temporal-worker"} == 1)'),
            ("Activity slots used",     'sum(temporal_worker_task_slots_used{job="temporal-worker",worker_type="ActivityWorker"})'),
        ]
        for label, q in rows:
            v = self.prom_scalar(q)
            if v is None:
                print(f"  {label:24}: {C.YEL}no data (needs traffic){C.END}")
            else:
                try:
                    v = f"{float(v):.2f}".rstrip("0").rstrip(".")
                except Exception:
                    pass
                print(f"  {label:24}: {C.GREEN}{v}{C.END}")

    def rules(self):
        self.log("Prometheus recording rules (via Grafana proxy):", C.BLUE)
        url = f"{GRAFANA}/api/datasources/proxy/uid/{PROM_UID}/api/v1/rules"
        req = urllib.request.Request(url)
        req.add_header("Authorization", "Basic " +
                       base64.b64encode(f"{GUSER}:{GPASS}".encode()).decode())
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                groups = json.load(r)["data"]["groups"]
        except Exception:
            self.log("could not read rules", C.RED)
            return
        for g in groups:
            recs = [x["name"] for x in g.get("rules", []) if x.get("type") == "recording"]
            if recs:
                print(f"  {C.CYAN}{g['name']}{C.END}: {', '.join(recs)}")

    # ── 5. inventory ─────────────────────────────────────────────────────────
    def reset_inventory(self):
        self.log("Resetting inventory — restarting the service reseeds full stock "
                 "(1001:50, 1002:30, 1003:10 = 90 units)…", C.YEL)
        self.sh(f"aws ecs update-service --cluster {CLUSTER} --service {INVENTORY_SVC} "
                f"--force-new-deployment --region {REGION} --query 'service.serviceName' --output text")
        self.log("✓ inventory redeploying. Full stock available in ~30–60s. "
                 "Re-run traffic afterwards.", C.GREEN)

    # ── 6. utilities ─────────────────────────────────────────────────────────
    def urls(self):
        self.log("Access URLs:", C.HEAD)
        print(f"  Grafana     {C.CYAN}{GRAFANA}{C.END}  (also :8443; admin / {GPASS})")
        print(f"  Temporal UI {C.CYAN}{UI_URL}{C.END}")
        print(f"  Order API   {C.CYAN}{API_URL}{C.END}  (/docs)")

    def logs(self):
        which = input("  service (server/worker/api): ").strip().lower() or "server"
        lg = f"/ecs/temporal-order/dev/{'temporal-server' if which == 'server' else which}"
        self.log(f"last 20 lines — {lg}:", C.BLUE)
        print(self.sh(
            f"S=$(aws logs describe-log-streams --log-group-name {lg} --region {REGION} "
            f"--order-by LastEventTime --descending --max-items 1 "
            f"--query 'logStreams[0].logStreamName' --output text); "
            f"aws logs get-log-events --log-group-name {lg} --log-stream-name \"$S\" "
            f"--region {REGION} --query 'events[-20:].message' --output text") or "  (none)")

    # ── menu ─────────────────────────────────────────────────────────────────
    MENU = [
        ("INFRASTRUCTURE", [
            ("1", "Platform status (ECS services)", "status"),
            ("2", "CloudWatch alarms (state + firing)", "alarms"),
            ("3", "SNS email subscription (confirmed?)", "sns"),
        ]),
        ("ALARMS & RECOVERY", [
            ("4", "Fire a test alarm now → instant email (no downtime)", "fire_test_alarm"),
            ("5", "Outage drill: down a service → alarm+email → auto-restore", "outage_drill"),
            ("6", "Kill ONE worker task → watch ECS self-heal", lambda s: s.kill_task("worker")),
            ("7", "Kill ONE server task → watch ECS self-heal", lambda s: s.kill_task("server")),
        ]),
        ("TRAFFIC (Temporal)", [
            ("8",  "Light traffic  (5 orders)", lambda s: s.traffic(5)),
            ("9",  "Medium traffic (20 orders)", lambda s: s.traffic(20)),
            ("10", "Heavy traffic  (100 orders)", lambda s: s.traffic(100)),
            ("11", "Timeout test (order with no proceed → TIMED_OUT)", "timeout_test"),
        ]),
        ("OBSERVABILITY", [
            ("12", "SLO metrics (success / p95 / poll-sync / workers)", "slo"),
            ("13", "Recording rules loaded", "rules"),
        ]),
        ("INVENTORY", [
            ("14", "Reset inventory to full stock (restart service)", "reset_inventory"),
        ]),
        ("UTILITIES", [
            ("15", "Access URLs", "urls"),
            ("16", "View logs (server/worker/api)", "logs"),
        ]),
    ]

    def print_menu(self):
        print(f"\n{C.HEAD}{C.B}╔══════════════════════════════════════════════════╗{C.END}")
        print(f"{C.HEAD}{C.B}║   TEMPORAL OBSERVABILITY — TEST & DEMO SUITE      ║{C.END}")
        print(f"{C.HEAD}{C.B}╚══════════════════════════════════════════════════╝{C.END}")
        for section, items in self.MENU:
            print(f"\n{C.CYAN}{section}{C.END}")
            for key, label, _ in items:
                print(f"  {key:>2}. {label}")
        print(f"\n{C.YEL}   0. Exit{C.END}")

    def dispatch(self, choice):
        for _, items in self.MENU:
            for key, _, action in items:
                if key == choice:
                    action(self) if callable(action) else getattr(self, action)()
                    return True
        return False

    def run(self):
        while True:
            self.print_menu()
            try:
                choice = input(f"\n{C.B}choice (0-16): {C.END}").strip()
                if choice == "0":
                    self.log("bye", C.GREEN)
                    return
                if not self.dispatch(choice):
                    self.log("unknown option", C.YEL)
                input(f"\n{C.B}Enter to continue…{C.END}")
            except (KeyboardInterrupt, EOFError):
                print()
                self.log("bye", C.YEL)
                return
            except Exception as e:
                self.log(f"error: {e}", C.RED)


if __name__ == "__main__":
    Suite().run()
