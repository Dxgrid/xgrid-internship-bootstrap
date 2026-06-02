#!/usr/bin/env python3
"""
Week 6 SRE Demo App

Replaces WordPress as the ECS application. Serves HTTP on :80 and exposes
Prometheus metrics on the same port at /metrics. Designed for the SRE
observability demo: kill container, spike CPU, scale tasks, stop service.
"""

import os
import socket
import time

from flask import Flask, jsonify
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

app = Flask(__name__)

# ── Prometheus metrics ────────────────────────────────────────────────────────

REQUEST_COUNT = Counter(
    "app_requests_total",
    "Total HTTP requests received",
    ["method", "endpoint", "status"],
)

REQUEST_LATENCY = Histogram(
    "app_request_latency_seconds",
    "HTTP request latency in seconds",
    ["endpoint"],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0],
)

APP_UP = Gauge(
    "app_up",
    "Whether the application is healthy (1 = up, 0 = down)",
)

APP_INFO = Gauge(
    "app_info",
    "Application metadata",
    ["version", "hostname", "environment"],
)

# Set static gauges once at startup.
APP_UP.set(1)
APP_INFO.labels(
    version="1.0.0",
    hostname=socket.gethostname(),
    environment=os.getenv("ENVIRONMENT", "dev"),
).set(1)


# ── Routes ────────────────────────────────────────────────────────────────────

@app.route("/")
def home():
    start = time.time()
    REQUEST_COUNT.labels("GET", "/", "200").inc()
    REQUEST_LATENCY.labels("/").observe(time.time() - start)
    return jsonify({
        "message": "Week 6 SRE Demo App",
        "hostname": socket.gethostname(),
        "status": "healthy",
        "version": "1.0.0",
    })


@app.route("/health")
def health():
    """ALB and ECS health check endpoint."""
    REQUEST_COUNT.labels("GET", "/health", "200").inc()
    return jsonify({"status": "ok"}), 200


@app.route("/metrics")
def metrics():
    """Prometheus scrape endpoint."""
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


@app.route("/simulate/cpu")
def simulate_cpu():
    """Burn CPU for 2 seconds — use during demo to trigger HighCPU alert."""
    start = time.time()
    deadline = time.time() + 2
    while time.time() < deadline:
        _ = [x ** 2 for x in range(10_000)]
    REQUEST_COUNT.labels("GET", "/simulate/cpu", "200").inc()
    REQUEST_LATENCY.labels("/simulate/cpu").observe(time.time() - start)
    return jsonify({"message": "CPU spike simulated", "duration_seconds": 2})


@app.route("/simulate/error")
def simulate_error():
    """Return a 500 — use during demo to trigger the alb-5xx alarm."""
    REQUEST_COUNT.labels("GET", "/simulate/error", "500").inc()
    return jsonify({"error": "Simulated server error"}), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80, debug=False)
