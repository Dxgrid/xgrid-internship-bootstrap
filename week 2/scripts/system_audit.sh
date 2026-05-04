#!/bin/bash

STATUS=0

echo "--- STARTING SYSTEM AUDIT ---"

# 1. Disk Check (Threshold 90%)
USAGE=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
if [ "$USAGE" -gt 90 ]; then
    echo "DISK ALERT: Usage is at ${USAGE}%"
    STATUS=1
else
    echo "Disk OK: ${USAGE}% used"
fi

# 2. Port Checks (22 and 8000)
for port in 22 8000; do
    if netstat -tuln | grep -q ":$port "; then
        echo "Port $port: OPEN"
    else
        echo "Port $port: CLOSED"
        STATUS=1
    fi
done

# 3. Docker Container Check
if docker ps --format '{{.Names}}' | grep -q "health-api"; then
    echo "Container health-api: RUNNING"
else
    echo "Container health-api: NOT FOUND"
    STATUS=1
fi

# 4. API Health Endpoint Check
CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/health)
if [ "$CODE" == "200" ]; then
    echo "API Endpoint: SUCCESS (HTTP 200)"
else
    echo "API Endpoint: FAILED (HTTP $CODE)"
    STATUS=1
fi

# FINAL RESULT
if [ $STATUS -eq 0 ]; then
    echo "--- AUDIT PASSED ---"
    exit 0
else
    echo "--- AUDIT FAILED ---"
    exit 1
fi
