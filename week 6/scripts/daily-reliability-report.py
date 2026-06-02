#!/usr/bin/env python3
"""
Daily Reliability Report — Flask SRE Platform (Week 6)

Collects SLI/SLO metrics from Prometheus (via Grafana proxy) and infrastructure
health from CloudWatch, then publishes a structured report to SNS.

Usage:
  python3 daily-reliability-report.py            # publish to SNS
  python3 daily-reliability-report.py --dry-run  # print to stdout only

Cron (runs daily at 06:00 UTC):
  0 6 * * * python3 /path/to/daily-reliability-report.py >> /var/log/daily-report.log 2>&1
"""

import os
import sys
import argparse
from datetime import datetime, timedelta, timezone

import boto3
import requests

# ── Week 6 Config ─────────────────────────────────────────────────────────────

REGION          = "us-east-1"
CLUSTER         = "flask-sre-ecs-dev-cluster"
SERVICES        = {
    "demo-app":   "flask-sre-ecs-dev-demo-app-svc",
    "prometheus": "flask-sre-ecs-dev-prometheus-svc",
    "grafana":    "flask-sre-ecs-dev-grafana-svc",
}
RDS_ID          = "terraform-20260601150050372800000001"
ALB_SUFFIX      = "app/flask-sre-ecs-dev-alb/db8e8e73ba84b393"
APP_TG_SUFFIX   = "targetgroup/app-tg2026060114554885620000000c/3eed688ba5411e74"
SNS_TOPIC_ARN   = "arn:aws:sns:us-east-1:432500708329:flask-sre-ecs-dev-alerts"
GRAFANA_URL     = "http://flask-sre-ecs-dev-alb-388642593.us-east-1.elb.amazonaws.com/grafana"
GRAFANA_USER    = "admin"
GRAFANA_PASS    = os.environ.get("GRAFANA_PASSWORD", "GrafanaSecure2026")
PROM_DS_UID     = "PBFA97CFB590B2093"
APP_LOG_GROUP   = "/ecs/flask-sre-ecs/dev/demo-app"
ALARM_PREFIX    = "flask-sre-ecs-dev"

# ── SLO Targets ───────────────────────────────────────────────────────────────

SLO_AVAILABILITY_PCT = 99.5   # SLO-1: HTTP availability
SLO_P95_LATENCY_S    = 2.0    # SLO-2: p95 response time
ERROR_BUDGET_PCT     = 0.5    # 100% - 99.5% = 0.5% budget


# ── Prometheus via Grafana Proxy ──────────────────────────────────────────────

def prom_query(promql: str) -> list:
    try:
        r = requests.get(
            f"{GRAFANA_URL}/api/datasources/proxy/uid/{PROM_DS_UID}/api/v1/query",
            params={"query": promql},
            auth=(GRAFANA_USER, GRAFANA_PASS),
            timeout=10,
        )
        data = r.json()
        if data.get("status") == "success":
            return data["data"]["result"]
    except Exception as e:
        print(f"  [warn] Prometheus query failed: {e}", file=sys.stderr)
    return []


def prom_scalar(promql: str, default=None):
    results = prom_query(promql)
    if not results:
        return default
    val = results[0]["value"][1]
    return None if val == "NaN" else float(val)


# ── CloudWatch Helper ─────────────────────────────────────────────────────────

def cw_stat(namespace, metric, dimensions, stat, start, end, period=86400):
    cw = boto3.client("cloudwatch", region_name=REGION)
    resp = cw.get_metric_statistics(
        Namespace=namespace, MetricName=metric, Dimensions=dimensions,
        StartTime=start, EndTime=end, Period=period, Statistics=[stat],
    )
    pts = sorted(resp.get("Datapoints", []), key=lambda x: x["Timestamp"])
    return [p[stat] for p in pts] or None


# ── Data Collection ───────────────────────────────────────────────────────────

def collect_slos():
    avail    = prom_scalar("job:app_requests_success:ratio_rate5m * 100", default=100.0)
    p95_s    = prom_scalar("job:app_request_latency_seconds:p95rate5m")
    budget   = prom_scalar(
        "((1-0.995) - (1-job:app_requests_success:ratio_rate5m)) / (1-0.995) * 100",
        default=100.0,
    )
    burn     = prom_scalar(
        "(1 - job:app_requests_success:ratio_rate5m) / (1 - 0.995)",
        default=0.0,
    )
    req_rate = prom_scalar("job:app_requests:rate5m", default=0.0)
    err_rate = prom_scalar("job:app_request_errors:ratio_rate5m * 100", default=0.0)
    return dict(
        availability=avail, p95_s=p95_s,
        error_budget=budget, burn_rate=burn,
        req_rate=req_rate, error_rate=err_rate,
    )


def collect_ecs():
    ecs = boto3.client("ecs", region_name=REGION)
    results = {}
    for label, svc_name in SERVICES.items():
        try:
            resp = ecs.describe_services(cluster=CLUSTER, services=[svc_name])
            s = resp["services"][0]
            results[label] = {
                "desired": s["desiredCount"],
                "running": s["runningCount"],
                "status":  s["status"],
            }
        except Exception:
            results[label] = {"desired": "?", "running": "?", "status": "ERROR"}
    return results


def collect_host_metrics():
    cpu_results = prom_query("instance:node_cpu_utilisation:rate5m")
    mem_results = prom_query("instance:node_memory_utilisation:ratio * 100")
    dsk_results = prom_query("instance:node_filesystem_utilisation:ratio * 100")

    hosts = {}
    for r in cpu_results:
        inst = r["metric"].get("instance", "?")
        hosts.setdefault(inst, {})["cpu"] = round(float(r["value"][1]), 1)
    for r in mem_results:
        inst = r["metric"].get("instance", "?")
        hosts.setdefault(inst, {})["mem"] = round(float(r["value"][1]), 1)
    for r in dsk_results:
        inst = r["metric"].get("instance", "?")
        hosts.setdefault(inst, {})["disk"] = round(float(r["value"][1]), 1)
    return hosts


def collect_rds(start, end):
    dims = [{"Name": "DBInstanceIdentifier", "Value": RDS_ID}]
    cpu  = cw_stat("AWS/RDS", "CPUUtilization",    dims, "Average", start, end)
    conn = cw_stat("AWS/RDS", "DatabaseConnections", dims, "Maximum", start, end)
    free = cw_stat("AWS/RDS", "FreeStorageSpace",  dims, "Minimum", start, end)

    rds  = boto3.client("rds", region_name=REGION)
    try:
        inst = rds.describe_db_instances(DBInstanceIdentifier=RDS_ID)["DBInstances"][0]
        state = inst["DBInstanceStatus"]
        allocated_gb = inst["AllocatedStorage"]
    except Exception:
        state, allocated_gb = "unknown", 20

    return {
        "state":        state,
        "allocated_gb": allocated_gb,
        "free_gb":      round(min(free) / 1e9, 2) if free else None,
        "cpu_avg":      round(sum(cpu) / len(cpu), 1) if cpu else None,
        "conn_max":     int(max(conn)) if conn else None,
    }


def collect_alb(start, end):
    dims = [{"Name": "LoadBalancer", "Value": ALB_SUFFIX}]
    tg_dims = dims + [{"Name": "TargetGroup", "Value": APP_TG_SUFFIX}]

    reqs = cw_stat("AWS/ApplicationELB", "RequestCount",              dims,    "Sum",     start, end) or [0]
    e5xx = cw_stat("AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", dims,    "Sum",     start, end) or [0]
    hlt  = cw_stat("AWS/ApplicationELB", "HealthyHostCount",          tg_dims, "Minimum", start, end)

    total  = sum(reqs)
    errors = sum(e5xx)
    return {
        "total_requests":  int(total),
        "total_5xx":       int(errors),
        "healthy_hosts":   int(min(hlt)) if hlt else None,
    }


def collect_alarms():
    cw = boto3.client("cloudwatch", region_name=REGION)
    firing, ok, unknown = [], 0, 0
    for page in cw.get_paginator("describe_alarms").paginate(AlarmNamePrefix=ALARM_PREFIX):
        for a in page.get("MetricAlarms", []) + page.get("CompositeAlarms", []):
            if a["StateValue"] == "ALARM":
                firing.append(a["AlarmName"])
            elif a["StateValue"] == "OK":
                ok += 1
            else:
                unknown += 1
    return {"firing": firing, "ok": ok, "unknown": unknown}


def collect_log_errors(start, end):
    logs = boto3.client("logs", region_name=REGION)
    try:
        pages = logs.get_paginator("filter_log_events").paginate(
            logGroupName=APP_LOG_GROUP,
            startTime=int(start.timestamp() * 1000),
            endTime=int(end.timestamp() * 1000),
            filterPattern="?ERROR ?error ?Fatal",
            PaginationConfig={"MaxItems": 100},
        )
        count, samples = 0, []
        for page in pages:
            for ev in page.get("events", []):
                count += 1
                if len(samples) < 3:
                    ts  = datetime.fromtimestamp(ev["timestamp"] / 1000, tz=timezone.utc)
                    samples.append(f"  [{ts.strftime('%H:%M')} UTC] {ev['message'].strip()[:100]}")
        return {"count": count, "samples": samples}
    except Exception as e:
        return {"count": 0, "samples": [], "error": str(e)}


# ── Report Formatting ─────────────────────────────────────────────────────────

def fmt_slo(name, value_str, target_str, passing):
    mark = "PASS ✓" if passing else "FAIL ✗"
    return f"  {name:<28} {mark:<8}  {value_str}  (target: {target_str})"


def format_report(date_str, slos, ecs, hosts, rds, alb, alarms, logs):
    slo1_pass = slos["availability"] is not None and slos["availability"] >= SLO_AVAILABILITY_PCT
    slo2_pass = slos["p95_s"] is not None and slos["p95_s"] <= SLO_P95_LATENCY_S

    slos_failing = sum([not slo1_pass, not slo2_pass])
    alarms_firing = len(alarms["firing"])

    if alarms_firing > 0 or slos_failing > 0:
        status = "CRITICAL" if alarms_firing > 0 else "DEGRADED"
    else:
        status = "HEALTHY"

    W = 62
    div = "=" * W

    def section(title):
        return [div, title, div]

    avail_str  = f"{slos['availability']:.3f}%" if slos["availability"] is not None else "N/A"
    p95_str    = f"{slos['p95_s'] * 1000:.1f}ms" if slos["p95_s"] is not None else "N/A (no traffic)"
    budget_str = f"{slos['error_budget']:.1f}%" if slos["error_budget"] is not None else "N/A"
    burn_str   = f"{slos['burn_rate']:.2f}x" if slos["burn_rate"] is not None else "N/A"

    lines = [
        f"Subject: [SRE Daily Report] Flask SRE Week 6 — {date_str} — {status}",
        "",
        f"  Status   : {status}",
        f"  Period   : {date_str} (last 24 hours)",
        f"  Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}",
        "",
    ]

    lines += section("SLO STATUS")
    lines += [
        fmt_slo("SLO-1  HTTP Availability",  avail_str,  f"≥ {SLO_AVAILABILITY_PCT}%", slo1_pass),
        fmt_slo("SLO-2  p95 Latency",        p95_str,    f"≤ {SLO_P95_LATENCY_S * 1000:.0f}ms", slo2_pass),
        "",
        f"  Error Budget Remaining : {budget_str}",
        f"  Burn Rate              : {burn_str}  (>2x = budget gone in <15 days)",
        f"  Request Rate (current) : {slos['req_rate']:.2f} req/s",
        f"  Error Rate  (current)  : {slos['error_rate']:.2f}%",
        "",
    ]

    lines += section("ECS SERVICES")
    for label, svc in ecs.items():
        health = "✓" if svc["running"] == svc["desired"] else "⚠ degraded"
        lines.append(f"  {label:<12} running={svc['running']}/{svc['desired']}  status={svc['status']}  {health}")
    lines.append("")

    lines += section("HOST METRICS (via Prometheus node_exporter)")
    if hosts:
        for inst, m in hosts.items():
            cpu  = f"{m.get('cpu', 'N/A')}%"
            mem  = f"{m.get('mem', 'N/A')}%"
            disk = f"{m.get('disk', 'N/A')}%"
            lines.append(f"  {inst}")
            lines.append(f"    CPU {cpu:<8}  Memory {mem:<8}  Disk {disk}")
    else:
        lines.append("  No host metrics available (Prometheus unreachable?)")
    lines.append("")

    lines += section("RDS DATABASE")
    lines += [
        f"  State        : {rds['state']}",
        f"  CPU Avg      : {rds['cpu_avg']}%",
        f"  Connections  : max {rds['conn_max']} (limit ~85 on t3.micro)",
        f"  Free Storage : {rds['free_gb']} GB / {rds['allocated_gb']} GB"
        + ("  ✓" if rds["free_gb"] and rds["free_gb"] > 5 else "  ⚠ LOW"),
        "",
    ]

    lines += section("ALB TRAFFIC (last 24h)")
    lines += [
        f"  Total Requests : {alb['total_requests']:,}",
        f"  5xx Errors     : {alb['total_5xx']:,}"
        + (f"  ({alb['total_5xx'] / alb['total_requests'] * 100:.2f}%)" if alb["total_requests"] else ""),
        f"  Healthy Hosts  : {alb['healthy_hosts']}",
        "",
    ]

    lines += section("CLOUDWATCH ALARMS")
    lines += [
        f"  Firing : {alarms_firing}",
        f"  OK     : {alarms['ok']}",
        f"  Other  : {alarms['unknown']}",
    ]
    if alarms["firing"]:
        lines.append("")
        for name in alarms["firing"]:
            lines.append(f"  ⚠  {name}")
    lines.append("")

    lines += section("APP LOG ERRORS (last 24h)")
    if logs.get("error"):
        lines.append(f"  Could not fetch logs: {logs['error']}")
    else:
        lines.append(f"  Total error lines : {logs['count']}")
        if logs["samples"]:
            lines.append("  Most recent:")
            lines.extend(logs["samples"])
        else:
            lines.append("  No errors found ✓")
    lines.append("")

    lines += [
        "─" * W,
        f"  SLOs Passing: {'2/2' if slo1_pass and slo2_pass else '1/2' if slo1_pass or slo2_pass else '0/2'}  |  "
        f"Alarms Firing: {alarms_firing}  |  Status: {status}",
        "─" * W,
        "",
        f"  Grafana dashboards → {GRAFANA_URL}",
        "  This report is generated automatically by the Week 6 SRE Platform.",
    ]

    return "\n".join(lines)


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Week 6 Daily SRE Reliability Report")
    parser.add_argument("--dry-run", action="store_true", help="Print report to stdout, do not publish to SNS")
    args = parser.parse_args()

    end   = datetime.now(timezone.utc)
    start = end - timedelta(hours=24)
    date_str = end.strftime("%Y-%m-%d")

    print(f"Collecting metrics for {date_str}...", file=sys.stderr)

    slo_data   = collect_slos()
    ecs_data   = collect_ecs()
    host_data  = collect_host_metrics()
    rds_data   = collect_rds(start, end)
    alb_data   = collect_alb(start, end)
    alarm_data = collect_alarms()
    log_data   = collect_log_errors(start, end)

    report = format_report(date_str, slo_data, ecs_data, host_data, rds_data, alb_data, alarm_data, log_data)

    if args.dry_run:
        print(report)
        return

    sns = boto3.client("sns", region_name=REGION)
    lines = report.splitlines()
    subject = lines[0].replace("Subject: ", "")
    body    = "\n".join(lines[2:])
    resp = sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject, Message=body)
    print(f"Published to SNS (MessageId: {resp['MessageId']})", file=sys.stderr)


if __name__ == "__main__":
    main()
