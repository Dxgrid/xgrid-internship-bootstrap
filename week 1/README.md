# System Monitoring Stack (macOS Native + Docker)

This repository contains a professional-grade observability stack that combines industry-standard infrastructure monitoring with a custom Python-based metrics exporter and structured JSON logging.

---

## 🚀 The "Start From Zero" Guide

Follow these steps in order to launch the full environment on macOS.

### 1. Clean Up & Prerequisites
Ensure no old processes are running and all dependencies are installed:
```bash
# 1. Kill any existing processes
docker compose down --remove-orphans
pkill node_exporter
pkill -f prometheus_exporter.py
pkill -f monitor.sh
pkill -f create_dashboard.py

# 2. Install dependencies
pip3 install psutil prometheus_client requests
brew install node_exporter
```

### 2. Launch the Stack (Open 4 Terminal Tabs)

| Tab | Command | Purpose |
|-----|---------|---------|
| **Tab 1** | `node_exporter` | Native Mac infrastructure metrics (:9100) |
| **Tab 2** | `python3 prometheus_exporter.py` | Custom Python metrics exporter (:8000) |
| **Tab 3** | `docker compose up -d` | Launch Prometheus (:9090) & Grafana (:3000) |
| **Tab 4** | `bash monitor.sh` | **Real-time Terminal Monitor** with JSON logging |

### 3. Automatic Dashboard Setup
Once the Docker containers are healthy (wait ~10 seconds), run this script to automatically build your Grafana dashboard:
```bash
python3 create_dashboard.py
```
*Wait for the message: `✅ Dashboard created successfully!`*

---

## 📊 Where to View Results

### 1. The Web Dashboard (Professional View)
Open [http://localhost:3000/d/system-monitor](http://localhost:3000/d/system-monitor)
*   **Username:** `admin` | **Password:** `admin`
*   This shows real-time graphs for CPU, Memory, Disk, and Processes.

### 2. The Terminal Monitor (Live View)
Look at **Tab 4**. It displays a clean, human-readable summary of your Mac's health updated every second.

### 3. The Log Files (Audit View)
Every second, your system generates professional JSON logs with unique Trace IDs. To view them in a searchable format:
```bash
tail -f monitor.log | python3 -m json.tool
```

---

## 📂 Project Architecture

| File | Role |
|------|------|
| `prometheus_exporter.py` | Python script that converts OS stats into Prometheus format. |
| `monitor.sh` | Bash script for terminal visibility and local JSON logging. |
| `create_dashboard.py` | Automated script to build Grafana dashboards via API. |
| `EXPORTER_COMPARISON.md` | Analysis of Load vs CPU and Active vs Used Memory. |
| `MONITORING_JOURNEY.md` | Technical documentation of the project's evolution. |

---

## 🛑 Stop Everything
When you are finished, run this single command to clean up all resources:
```bash
docker compose down && pkill node_exporter && pkill -f prometheus_exporter.py && pkill -f monitor.sh
```
