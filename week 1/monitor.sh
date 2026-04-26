#!/bin/bash

LOG_FILE="monitor.log"
REFRESH_RATE=1

generate_trace_id() {
    LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | fold -w 8 | head -n 1
}

log_json() {
    local level=$1
    local msg=$2
    local cpu=$3
    local mem=$4
    local disk=$5
    local proc=$6
    local trace=$7
    local timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    
    printf '{"timestamp":"%s","level":"%s","service":"shell_monitor","message":"%s","metrics":{"cpu":%s,"memory_mb":%s,"disk_pct":%s,"processes":%s},"trace_id":"%s"}\n' \
        "$timestamp" "$level" "$msg" "$cpu" "$mem" "$disk" "$proc" "$trace"
}

echo "Starting System Monitor..."
echo "Logging to: $LOG_FILE"

while true; do
    clear
    trace_id=$(generate_trace_id)
    
    # Accurate macOS CPU calculation (100 - idle)
    CPU=$(top -l 2 | grep "CPU usage" | tail -n 1 | awk '{print $7}' | sed 's/%//' | awk '{print 100 - $1}')
    MEM=$(ps aux | awk '{sum += $6} END {printf "%.1f", sum/1024}')
    DISK=$(df -h / | tail -1 | awk '{print $5}' | sed 's/%//')
    PROC=$(ps aux | wc -l)
    
    echo "=== System Monitor [$(date '+%H:%M:%S')] ==="
    echo "Trace-ID:  $trace_id"
    echo "CPU:       ${CPU}%"
    echo "Memory:    ${MEM}MB"
    echo "Disk:      ${DISK}%"
    echo "Processes: $PROC"
    echo "======================================"
    
    log_json "INFO" "Metrics collected" "$CPU" "$MEM" "$DISK" "$PROC" "$trace_id" >> "$LOG_FILE"
    
    sleep $REFRESH_RATE
done
