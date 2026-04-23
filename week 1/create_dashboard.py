#!/usr/bin/env python3
"""
Simple System Monitoring Dashboard for Grafana.
Creates a clean, easy-to-understand dashboard with real data visualization.
"""

import requests
import json
import time

# Grafana Configuration
GRAFANA_URL = 'http://localhost:3000'
GRAFANA_AUTH = ('admin', 'admin')

def setup_datasource():
    """Create Prometheus datasource in Grafana."""
    print("📊 Setting up Prometheus datasource...")
    
    datasource_payload = {
        "name": "Prometheus",
        "type": "prometheus",
        "url": "http://localhost:9090",
        "access": "proxy",
        "isDefault": True,
        "jsonData": {}
    }
    
    try:
        response = requests.post(
            f"{GRAFANA_URL}/api/datasources",
            json=datasource_payload,
            auth=GRAFANA_AUTH
        )
        if response.status_code in [200, 409]:  # 409 = already exists
            print("✅ Prometheus datasource ready")
            return True
        else:
            print(f"⚠️  Could not set datasource: {response.text}")
            return False
    except Exception as e:
        print(f"❌ Error setting datasource: {e}")
        return False

def create_simple_dashboard():
    """Create a simple, clean dashboard."""
    print("🎨 Creating dashboard...")
    
    dashboard = {
        "dashboard": {
            "title": "System Monitor",
            "tags": ["monitoring"],
            "timezone": "browser",
            "schemaVersion": 35,
            "version": 0,
            "refresh": "5s",
            "time": {"from": "now-6h", "to": "now"},
            "panels": [
                # CPU Gauge
                {
                    "id": 1,
                    "title": "CPU Usage %",
                    "type": "gauge",
                    "gridPos": {"x": 0, "y": 0, "w": 6, "h": 8},
                    "targets": [{"expr": "node_cpu_usage_percent", "refId": "A"}],
                    "options": {
                        "orientation": "auto",
                        "textMode": "auto",
                        "colorMode": "background",
                        "graphMode": "none",
                        "justifyMode": "auto",
                        "thresholds": {
                            "mode": "absolute",
                            "steps": [
                                {"color": "green", "value": None},
                                {"color": "yellow", "value": 60},
                                {"color": "red", "value": 80}
                            ]
                        }
                    },
                    "fieldConfig": {
                        "defaults": {"min": 0, "max": 100, "unit": "percent"},
                        "overrides": []
                    }
                },
                # Memory Gauge
                {
                    "id": 2,
                    "title": "Memory Usage %",
                    "type": "gauge",
                    "gridPos": {"x": 6, "y": 0, "w": 6, "h": 8},
                    "targets": [{"expr": "(node_memory_used_bytes / node_memory_total_bytes) * 100", "refId": "A"}],
                    "options": {
                        "orientation": "auto",
                        "textMode": "auto",
                        "colorMode": "background",
                        "graphMode": "none",
                        "justifyMode": "auto",
                        "thresholds": {
                            "mode": "absolute",
                            "steps": [
                                {"color": "green", "value": None},
                                {"color": "yellow", "value": 70},
                                {"color": "red", "value": 85}
                            ]
                        }
                    },
                    "fieldConfig": {
                        "defaults": {"min": 0, "max": 100, "unit": "percent"},
                        "overrides": []
                    }
                },
                # Disk Gauge
                {
                    "id": 3,
                    "title": "Disk Usage %",
                    "type": "gauge",
                    "gridPos": {"x": 12, "y": 0, "w": 6, "h": 8},
                    "targets": [{"expr": "node_disk_usage_percent", "refId": "A"}],
                    "options": {
                        "orientation": "auto",
                        "textMode": "auto",
                        "colorMode": "background",
                        "graphMode": "none",
                        "justifyMode": "auto",
                        "thresholds": {
                            "mode": "absolute",
                            "steps": [
                                {"color": "green", "value": None},
                                {"color": "yellow", "value": 75},
                                {"color": "red", "value": 90}
                            ]
                        }
                    },
                    "fieldConfig": {
                        "defaults": {"min": 0, "max": 100, "unit": "percent"},
                        "overrides": []
                    }
                },
                # Processes
                {
                    "id": 4,
                    "title": "Active Processes",
                    "type": "stat",
                    "gridPos": {"x": 18, "y": 0, "w": 6, "h": 8},
                    "targets": [{"expr": "node_processes_total", "refId": "A"}],
                    "options": {
                        "colorMode": "background",
                        "graphMode": "none",
                        "justifyMode": "auto",
                        "textMode": "auto"
                    },
                    "fieldConfig": {
                        "defaults": {"unit": "short"},
                        "overrides": []
                    }
                },
                # CPU Time Series
                {
                    "id": 5,
                    "title": "CPU Load Over Time",
                    "type": "timeseries",
                    "gridPos": {"x": 0, "y": 8, "w": 12, "h": 8},
                    "targets": [{"expr": "node_cpu_usage_percent", "legendFormat": "CPU %", "refId": "A"}],
                    "options": {
                        "legend": {"displayMode": "list", "placement": "bottom"},
                        "tooltip": {"mode": "multi"}
                    },
                    "fieldConfig": {
                        "defaults": {"unit": "percent", "min": 0, "max": 100},
                        "overrides": []
                    }
                },
                # Memory Time Series
                {
                    "id": 6,
                    "title": "Memory Over Time",
                    "type": "timeseries",
                    "gridPos": {"x": 12, "y": 8, "w": 12, "h": 8},
                    "targets": [{"expr": "node_memory_used_bytes / 1024 / 1024 / 1024", "legendFormat": "Used (GB)", "refId": "A"}],
                    "options": {
                        "legend": {"displayMode": "list", "placement": "bottom"},
                        "tooltip": {"mode": "multi"}
                    },
                    "fieldConfig": {
                        "defaults": {"unit": "GB"},
                        "overrides": []
                    }
                }
            ]
        },
        "overwrite": True
    }
    
    try:
        response = requests.post(
            f"{GRAFANA_URL}/api/dashboards/db",
            json=dashboard,
            auth=GRAFANA_AUTH
        )
        if response.status_code == 200:
            result = response.json()
            print(f"✅ Dashboard created successfully!")
            print(f"📺 Open: http://localhost:3000/d/system-monitor")
            return True
        else:
            print(f"❌ Failed: {response.status_code}")
            print(f"Response: {response.text}")
            return False
    except Exception as e:
        print(f"❌ Error creating dashboard: {e}")
        return False

def check_prometheus():
    """Check if Prometheus is running."""
    print("🔍 Checking Prometheus...")
    try:
        response = requests.get("http://localhost:9090/api/v1/query?query=up", timeout=5)
        if response.status_code == 200:
            print("✅ Prometheus is running")
            return True
        else:
            print("⚠️  Prometheus not responding properly")
            return False
    except:
        print("❌ Prometheus not accessible. Make sure it's running on port 9090")
        return False

def check_grafana():
    """Check if Grafana is running."""
    print("🔍 Checking Grafana...")
    try:
        response = requests.get(f"{GRAFANA_URL}/api/health", timeout=5, auth=GRAFANA_AUTH)
        if response.status_code == 200:
            print("✅ Grafana is running")
            return True
        else:
            print("⚠️  Grafana not responding properly")
            return False
    except:
        print("❌ Grafana not accessible. Make sure it's running on port 3000")
        return False

def main():
    print("=" * 50)
    print("  System Monitor Dashboard Setup")
    print("=" * 50)
    
    # Check services
    if not check_grafana() or not check_prometheus():
        print("\n⏳ Waiting 10 seconds before retrying...")
        time.sleep(10)
        if not check_grafana() or not check_prometheus():
            print("\n❌ Services not running. Please start docker first:")
            print("   cd week\\ 1 && docker compose up -d")
            return
    
    # Setup datasource
    if not setup_datasource():
        return
    
    # Create dashboard
    if create_simple_dashboard():
        print("\n" + "=" * 50)
        print("✨ Dashboard ready!")
        print("=" * 50)
        print("\n🚀 Next steps:")
        print("1. Open: http://localhost:3000")
        print("2. Login with: admin / admin")
        print("3. Go to Dashboards > System Monitor")
        print("\n📝 Make sure you're running:")
        print("   - docker compose up -d")
        print("   - python3 prometheus_exporter.py")
        print("   - ./monitor.sh")

if __name__ == '__main__':
    main()

