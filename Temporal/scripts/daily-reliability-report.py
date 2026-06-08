#!/usr/bin/env python3
"""
Daily Reliability Report — Temporal-on-ECS Observability Platform

Collects SLO/golden-signal metrics from Prometheus (via the Grafana datasource
proxy — works from anywhere since Grafana is public and reaches Prometheus
internally) plus infrastructure health from CloudWatch, then publishes a single
structured report to SNS. A CRITICAL/DEGRADED status in the subject line is the
"alarm"; the email is the daily delivery.

Usage:
  python3 daily-reliability-report.py            # collect + publish to SNS (email)
  python3 daily-reliability-report.py --dry-run  # print to stdout only

Run daily (06:00 UTC) via cron:
  0 6 * * * GRAFANA_PASSWORD=*** python3 /abs/path/Temporal/scripts/daily-reliability-report.py \
            >> /var/log/temporal-daily-report.log 2>&1

Prereq for the EMAIL to arrive: the SNS email subscription on the topic below
must be CONFIRMED (click the AWS confirmation link). Check with:
  aws sns list-subscriptions --query "Subscriptions[?Protocol=='email']" --output table
"""

import argparse
import os
import sys
from datetime import datetime, timedelta, timezone

import boto3
import requests

# ── Config (this project) ─────────────────────────────────────────────────────
REGION        = "us-east-1"
CLUSTER       = "temporal-order-dev"
SERVICES      = {
    "temporal-server": "temporal-order-temporal-server",
    "api":             "temporal-order-api",
    "worker":          "temporal-order-worker",
    "prometheus":      "temporal-order-dev-prometheus",
    "grafana":         "temporal-order-dev-grafana",
}
RDS_ID        = "temporal-order-dev-temporal-db"
SNS_TOPIC_ARN = "arn:aws:sns:us-east-1:432500708329:temporal-order-dev-alarms"

# These change on every destroy/re-apply, so discover them from live AWS at startup
# (CloudWatch dimensions for the ALB/target-group, plus the ALB DNS for the Grafana
# proxy). Constants are only fallbacks if discovery fails.
ALB_SUFFIX    = "app/temporal-order-dev-alb/0f3890c75668e3b3"                       # fallback
API_TG_SUFFIX = "targetgroup/api-20260604064615894600000005/319392857413ad52"      # fallback
GRAFANA_URL   = "http://temporal-order-dev-alb-826497180.us-east-1.elb.amazonaws.com"  # fallback
GRAFANA_USER  = "admin"
GRAFANA_PASS  = os.environ.get("GRAFANA_PASSWORD", "")  # discovered at runtime; never hardcode the live password
PROM_DS_UID   = "temporalprom"


def _discover():
    """Resolve live ALB DNS, ALB/target-group CloudWatch suffixes, and Grafana password."""
    global ALB_SUFFIX, API_TG_SUFFIX, GRAFANA_URL, GRAFANA_PASS
    try:
        elb = boto3.client("elbv2", region_name=REGION)
        for lb in elb.describe_load_balancers()["LoadBalancers"]:
            if "temporal-order-dev-alb" in lb["LoadBalancerName"]:
                GRAFANA_URL = f"http://{lb['DNSName']}"
                # ARN: ...:loadbalancer/app/<name>/<id>  → dimension value is the part after "loadbalancer/"
                ALB_SUFFIX = lb["LoadBalancerArn"].split("loadbalancer/", 1)[1]
                break
        for tg in elb.describe_target_groups()["TargetGroups"]:
            if tg["TargetGroupName"].startswith("api-"):
                # ARN: ...:targetgroup/<name>/<id>  → dimension value is "targetgroup/<name>/<id>"
                API_TG_SUFFIX = tg["TargetGroupArn"].split(":")[-1]
                break
    except Exception as e:
        print(f"[warn] AWS discovery failed, using fallbacks: {e}", file=sys.stderr)

    # Grafana password: env var wins (cron sets it); else terraform output; else fallback.
    if not os.environ.get("GRAFANA_PASSWORD"):
        try:
            import subprocess
            tf_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                  "..", "terraform", "environments", "dev")
            pw = subprocess.run(
                ["terraform", f"-chdir={tf_dir}", "output", "-raw", "grafana_admin_password"],
                capture_output=True, text=True, timeout=30).stdout.strip()
            if pw:
                GRAFANA_PASS = pw
        except Exception:
            pass


_discover()

LOG_GROUPS    = {
    "temporal-server": "/ecs/temporal-order/dev/temporal-server",
    "worker":          "/ecs/temporal-order/dev/worker",
    "api":             "/ecs/temporal-order/dev/api",
}
ALARM_PREFIX  = "temporal-order-dev"

# ── SLO targets ───────────────────────────────────────────────────────────────
SLO_SUCCESS_PCT  = 99.0    # SLO-1: workflow success rate (server-sourced)
SLO_P95_MS       = 150.0   # SLO-2: activity schedule-to-start p95 (Core SDK = ms)
ERROR_BUDGET_PCT = 1.0     # 100% - 99% over 30d


# ── Prometheus via Grafana proxy ──────────────────────────────────────────────
def prom_query(promql):
    try:
        r = requests.get(
            f"{GRAFANA_URL}/api/datasources/proxy/uid/{PROM_DS_UID}/api/v1/query",
            params={"query": promql}, auth=(GRAFANA_USER, GRAFANA_PASS), timeout=15)
        data = r.json()
        if data.get("status") == "success":
            return data["data"]["result"]
    except Exception as e:
        print(f"  [warn] prom query failed: {e}", file=sys.stderr)
    return []


def prom_scalar(promql, default=None):
    res = prom_query(promql)
    if not res:
        return default
    v = res[0]["value"][1]
    return default if v in ("NaN", "+Inf", "-Inf") else float(v)


# ── CloudWatch helper ─────────────────────────────────────────────────────────
def cw_stat(ns, metric, dims, stat, start, end, period=86400):
    cw = boto3.client("cloudwatch", region_name=REGION)
    resp = cw.get_metric_statistics(Namespace=ns, MetricName=metric, Dimensions=dims,
                                    StartTime=start, EndTime=end, Period=period,
                                    Statistics=[stat])
    pts = sorted(resp.get("Datapoints", []), key=lambda x: x["Timestamp"])
    return [p[stat] for p in pts] or None


# ── Collectors ────────────────────────────────────────────────────────────────
def collect_slos():
    succ = prom_scalar("temporal:workflow_success_rate:ratio_rate5m", default=1.0)
    return dict(
        success_pct = succ * 100 if succ is not None else None,
        p95_ms      = prom_scalar("histogram_quantile(0.95, sum(rate("
                                  "temporal_activity_schedule_to_start_latency_bucket[5m])) by (le))"),
        err_rate_1h = prom_scalar("temporal:workflow_error_rate:ratio_rate1h", default=0.0),
        poll_sync   = prom_scalar("min(temporal:poll_sync_rate:ratio_rate5m)"),
        wf_done     = prom_scalar("sum(rate(temporal_workflow_completed[5m]))", default=0.0),
        wf_fail     = prom_scalar("sum(rate(temporal_workflow_failed[5m]))", default=0.0),
        workers     = prom_scalar('count(up{job="temporal-worker"} == 1)', default=0.0),
        slots_used  = prom_scalar('sum(temporal_worker_task_slots_used'
                                  '{job="temporal-worker",worker_type="ActivityWorker"})', default=0.0),
        slots_avail = prom_scalar('sum(temporal_worker_task_slots_available'
                                  '{job="temporal-worker",worker_type="ActivityWorker"})', default=0.0),
    )


def collect_ecs():
    ecs = boto3.client("ecs", region_name=REGION)
    out = {}
    try:
        resp = ecs.describe_services(cluster=CLUSTER, services=list(SERVICES.values()))
        by_name = {s["serviceName"]: s for s in resp["services"]}
    except Exception:
        by_name = {}
    for label, name in SERVICES.items():
        s = by_name.get(name)
        out[label] = ({"running": s["runningCount"], "desired": s["desiredCount"],
                       "status": s["status"]} if s
                      else {"running": "?", "desired": "?", "status": "ERROR"})
    return out


def collect_hosts():
    cpu = prom_query("instance:node_cpu_utilisation:rate5m")
    mem = prom_query("instance:node_memory_utilisation:ratio * 100")
    dsk = prom_query('100 * (1 - node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"}'
                     ' / node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"})')
    hosts = {}
    for key, series in (("cpu", cpu), ("mem", mem), ("disk", dsk)):
        for r in series:
            inst = r["metric"].get("instance", "?")
            hosts.setdefault(inst, {})[key] = round(float(r["value"][1]), 1)
    return hosts


def collect_rds(start, end):
    dims = [{"Name": "DBInstanceIdentifier", "Value": RDS_ID}]
    cpu  = cw_stat("AWS/RDS", "CPUUtilization", dims, "Average", start, end)
    conn = cw_stat("AWS/RDS", "DatabaseConnections", dims, "Maximum", start, end)
    free = cw_stat("AWS/RDS", "FreeStorageSpace", dims, "Minimum", start, end)
    rds = boto3.client("rds", region_name=REGION)
    try:
        inst = rds.describe_db_instances(DBInstanceIdentifier=RDS_ID)["DBInstances"][0]
        state, alloc = inst["DBInstanceStatus"], inst["AllocatedStorage"]
    except Exception:
        state, alloc = "unknown", 20
    return {"state": state, "allocated_gb": alloc,
            "free_gb": round(min(free) / 1e9, 2) if free else None,
            "cpu_avg": round(sum(cpu) / len(cpu), 1) if cpu else None,
            "conn_max": int(max(conn)) if conn else None}


def collect_alb(start, end):
    dims = [{"Name": "LoadBalancer", "Value": ALB_SUFFIX}]
    tg   = dims + [{"Name": "TargetGroup", "Value": API_TG_SUFFIX}]
    reqs = cw_stat("AWS/ApplicationELB", "RequestCount", dims, "Sum", start, end) or [0]
    e5xx = cw_stat("AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", dims, "Sum", start, end) or [0]
    hlt  = cw_stat("AWS/ApplicationELB", "HealthyHostCount", tg, "Minimum", start, end)
    return {"total_requests": int(sum(reqs)), "total_5xx": int(sum(e5xx)),
            "healthy_hosts": int(min(hlt)) if hlt else None}


def collect_alarms():
    cw = boto3.client("cloudwatch", region_name=REGION)
    firing, ok, other = [], 0, 0
    for page in cw.get_paginator("describe_alarms").paginate(AlarmNamePrefix=ALARM_PREFIX):
        for a in page.get("MetricAlarms", []) + page.get("CompositeAlarms", []):
            if a["StateValue"] == "ALARM":
                firing.append(a["AlarmName"])
            elif a["StateValue"] == "OK":
                ok += 1
            else:
                other += 1
    return {"firing": firing, "ok": ok, "other": other}


def collect_log_errors(start, end):
    logs = boto3.client("logs", region_name=REGION)
    total, samples = 0, []
    for label, lg in LOG_GROUPS.items():
        try:
            pages = logs.get_paginator("filter_log_events").paginate(
                logGroupName=lg, startTime=int(start.timestamp() * 1000),
                endTime=int(end.timestamp() * 1000),
                filterPattern="?ERROR ?Error ?Fatal ?Traceback",
                PaginationConfig={"MaxItems": 50})
            for page in pages:
                for ev in page.get("events", []):
                    total += 1
                    if len(samples) < 3:
                        ts = datetime.fromtimestamp(ev["timestamp"] / 1000, tz=timezone.utc)
                        samples.append(f"  [{ts.strftime('%H:%M')} {label}] {ev['message'].strip()[:90]}")
        except Exception:
            pass
    return {"count": total, "samples": samples}


# ── Report ────────────────────────────────────────────────────────────────────
def fmt_slo(name, value, target, ok):
    mark = "N/A  —" if ok is None else ("PASS ✓" if ok else "FAIL ✗")
    return f"  {name:<34} {mark:<8} {value:<14} (target {target})"


def build_report(date_str, slo, ecs, hosts, rds, alb, alarms, logs):
    slo1 = slo["success_pct"] is not None and slo["success_pct"] >= SLO_SUCCESS_PCT
    # No traffic -> p95 is null -> the latency SLO is N/A (neutral), not a violation.
    slo2 = None if slo["p95_ms"] is None else slo["p95_ms"] <= SLO_P95_MS
    ecs_degraded = any(v["running"] != v["desired"] for v in ecs.values())
    firing = len(alarms["firing"])

    if firing or not slo1:
        status = "CRITICAL"
    elif slo2 is False or ecs_degraded:
        status = "DEGRADED"
    else:
        status = "HEALTHY"

    budget = (ERROR_BUDGET_PCT - (100 - slo["success_pct"])) / ERROR_BUDGET_PCT * 100 \
        if slo["success_pct"] is not None else None
    burn = slo["err_rate_1h"] / (ERROR_BUDGET_PCT / 100) if slo["err_rate_1h"] is not None else None

    W = 64
    div, sub = "=" * W, "-" * W
    succ_s   = f"{slo['success_pct']:.3f}%" if slo["success_pct"] is not None else "N/A"
    p95_s    = f"{slo['p95_ms']:.0f}ms" if slo["p95_ms"] is not None else "N/A (no traffic)"
    poll_s   = f"{slo['poll_sync'] * 100:.1f}%" if slo["poll_sync"] is not None else "N/A"
    budget_s = f"{budget:.1f}%" if budget is not None else "N/A"
    burn_s   = f"{burn:.2f}x" if burn is not None else "N/A"

    L = [f"Subject: [Temporal SRE] Daily Report {date_str} — {status}", "",
         f"  Status   : {status}",
         f"  Period   : {date_str} (last 24h)",
         f"  Generated: {datetime.now(timezone.utc):%Y-%m-%d %H:%M UTC}", ""]

    L += [div, "SLO STATUS", div,
          fmt_slo("SLO-1  Workflow Success Rate", succ_s, f">= {SLO_SUCCESS_PCT}%", slo1),
          fmt_slo("SLO-2  Activity Sched-to-Start p95", p95_s, f"<= {SLO_P95_MS:.0f}ms", slo2),
          "",
          f"  Error Budget Remaining : {budget_s}  (99% / 30d)",
          f"  Burn Rate (1h)         : {burn_s}  (>14.4x = budget gone in ~2 days)",
          f"  Poll Sync Rate         : {poll_s}", ""]

    L += [div, "GOLDEN SIGNALS (worker SDK)", div,
          f"  Workflow throughput : {slo['wf_done']:.3f}/s done, {slo['wf_fail']:.3f}/s failed",
          f"  Active workers      : {int(slo['workers'])}",
          f"  Activity slots      : {int(slo['slots_used'])} used / {int(slo['slots_avail'])} available", ""]

    L += [div, "ECS SERVICES", div]
    for label, v in ecs.items():
        mark = "✓" if v["running"] == v["desired"] else "⚠ DEGRADED"
        L.append(f"  {label:<16} {v['running']}/{v['desired']}  {v['status']}  {mark}")
    L.append("")

    L += [div, "HOST METRICS (node_exporter)", div]
    if hosts:
        for inst, m in sorted(hosts.items()):
            L.append(f"  {inst:<14} CPU {m.get('cpu','?')}%  MEM {m.get('mem','?')}%  DISK {m.get('disk','?')}%")
    else:
        L.append("  (no host metrics — Prometheus unreachable?)")
    L.append("")

    L += [div, "RDS (PostgreSQL)", div,
          f"  State        : {rds['state']}",
          f"  CPU Avg      : {rds['cpu_avg']}%",
          f"  Connections  : max {rds['conn_max']}",
          f"  Free Storage : {rds['free_gb']} GB / {rds['allocated_gb']} GB"
          + ("  ✓" if rds['free_gb'] and rds['free_gb'] > 5 else "  ⚠ LOW"), ""]

    L += [div, "ALB / API (last 24h)", div,
          f"  Requests   : {alb['total_requests']:,}",
          f"  5xx Errors : {alb['total_5xx']:,}"
          + (f"  ({alb['total_5xx']/alb['total_requests']*100:.2f}%)" if alb['total_requests'] else ""),
          f"  Healthy Hosts (API TG) : {alb['healthy_hosts']}", ""]

    L += [div, "CLOUDWATCH ALARMS", div,
          f"  Firing : {firing}   OK : {alarms['ok']}   Other : {alarms['other']}"]
    for n in alarms["firing"]:
        L.append(f"  ⚠  {n}")
    L.append("")

    L += [div, "LOG ERRORS (last 24h, server+worker+api)", div,
          f"  Total error lines : {logs['count']}"]
    L += (["  Most recent:"] + logs["samples"]) if logs["samples"] else ["  No errors found ✓"]
    L.append("")

    passing = sum(1 for x in (slo1, slo2) if x)   # None (N/A) counts as not-failing, not passing
    L += [sub,
          f"  SLOs: {passing} passing, {sum(1 for x in (slo1, slo2) if x is False)} failing"
          f"  |  Alarms firing: {firing}  |  Status: {status}",
          sub, "",
          f"  Grafana → {GRAFANA_URL}",
          "  Auto-generated by the Temporal observability platform."]
    return "\n".join(L)


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description="Temporal daily reliability report")
    ap.add_argument("--dry-run", action="store_true", help="print report, do not publish to SNS")
    args = ap.parse_args()

    end = datetime.now(timezone.utc)
    start = end - timedelta(hours=24)
    date_str = end.strftime("%Y-%m-%d")
    print(f"Collecting Temporal reliability metrics for {date_str}…", file=sys.stderr)

    report = build_report(
        date_str,
        collect_slos(), collect_ecs(), collect_hosts(),
        collect_rds(start, end), collect_alb(start, end),
        collect_alarms(), collect_log_errors(start, end))

    if args.dry_run:
        print(report)
        return

    lines = report.splitlines()
    subject = lines[0].replace("Subject: ", "")[:100]
    body = "\n".join(lines[2:])
    sns = boto3.client("sns", region_name=REGION)
    resp = sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject, Message=body)
    print(f"Published to SNS (MessageId {resp['MessageId']}) — subject: {subject}", file=sys.stderr)


if __name__ == "__main__":
    main()
