#!/bin/bash

# Setup script to help understand the monitoring system

echo "=== Monitoring System Setup ==="
echo ""

# Make scripts executable
chmod +x monitor.sh

echo "✅ Scripts made executable"
echo ""

echo "📊 To see the three monitoring approaches in action:"
echo ""

echo "1️⃣  LOGS APPROACH (store events):"
echo "   ./monitor.sh"
echo "   Outputs to: system_metrics.log (CSV format)"
echo ""

echo "2️⃣  METRICS APPROACH (expose metrics):"
echo "   python3 prometheus_exporter.py"
echo "   Then curl: http://localhost:8000/metrics"
echo ""

echo "3️⃣  Learn the concepts:"
echo "   cat MONITORING_GUIDE.md"
echo ""

echo "💡 Try running both simultaneously in different terminals!"
