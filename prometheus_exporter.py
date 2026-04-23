#!/usr/bin/env python3
"""System metrics exporter for Prometheus using psutil."""

import time
import json
import uuid
import logging
import psutil
from datetime import datetime, timezone
from prometheus_client import Gauge, start_http_server

# Logging Configuration
logging.basicConfig(
    level=logging.INFO,
    format='%(message)s',
    handlers=[logging.FileHandler('exporter.log'), logging.StreamHandler()]
)
logger = logging.getLogger(__name__)

class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_data = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "service": "python_exporter",
            "logger": record.name,
            "message": record.getMessage(),
            "trace_id": getattr(record, 'trace_id', None)
        }
        if record.exc_info:
            log_data["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_data)

for handler in logger.handlers:
    handler.setFormatter(JSONFormatter())

# Prometheus Metrics
CPU_GAUGE       = Gauge('node_cpu_usage_percent',   'Total CPU utilization (user + system)')
MEM_USED_GAUGE  = Gauge('node_memory_used_bytes',   'Memory currently in use (bytes)')
MEM_TOTAL_GAUGE = Gauge('node_memory_total_bytes',  'Total physical memory (bytes)')
DISK_USED_GAUGE = Gauge('node_disk_used_bytes',     'Disk space used on root filesystem (bytes)')
DISK_TOTAL_GAUGE= Gauge('node_disk_total_bytes',    'Total disk space on root filesystem (bytes)')
DISK_PCT_GAUGE  = Gauge('node_disk_usage_percent',  'Disk usage as a percentage')
PROC_GAUGE      = Gauge('node_processes_total',     'Number of running processes')

def collect_metrics():
    """Collects system stats and updates Prometheus gauges."""
    trace_id = str(uuid.uuid4())
    log = logging.LoggerAdapter(logger, {'trace_id': trace_id})

    try:
        cpu = psutil.cpu_percent(interval=1)
        mem = psutil.virtual_memory()
        disk = psutil.disk_usage('/')
        proc_count = len(psutil.pids())

        CPU_GAUGE.set(cpu)
        MEM_USED_GAUGE.set(mem.used)
        MEM_TOTAL_GAUGE.set(mem.total)
        DISK_USED_GAUGE.set(disk.used)
        DISK_TOTAL_GAUGE.set(disk.total)
        DISK_PCT_GAUGE.set(disk.percent)
        PROC_GAUGE.set(proc_count)

        log.info(f"Metrics updated: CPU={cpu}% MEM={mem.used}B DISK={disk.percent}% PROC={proc_count}")
    except Exception as e:
        log.error(f"Failed to collect metrics: {e}", exc_info=True)

def run_exporter(port=8000, interval=5):
    """Starts the HTTP server and enters the collection loop."""
    start_http_server(port)
    logger.info(f"Exporter live at http://localhost:{port}/metrics")
    
    while True:
        collect_metrics()
        time.sleep(interval)

if __name__ == '__main__':
    run_exporter()
