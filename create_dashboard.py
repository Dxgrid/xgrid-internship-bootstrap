#!/usr/bin/env python3
"""
Professional Grafana Dashboard Generator for System Monitoring.
Configures a high-fidelity dashboard with thresholds, organized layouts, and proper units.
"""

import requests
import json

# Grafana Configuration
GRAFANA_URL = 'http://localhost:3000/api/dashboards/db'
GRAFANA_AUTH = ('admin', 'admin')

def create_panel(title, p_type, grid_pos, targets, unit=None, thresholds=None):
    panel = {
        "title": title,
        "type": p_type,
        "gridPos": grid_pos,
        "targets": targets,
        "datasource": {"type": "prometheus", "uid": "prometheus"},
    }
    
    if unit or thresholds:
        panel["fieldConfig"] = {
            "defaults": {
                "unit": unit,
                "thresholds": thresholds or {
                    "mode": "absolute",
                    "steps": [
                        {"color": "green", "value": None},
                        {"color": "orange", "value": 70},
                        {"color": "red", "value": 90}
                    ]
                }
            }
        }
    
    # Modern look for time series
    if p_type == "timeseries":
        panel["options"] = {
            "legend": {"displayMode": "table", "placement": "bottom", "calcs": ["mean", "last", "max"]},
            "tooltip": {"mode": "multi", "sort": "desc"}
        }
    
    return panel

dashboard_payload = {
    "dashboard": {
        "id": None,
        "uid": "system-observability-pro",
        "title": "🚀 System Observability Pro",
        "tags": ["system", "monitoring", "pro"],
        "timezone": "browser",
        "schemaVersion": 36,
        "version": 1,
        "refresh": "5s",
        "panels": [
            # --- Row 1: Key Stats ---
            create_panel(
                "CPU Utilization", "gauge", 
                {"x": 0, "y": 0, "w": 6, "h": 8},
                [{"expr": "node_cpu_usage_percent", "refId": "A"}],
                "percent",
                {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 70}, {"color": "red", "value": 85}]}
            ),
            create_panel(
                "Memory Usage", "gauge", 
                {"x": 6, "y": 0, "w": 6, "h": 8},
                [{"expr": "(node_memory_used_bytes / node_memory_total_bytes) * 100", "refId": "A"}],
                "percent",
                {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 75}, {"color": "red", "value": 90}]}
            ),
            create_panel(
                "Disk Usage", "gauge", 
                {"x": 12, "y": 0, "w": 6, "h": 8},
                [{"expr": "node_disk_usage_percent", "refId": "A"}],
                "percent",
                {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 80}, {"color": "red", "value": 95}]}
            ),
            create_panel(
                "Active Processes", "stat", 
                {"x": 18, "y": 0, "w": 6, "h": 8},
                [{"expr": "node_processes_total", "refId": "A"}],
                "none"
            ),
            
            # --- Row 2: Time Series ---
            create_panel(
                "CPU Load Over Time", "timeseries", 
                {"x": 0, "y": 8, "w": 12, "h": 10},
                [{"expr": "node_cpu_usage_percent", "legendFormat": "CPU Load", "refId": "A"}],
                "percent"
            ),
            create_panel(
                "Memory Consumption Over Time", "timeseries", 
                {"x": 12, "y": 8, "w": 12, "h": 10},
                [
                    {"expr": "node_memory_used_bytes", "legendFormat": "Used", "refId": "A"},
                    {"expr": "node_memory_total_bytes", "legendFormat": "Total", "refId": "B"}
                ],
                "bytes"
            ),
            
            # --- Row 3: Disk & Details ---
            create_panel(
                "Disk Capacity", "timeseries", 
                {"x": 0, "y": 18, "w": 24, "h": 8},
                [
                    {"expr": "node_disk_used_bytes", "legendFormat": "Used Space", "refId": "A"},
                    {"expr": "node_disk_total_bytes", "legendFormat": "Total Capacity", "refId": "B"}
                ],
                "bytes"
            )
        ]
    },
    "overwrite": True
}

def setup_dashboard():
    print(f"📡 Connecting to Grafana at {GRAFANA_URL}...")
    try:
        response = requests.post(GRAFANA_URL, json=dashboard_payload, auth=GRAFANA_AUTH)
        if response.status_code == 200:
            result = response.json()
            url = f"http://localhost:3000{result['url']}"
            print("✅ Dashboard deployed successfully!")
            print(f"🔗 Access it here: {url}")
        else:
            print(f"❌ Failed to deploy dashboard (Status {response.status_code})")
            print(f"📝 Response: {response.text}")
    except requests.exceptions.ConnectionError:
        print("❌ Error: Could not connect to Grafana. Is it running on port 3000?")
    except Exception as e:
        print(f"💥 An unexpected error occurred: {e}")

if __name__ == '__main__':
    setup_dashboard()
