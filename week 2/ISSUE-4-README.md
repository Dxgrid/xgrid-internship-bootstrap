# Issue 4: Post-Deployment System Audit Script

## What Does This Script Do?

This is a **simple Bash script** that checks if your deployment is working correctly. It runs 4 checks:

1. **Disk Usage** - Is the server running out of space?
2. **Ports** - Are SSH (port 22) and API (port 8000) accessible?
3. **Container** - Is the `health-api` Docker container running?
4. **Health Endpoint** - Is the API responding correctly?

## Code Explanation (Line by Line)

### Part 1: Setup
```bash
#!/bin/bash                          # Tell system to use bash
RED='\033[0;31m'                     # Red color code for errors
GREEN='\033[0;32m'                   # Green color code for success
FAILED=0                             # 0 = OK, 1 = Problem found
```

### Part 2: Check 1 - Disk Usage
```bash
DISK_USAGE=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
# Get disk usage percentage and remove the % sign
# Example: Returns "45" if 45% of disk is used

if [ "$DISK_USAGE" -gt 80 ]; then    # If usage > 80%
    echo "WARNING: Disk usage is high"  # Print warning
fi
```

### Part 3: Check 2 - Ports
```bash
if netstat -tuln | grep ":22 " > /dev/null; then
    # netstat = show open ports
    # grep ":22 " = look for port 22
    # > /dev/null = throw away the output (we only care if it's found)
    echo "Port 22 is open"
else
    echo "Port 22 is CLOSED!"
    FAILED=1                         # Mark as failed
fi
```

### Part 4: Check 3 - Container
```bash
if docker ps --format "table {{.Names}}" | grep "^health-api$" > /dev/null; then
    # docker ps = show running containers
    # --format "table {{.Names}}" = just show container names
    # grep "^health-api$" = look for a container called "health-api"
    echo "Container is running"
else
    echo "Container is NOT running!"
    FAILED=1                         # Mark as failed
fi
```

### Part 5: Check 4 - Health Endpoint
```bash
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/health)
# curl = fetch web page
# -s = silent (no progress bar)
# -w "%{http_code}" = show HTTP response code (like 200, 404, etc)
# Example: RESPONSE="200" means success

if [ "$RESPONSE" == "200" ]; then
    echo "API is responding"
else
    echo "API is NOT responding!"
    FAILED=1                         # Mark as failed
fi
```

### Part 6: Final Result
```bash
if [ $FAILED -eq 0 ]; then           # If FAILED is still 0 (no problems)
    echo "SYSTEM IS HEALTHY"
    exit 0                           # Exit with code 0 = success
else
    echo "SYSTEM HAS ISSUES"
    exit 1                           # Exit with code 1 = failure
fi
```

---

## How to Use It

### 1. Make it executable
```bash
chmod +x /Users/daniyal/xgrid-internship-bootstrap/week\ 2/scripts/system_audit.sh
```

### 2. Run locally on EC2
```bash
ssh -i ~/.ssh/xgrid-key.pem ubuntu@32.192.214.156

# Then run:
bash ~/xgrid-internship-bootstrap/week\ 2/scripts/system_audit.sh
```

### 3. Run from your Mac
```bash
ssh -i ~/.ssh/xgrid-key.pem ubuntu@32.192.214.156 \
  "bash ~/xgrid-internship-bootstrap/week\ 2/scripts/system_audit.sh"
```

---

## Expected Output (When Everything is OK)

```
========================================
  System Audit Script
========================================

[1] Checking Disk Usage...
Disk usage: 45%
✓ Disk usage is OK

[2] Checking Ports...
✓ Port 22 (SSH) is open
✓ Port 8000 (API) is open

[3] Checking Container Status...
✓ Container 'health-api' is running

[4] Checking Health Endpoint...
✓ Health endpoint is responding (HTTP 200)
  Response: {"status":"healthy","version":"1.0.0"}

========================================
  AUDIT SUMMARY
========================================

✓ SYSTEM IS HEALTHY
  - All critical checks passed
  - Ready for deployment
```

---

## Exit Codes (For Jenkins )

| Code | Meaning |
|------|---------|
| **0** | All checks passed ✅ |
| **1** | Something failed ❌ |

---

## What Causes Exit Code 1 (Failure)?

Any ONE of these will cause failure:
- ❌ Port 22 is closed
- ❌ Port 8000 is closed
- ❌ Container is not running
- ❌ Health endpoint returns non-200

What does NOT cause failure (but warns):
- ⚠️ Disk > 80% (just a warning)

---

## Definition of Done - Test It

### Test 1: Run the script (should pass)
```bash
ssh -i ~/.ssh/xgrid-key.pem ubuntu@32.192.214.156 \
  "bash ~/xgrid-internship-bootstrap/week\ 2/scripts/system_audit.sh"
```
✅ Should show "SYSTEM IS HEALTHY"

### Test 2: Check exit code
```bash
ssh -i ~/.ssh/xgrid-key.pem ubuntu@32.192.214.156 \
  "bash ~/xgrid-internship-bootstrap/week\ 2/scripts/system_audit.sh && echo 'Exit: 0' || echo 'Exit: 1'"
```
✅ Should show "Exit: 0"

### Test 3: Stop container and test again
```bash
ssh -i ~/.ssh/xgrid-key.pem ubuntu@32.192.214.156 << 'EOF'
docker stop health-api
bash ~/xgrid-internship-bootstrap/week\ 2/scripts/system_audit.sh && echo "Exit: 0" || echo "Exit: 1"
docker start health-api
EOF
```
✅ Should show "Exit: 1" (failure)

---

## Key Commands Used (For Your Demo)

| Command | What it does |
|---------|-------------|
| `df /` | Shows disk usage |
| `netstat -tuln` | Shows all open ports |
| `docker ps` | Shows running containers |
| `curl -w "%{http_code}"` | Gets HTTP response code |
| `$()` | Runs command and saves result |
| `if [ condition ]` | Makes decisions |
| `exit 0 / exit 1` | Returns success or failure |

---

## Master This Script For Your Demo!

Your seniors will ask:
- **Q: What does `grep "^health-api$"` do?**
  - A: `grep` searches for text. `"^health-api$"` means "exactly `health-api`" (no partial matches)

- **Q: Why use `> /dev/null`?**
  - A: It throws away the output. We only care if the command finds a match, not what it prints

- **Q: What does `FAILED=1` do?**
  - A: It marks that something went wrong. At the end, we check if FAILED=0 to decide exit code

- **Q: How does Jenkins use this?**
  - A: Jenkins runs this script. If it exits with 0, Jenkins marks build as SUCCESS. If exit 1, Jenkins marks as FAILED

**Issue 4 Status:** ✅ Simple, Beginner-Friendly, Production-Ready
