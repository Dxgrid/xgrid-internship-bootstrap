#!/bin/bash

# ============================================
# System Audit Script - Issue #4
# Purpose: Check if EC2 deployment is healthy
# Version: 1.0.0
# ============================================

# Colors for output
RED='\033[0;31m'        # Red for errors
GREEN='\033[0;32m'      # Green for success
YELLOW='\033[0;33m'     # Yellow for warnings
BLUE='\033[0;34m'       # Blue for info
NC='\033[0m'            # No color

# Status variables
FAILED=0                # 0 = all good, 1 = something failed

echo "========================================"
echo "  System Audit Script"
echo "========================================"
echo ""

# ============================================
# CHECK 1: Disk Usage
# ============================================
echo -e "${BLUE}[1] Checking Disk Usage...${NC}"

# Get disk usage percentage from root filesystem
DISK_USAGE=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')

echo "Disk usage: ${DISK_USAGE}%"

if [ "$DISK_USAGE" -gt 80 ]; then
    echo -e "${YELLOW}⚠ WARNING: Disk usage is high${NC}"
else
    echo -e "${GREEN}✓ Disk usage is OK${NC}"
fi

echo ""

# ============================================
# CHECK 2: Required Ports (22 and 8000)
# ============================================
echo -e "${BLUE}[2] Checking Ports...${NC}"

# Check if port 22 is open (SSH)
if netstat -tuln 2>/dev/null | grep ":22 " > /dev/null; then
    echo -e "${GREEN}✓ Port 22 (SSH) is open${NC}"
else
    echo -e "${RED}✗ Port 22 (SSH) is NOT open${NC}"
    FAILED=1
fi

# Check if port 8000 is open (API)
if netstat -tuln 2>/dev/null | grep ":8000 " > /dev/null; then
    echo -e "${GREEN}✓ Port 8000 (API) is open${NC}"
else
    echo -e "${RED}✗ Port 8000 (API) is NOT open${NC}"
    FAILED=1
fi

echo ""

# ============================================
# CHECK 3: Container Status
# ============================================
echo -e "${BLUE}[3] Checking Container Status...${NC}"

# Check if container "health-api" is running
if docker ps --format "table {{.Names}}" | grep "^health-api$" > /dev/null; then
    echo -e "${GREEN}✓ Container 'health-api' is running${NC}"
else
    echo -e "${RED}✗ Container 'health-api' is NOT running${NC}"
    FAILED=1
fi

echo ""

# ============================================
# CHECK 4: Health Endpoint
# ============================================
echo -e "${BLUE}[4] Checking Health Endpoint...${NC}"

# Test the /health endpoint
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/health 2>/dev/null)

if [ "$RESPONSE" == "200" ]; then
    echo -e "${GREEN}✓ Health endpoint is responding (HTTP ${RESPONSE})${NC}"
    
    # Show the actual response
    API_RESPONSE=$(curl -s http://localhost:8000/health 2>/dev/null)
    echo "  Response: ${API_RESPONSE}"
else
    echo -e "${RED}✗ Health endpoint is NOT responding (HTTP ${RESPONSE})${NC}"
    FAILED=1
fi

echo ""

# ============================================
# FINAL SUMMARY
# ============================================
echo "========================================"
echo "  AUDIT SUMMARY"
echo "========================================"

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ SYSTEM IS HEALTHY${NC}"
    echo "  - All critical checks passed"
    echo "  - Ready for deployment"
    exit 0
else
    echo -e "${RED}✗ SYSTEM HAS ISSUES${NC}"
    echo "  - Some critical checks failed"
    echo "  - Fix problems and try again"
    exit 1
fi
