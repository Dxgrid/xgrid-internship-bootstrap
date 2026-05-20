#!/usr/bin/env python3
"""
Daily Reliability Report — WordPress ECS HA (Week 5 SRE Sprint)

Collects metrics from ECS, EC2, ALB, RDS, and Prometheus then generates
a structured SLO report and optionally sends it via SMTP email.

Usage:
  python3 daily-reliability-report.py \\
    --cluster wordpress-ecs-ha-dev-cluster \\
    --rds-identifier wordpress-ecs-ha-dev-mysql \\
    --alb-arn-suffix <value-from-terraform-output> \\
    --tg-arn-suffix  <value-from-terraform-output> \\
    --region us-east-1 \\
    --dry-run

Cron (runs daily at 06:00 UTC on the monitoring EC2):
  0 6 * * * /usr/bin/python3 /opt/monitoring/scripts/daily-reliability-report.py \\
      --cluster wordpress-ecs-ha-dev-cluster \\
      --rds-identifier wordpress-ecs-ha-dev-mysql \\
      --alb-arn-suffix <suffix> \\
      --tg-arn-suffix <suffix> >> /var/log/daily-report.log 2>&1
"""

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone

import boto3
import requests

# ─── SLO Thresholds ──────────────────────────────────────────────────────────
SLO_HTTP_AVAILABILITY_PCT = 99.5   # SLO-1: monthly availability target
SLO_P95_LATENCY_S         = 2.0    # SLO-2: p95 response time target (seconds)
SLO_MIN_RUNNING_TASKS     = 1      # SLO-3: minimum acceptable running tasks
SLO_RDS_MIN_STORAGE_GB    = 5.0    # SLO-4: minimum free RDS storage


def get_time_window(hours: int = 24):
    end   = datetime.now(timezone.utc)
    start = end - timedelta(hours=hours)
    return start, end


def query_cloudwatch(cw, namespace, metric, dimensions, stat, start, end, period=3600):
    resp = cw.get_metric_statistics(
        Namespace=namespace,
        MetricName=metric,
        Dimensions=dimensions,
        StartTime=start,
        EndTime=end,
        Period=period,
        Statistics=[stat],
    )
    points = resp.get("Datapoints", [])
    if not points:
        return None
    return [p[stat] for p in sorted(points, key=lambda x: x["Timestamp"])]


def query_cloudwatch_extended(cw, namespace, metric, dimensions, stat, start, end, period=3600):
    resp = cw.get_metric_statistics(
        Namespace=namespace,
        MetricName=metric,
        Dimensions=dimensions,
        StartTime=start,
        EndTime=end,
        Period=period,
        ExtendedStatistics=[stat],
    )
    points = resp.get("Datapoints", [])
    if not points:
        return None
    return [p["ExtendedStatistics"][stat] for p in sorted(points, key=lambda x: x["Timestamp"])]


def prometheus_query(prometheus_url: str, query: str):
    try:
        resp = requests.get(
            f"{prometheus_url}/api/v1/query",
            params={"query": query},
            timeout=5,
        )
        data = resp.json()
        if data.get("status") == "success":
            return data["data"]["result"]
    except Exception:
        pass
    return []


# ─── Section 1: ECS ──────────────────────────────────────────────────────────

def collect_ecs_status(cluster: str, region: str, start, end):
    ecs  = boto3.client("ecs", region_name=region)
    ec2  = boto3.client("ec2", region_name=region)

    clusters = ecs.describe_clusters(clusters=[cluster])["clusters"]
    if not clusters:
        return {"error": f"Cluster '{cluster}' not found"}

    c = clusters[0]
    running   = c.get("runningTasksCount", 0)
    pending   = c.get("pendingTasksCount", 0)
    instances = c.get("registeredContainerInstancesCount", 0)

    # Count stopped tasks in last 24h as proxy for container restarts
    stopped_arns = ecs.list_tasks(
        cluster=cluster,
        desiredStatus="STOPPED",
    ).get("taskArns", [])

    restart_count = 0
    if stopped_arns:
        tasks = ecs.describe_tasks(cluster=cluster, tasks=stopped_arns[:10])["tasks"]
        for t in tasks:
            stopped_at = t.get("stoppedAt")
            if stopped_at and stopped_at >= start:
                restart_count += 1

    return {
        "cluster": cluster,
        "running_tasks": running,
        "pending_tasks": pending,
        "registered_instances": instances,
        "restarts_24h": restart_count,
    }


# ─── Section 2: EC2 Metrics (via CloudWatch) ─────────────────────────────────

def collect_ec2_metrics(region: str, cluster_name: str, start, end):
    ec2 = boto3.client("ec2", region_name=region)
    cw  = boto3.client("cloudwatch", region_name=region)

    instances_resp = ec2.describe_instances(
        Filters=[
            {"Name": "tag:AmazonECSManaged", "Values": ["true"]},
            {"Name": "instance-state-name",  "Values": ["running"]},
        ]
    )
    instances = []
    for r in instances_resp["Reservations"]:
        for i in r["Instances"]:
            instances.append({
                "id":         i["InstanceId"],
                "private_ip": i.get("PrivateIpAddress", "unknown"),
            })

    results = []
    for inst in instances:
        dims = [{"Name": "InstanceId", "Value": inst["id"]}]
        cpu_points = query_cloudwatch(cw, "AWS/EC2", "CPUUtilization", dims, "Average", start, end)
        results.append({
            "instance_id": inst["id"],
            "private_ip":  inst["private_ip"],
            "cpu_avg":     round(sum(cpu_points) / len(cpu_points), 1) if cpu_points else None,
            "cpu_max":     round(max(cpu_points), 1) if cpu_points else None,
        })
    return results


# ─── Section 3+4: Host Metrics via Prometheus ────────────────────────────────

def collect_host_metrics(prometheus_url: str):
    disk_results = prometheus_query(
        prometheus_url,
        '100 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} * 100)'
    )
    mem_results = prometheus_query(
        prometheus_url,
        "100 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100)"
    )

    hosts = {}
    for r in disk_results:
        instance = r["metric"].get("instance", "unknown")
        hosts.setdefault(instance, {})["disk_pct"] = round(float(r["value"][1]), 1)

    for r in mem_results:
        instance = r["metric"].get("instance", "unknown")
        hosts.setdefault(instance, {})["mem_pct"] = round(float(r["value"][1]), 1)

    return hosts


# ─── Section 5: ALB Metrics ──────────────────────────────────────────────────

def collect_alb_metrics(alb_suffix: str, tg_suffix: str, region: str, start, end):
    cw = boto3.client("cloudwatch", region_name=region)
    alb_dims = [{"Name": "LoadBalancer", "Value": alb_suffix}]
    tg_dims  = alb_dims + [{"Name": "TargetGroup", "Value": tg_suffix}]

    requests_pts = query_cloudwatch(cw, "AWS/ApplicationELB", "RequestCount",              alb_dims, "Sum",     start, end) or [0]
    errors_5xx   = query_cloudwatch(cw, "AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", alb_dims, "Sum",     start, end) or [0]
    errors_4xx   = query_cloudwatch(cw, "AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", alb_dims, "Sum",     start, end) or [0]
    latency_p95  = query_cloudwatch_extended(cw, "AWS/ApplicationELB", "TargetResponseTime", alb_dims, "p95",   start, end)

    total_req   = sum(requests_pts)
    total_5xx   = sum(errors_5xx)
    total_4xx   = sum(errors_4xx)
    availability = ((total_req - total_5xx) / total_req * 100) if total_req > 0 else 100.0
    p95_latency  = round(max(latency_p95), 3) if latency_p95 else None

    return {
        "total_requests":  int(total_req),
        "total_5xx":       int(total_5xx),
        "total_4xx":       int(total_4xx),
        "availability_pct": round(availability, 4),
        "p95_latency_s":   p95_latency,
    }


# ─── Section 6: RDS Metrics ──────────────────────────────────────────────────

def collect_rds_metrics(rds_identifier: str, region: str, start, end):
    rds = boto3.client("rds", region_name=region)
    cw  = boto3.client("cloudwatch", region_name=region)

    instances = rds.describe_db_instances(DBInstanceIdentifier=rds_identifier)["DBInstances"]
    if not instances:
        return {"error": f"RDS instance '{rds_identifier}' not found"}

    inst  = instances[0]
    state = inst.get("DBInstanceStatus", "unknown")
    allocated_gb = inst.get("AllocatedStorage", 0)

    dims = [{"Name": "DBInstanceIdentifier", "Value": rds_identifier}]
    cpu_pts     = query_cloudwatch(cw, "AWS/RDS", "CPUUtilization",    dims, "Average", start, end) or [0]
    conn_pts    = query_cloudwatch(cw, "AWS/RDS", "DatabaseConnections", dims, "Average", start, end) or [0]
    conn_max    = query_cloudwatch(cw, "AWS/RDS", "DatabaseConnections", dims, "Maximum", start, end) or [0]
    storage_pts = query_cloudwatch(cw, "AWS/RDS", "FreeStorageSpace",  dims, "Minimum", start, end) or [allocated_gb * 1e9]

    free_storage_gb = round(min(storage_pts) / 1e9, 2)

    return {
        "state":           state,
        "allocated_gb":    allocated_gb,
        "free_storage_gb": free_storage_gb,
        "cpu_avg":         round(sum(cpu_pts) / len(cpu_pts), 1) if cpu_pts else None,
        "conn_avg":        round(sum(conn_pts) / len(conn_pts), 1) if conn_pts else None,
        "conn_max":        int(max(conn_max)) if conn_max else None,
    }


# ─── Section 7: Alarm States ─────────────────────────────────────────────────

def collect_alarm_states(region: str, project_prefix: str):
    cw = boto3.client("cloudwatch", region_name=region)
    paginator = cw.get_paginator("describe_alarms")

    counts = {"ALARM": 0, "OK": 0, "INSUFFICIENT_DATA": 0}
    active_alarms = []

    for page in paginator.paginate(AlarmNamePrefix=project_prefix):
        for alarm in page.get("MetricAlarms", []):
            state = alarm["StateValue"]
            counts[state] = counts.get(state, 0) + 1
            if state == "ALARM":
                active_alarms.append({
                    "name":        alarm["AlarmName"],
                    "description": alarm.get("AlarmDescription", ""),
                })
        for alarm in page.get("CompositeAlarms", []):
            state = alarm["StateValue"]
            counts[state] = counts.get(state, 0) + 1
            if state == "ALARM":
                active_alarms.append({"name": alarm["AlarmName"], "description": ""})

    return {"counts": counts, "active": active_alarms}


# ─── SLO Evaluation ──────────────────────────────────────────────────────────

def evaluate_slos(ecs, alb, rds):
    slos = []

    # SLO-1: HTTP Availability
    avail = alb.get("availability_pct", 100.0)
    slos.append({
        "id":     "SLO-1",
        "name":   "HTTP Availability",
        "value":  f"{avail:.4f}%",
        "target": f"≥ {SLO_HTTP_AVAILABILITY_PCT}%",
        "pass":   avail >= SLO_HTTP_AVAILABILITY_PCT,
    })

    # SLO-2: p95 Latency
    p95 = alb.get("p95_latency_s")
    if p95 is not None:
        slos.append({
            "id":     "SLO-2",
            "name":   "p95 Request Latency",
            "value":  f"{p95:.3f}s",
            "target": f"≤ {SLO_P95_LATENCY_S}s",
            "pass":   p95 <= SLO_P95_LATENCY_S,
        })
    else:
        slos.append({"id": "SLO-2", "name": "p95 Request Latency", "value": "N/A (no data)", "target": f"≤ {SLO_P95_LATENCY_S}s", "pass": None})

    # SLO-3: Task Availability
    running = ecs.get("running_tasks", 0)
    slos.append({
        "id":     "SLO-3",
        "name":   "ECS Task Availability",
        "value":  f"{running} running",
        "target": f"≥ {SLO_MIN_RUNNING_TASKS} task(s)",
        "pass":   running >= SLO_MIN_RUNNING_TASKS,
    })

    # SLO-4: RDS Storage
    free_gb = rds.get("free_storage_gb", 0)
    slos.append({
        "id":     "SLO-4",
        "name":   "RDS Free Storage",
        "value":  f"{free_gb:.2f} GB free",
        "target": f"> {SLO_RDS_MIN_STORAGE_GB} GB",
        "pass":   free_gb > SLO_RDS_MIN_STORAGE_GB,
    })

    return slos


# ─── Report Formatting ────────────────────────────────────────────────────────

def format_report(date_str, ecs, ec2_instances, host_metrics, alb, rds, alarms, slos):
    passed    = sum(1 for s in slos if s["pass"] is True)
    failed    = sum(1 for s in slos if s["pass"] is False)
    overall   = "CRITICAL" if alarms["counts"].get("ALARM", 0) > 0 or failed > 0 else \
                "DEGRADED"  if ecs.get("running_tasks", 0) < 2 else "HEALTHY"

    lines = [
        f"Subject: [Daily SRE Report] WordPress ECS HA — {date_str} — Status: {overall}",
        "",
        f"Overall Status : {overall}",
        f"Report Period  : {date_str} (last 24 hours)",
        f"Generated      : {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}",
        "",
        "=" * 60,
        "ECS CLUSTER",
        "=" * 60,
        f"Cluster        : {ecs.get('cluster', 'N/A')}",
        f"Running Tasks  : {ecs.get('running_tasks', 'N/A')}",
        f"Pending Tasks  : {ecs.get('pending_tasks', 0)}",
        f"EC2 Instances  : {ecs.get('registered_instances', 0)}",
        f"Restarts (24h) : {ecs.get('restarts_24h', 0)}",
        "",
        "=" * 60,
        "EC2 INSTANCE METRICS (from CloudWatch)",
        "=" * 60,
    ]

    if ec2_instances:
        for inst in ec2_instances:
            host_data = host_metrics.get(f"{inst['private_ip']}:9100", {})
            cpu_avg = f"{inst['cpu_avg']}%" if inst.get("cpu_avg") is not None else "N/A"
            cpu_max = f"{inst['cpu_max']}%" if inst.get("cpu_max") is not None else "N/A"
            mem     = f"{host_data.get('mem_pct', 'N/A')}%" if host_data.get("mem_pct") else "N/A (Prometheus)"
            disk    = f"{host_data.get('disk_pct', 'N/A')}%" if host_data.get("disk_pct") else "N/A (Prometheus)"
            lines.append(f"  {inst['instance_id']} ({inst['private_ip']})")
            lines.append(f"    CPU Avg/Max : {cpu_avg} / {cpu_max}")
            lines.append(f"    Memory      : {mem} used")
            lines.append(f"    Disk /      : {disk} used")
    else:
        lines.append("  No running ECS EC2 instances found.")

    avail    = alb.get("availability_pct", 100.0)
    p95      = alb.get("p95_latency_s")
    p95_str  = f"{p95:.3f}s" if p95 is not None else "N/A"
    slo1_ok  = "✓" if avail >= SLO_HTTP_AVAILABILITY_PCT else "✗ SLO BREACH"
    slo2_ok  = ("✓" if p95 <= SLO_P95_LATENCY_S else "✗ SLO BREACH") if p95 is not None else "?"

    lines += [
        "",
        "=" * 60,
        "ALB PERFORMANCE (last 24h)",
        "=" * 60,
        f"Total Requests : {alb.get('total_requests', 0):,}",
        f"5XX Errors     : {alb.get('total_5xx', 0):,} ({alb.get('total_5xx', 0) / max(alb.get('total_requests', 1), 1) * 100:.2f}%)",
        f"4XX Errors     : {alb.get('total_4xx', 0):,}",
        f"Availability   : {avail:.4f}%  [SLO ≥ {SLO_HTTP_AVAILABILITY_PCT}%] {slo1_ok}",
        f"p95 Latency    : {p95_str}  [SLO ≤ {SLO_P95_LATENCY_S}s] {slo2_ok}",
        "",
        "=" * 60,
        "RDS DATABASE",
        "=" * 60,
        f"State          : {rds.get('state', 'N/A')}",
        f"CPU Avg (24h)  : {rds.get('cpu_avg', 'N/A')}%",
        f"Connections    : avg {rds.get('conn_avg', 'N/A')} / max {rds.get('conn_max', 'N/A')}",
        f"Free Storage   : {rds.get('free_storage_gb', 'N/A')} GB / {rds.get('allocated_gb', 'N/A')} GB"
        + ("  ✓" if rds.get("free_storage_gb", 0) > SLO_RDS_MIN_STORAGE_GB else "  ✗ SLO BREACH"),
        "",
        "=" * 60,
        "CLOUDWATCH ALARM STATUS",
        "=" * 60,
        f"ALARM           : {alarms['counts'].get('ALARM', 0)}",
        f"OK              : {alarms['counts'].get('OK', 0)}",
        f"INSUFFICIENT    : {alarms['counts'].get('INSUFFICIENT_DATA', 0)}",
    ]

    if alarms["active"]:
        lines.append("")
        lines.append("Active Alarms:")
        for a in alarms["active"]:
            lines.append(f"  ⚠  {a['name']}")
            if a.get("description"):
                lines.append(f"     {a['description']}")

    lines += [
        "",
        "=" * 60,
        "SLO SUMMARY",
        "=" * 60,
    ]
    for slo in slos:
        status = "PASS ✓" if slo["pass"] is True else "FAIL ✗" if slo["pass"] is False else "N/A"
        lines.append(f"[{slo['id']}] {slo['name']:<25} {status:<8} {slo['value']} (target: {slo['target']})")

    lines += [
        "",
        "─" * 60,
        f"SLOs Passing: {passed}/{len(slos)}  |  Status: {overall}",
        "─" * 60,
        "",
        "This report was generated automatically by the Week 5 SRE Observability Platform.",
        "For dashboards, open Grafana at: http://<alb-dns>/grafana",
    ]

    return "\n".join(lines)


# ─── Email Sending (SNS) ────────────────────────────────────────────────────

def send_via_sns(subject_line: str, body: str, topic_arn: str, region: str):
    """
    Publish the report to SNS topic.

    SNS handles email delivery to all subscribed addresses (e.g., your inbox).
    No credentials needed — uses EC2 IAM role to call sns:Publish.

    Args:
      subject_line — Report subject (extracted from first line)
      body — Report body text
      topic_arn — SNS topic ARN (e.g., arn:aws:sns:us-east-1:123...:wordpress-alerts)
      region — AWS region
    """
    try:
        sns = boto3.client("sns", region_name=region)
        subject = subject_line.replace("[Daily SRE Report] ", "", 1)
        response = sns.publish(
            TopicArn=topic_arn,
            Subject=subject,
            Message=body
        )
        print(f"Report published to SNS topic (MessageId: {response['MessageId']})", file=sys.stderr)
        return True
    except Exception as e:
        print(f"ERROR: Failed to publish to SNS: {e}", file=sys.stderr)
        return False


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Daily SRE Reliability Report")
    parser.add_argument("--cluster",        required=True, help="ECS cluster name")
    parser.add_argument("--rds-identifier", required=True, help="RDS DB instance identifier")
    parser.add_argument("--alb-arn-suffix", required=True, help="ALB ARN suffix (from terraform output)")
    parser.add_argument("--tg-arn-suffix",  required=True, help="WordPress target group ARN suffix")
    parser.add_argument("--region",         default="us-east-1", help="AWS region")
    parser.add_argument("--prometheus-url", default="http://localhost:9090", help="Prometheus base URL")
    parser.add_argument("--sns-topic-arn",  help="SNS topic ARN for email delivery (if not provided, uses --dry-run)")
    parser.add_argument("--dry-run",        action="store_true", help="Print report to stdout; do not publish to SNS")
    args = parser.parse_args()

    start, end = get_time_window(hours=24)
    date_str   = end.strftime("%Y-%m-%d")

    print(f"Collecting metrics for {date_str}...", file=sys.stderr)

    ecs_data      = collect_ecs_status(args.cluster, args.region, start, end)
    ec2_data      = collect_ec2_metrics(args.region, args.cluster, start, end)
    host_data     = collect_host_metrics(args.prometheus_url)
    alb_data      = collect_alb_metrics(args.alb_arn_suffix, args.tg_arn_suffix, args.region, start, end)
    rds_data      = collect_rds_metrics(args.rds_identifier, args.region, start, end)
    alarm_data    = collect_alarm_states(args.region, project_prefix="wordpress-ecs-ha")
    slos          = evaluate_slos(ecs_data, alb_data, rds_data)

    report = format_report(date_str, ecs_data, ec2_data, host_data, alb_data, rds_data, alarm_data, slos)

    if args.dry_run or not args.sns_topic_arn:
        print(report)
    else:
        subject_line = report.splitlines()[0]
        body         = "\n".join(report.splitlines()[2:])
        sent = send_via_sns(subject_line, body, args.sns_topic_arn, args.region)
        if not sent:
            print(report)


if __name__ == "__main__":
    main()
