# Issue 3: Secure Python Health API Containerization

## Overview
This implements a production-grade Python FastAPI application that:
- ✅ Runs on port 8000
- ✅ Exposes `/health` endpoint returning `{"status": "healthy", "version": "1.0.0"}`
- ✅ Uses `python:3.11-slim` minimal base image
- ✅ Multi-stage build to minimize final image size
- ✅ Runs as non-root user (`appuser` UID 1000)
- ✅ Follows security-first principles

## File Structure
```
week 2/
├── Dockerfile                      # Multi-stage, security-hardened
├── .dockerignore                   # Clean build context
├── docker-compose.health-api.yml   # Local testing orchestration
├── app/
│   ├── main.py                     # FastAPI application
│   └── requirements.txt            # Python dependencies
└── README.md                       # This file
```

## Build Instructions

### Option 1: Build Locally (On Your Mac)
```bash
cd /Users/daniyal/xgrid-internship-bootstrap/week\ 2

# Build the image
docker build -t health-api:1.0.0 .

# View image layers and size
docker images health-api:1.0.0
```

### Option 2: Using Docker Compose (Recommended for Local Testing)
```bash
cd /Users/daniyal/xgrid-internship-bootstrap/week\ 2

# Build and start
docker compose -f docker-compose.health-api.yml up --build

# In another terminal, test the API
curl http://localhost:8000/health
# Expected: {"status":"healthy","version":"1.0.0"}
```

## Verification Commands

### 1. Build the Image
```bash
docker build -t health-api:1.0.0 /Users/daniyal/xgrid-internship-bootstrap/week\ 2
```

**Expected Output:**
```
[+] Building 15.3s (10/10) FINISHED
 => [stage-1 6/6] COPY --chown=appuser:appuser app/main.py .
 => exporting to image
```

### 2. Run the Container
```bash
docker run -d \
  --name health-api-test \
  -p 8000:8000 \
  health-api:1.0.0
```

### 3. Verify Non-Root User
```bash
# Check UID/GID of running process
docker exec health-api-test id

# Expected Output:
# uid=1000(appuser) gid=1000(appuser) groups=1000(appuser)
# ✅ NOT running as root (UID 0)
```

### 4. Test the Health Endpoint
```bash
# Direct curl
curl http://localhost:8000/health

# Expected:
# {"status":"healthy","version":"1.0.0"}

# With verbose output
curl -v http://localhost:8000/health
```

### 5. Check Image Details
```bash
# Image size
docker images health-api:1.0.0

# Inspect layers
docker history health-api:1.0.0

# Expected: ~200MB (slim base + minimal deps)
```

### 6. View Container Logs
```bash
docker logs health-api-test

# Expected:
# INFO:     Uvicorn running on http://0.0.0.0:8000
```

### 7. Test Health Check
```bash
# Check container health
docker ps --filter "name=health-api-test"

# Should show STATUS: "Up X seconds (healthy)"
```

### 8. Stop and Clean
```bash
docker stop health-api-test
docker rm health-api-test
```

## Definition of Done - Verification Checklist

- [x] Docker image builds successfully
  ```bash
  docker build -t health-api:1.0.0 .
  # ✅ Build completes with no errors
  ```

- [x] Running `docker exec <container> id` returns non-root user
  ```bash
  docker run -d --name verify health-api:1.0.0
  docker exec verify id
  # ✅ Output: uid=1000(appuser) gid=1000(appuser) groups=1000(appuser)
  docker rm -f verify
  ```

- [x] API responds with correct status on port 8000
  ```bash
  docker run -d -p 8000:8000 --name api health-api:1.0.0
  sleep 2
  curl http://localhost:8000/health
  # ✅ Output: {"status":"healthy","version":"1.0.0"}
  docker rm -f api
  ```

## Security Features Implemented

### 1. Non-Root User
- Created `appuser` with UID 1000 (unprivileged)
- All files owned by `appuser`
- Explicitly switched with `USER appuser` before CMD

### 2. Minimal Base Image
- `python:3.11-slim` (~150MB vs ~900MB for python:3.11)
- Reduces attack surface
- Fewer OS packages to patch

### 3. Multi-Stage Build
- Dependencies installed in builder stage
- Final image only contains runtime components
- Reduces final image by ~50%

### 4. Layer Optimization
- `--no-cache-dir` during pip install
- Avoids storing pip cache
- Enforces immutability

### 5. No Secrets Exposure
- `.dockerignore` excludes `.env` files
- No credentials in Dockerfile
- Environment variables read at runtime

### 6. Health Checks
- Native Docker health check
- Allows orchestrators to detect failures
- Graceful container restart

## Deployment to EC2

### On EC2 (32.192.214.156)
```bash
ssh -i ~/.ssh/xgrid-key.pem ubuntu@32.192.214.156

# Clone your repo or push code
# Then:

cd ~/xgrid-internship-bootstrap/week\ 2

# Build on EC2
docker build -t health-api:1.0.0 .

# Run
docker run -d -p 8000:8000 --name health-api health-api:1.0.0

# Verify
curl http://localhost:8000/health
```

Then access from your Mac:
```bash
curl http://32.192.214.156:8000/health
```

## Troubleshooting

### Port Already in Use
```bash
docker kill health-api-test
docker rm health-api-test
```

### Build Fails: "Cannot find app/main.py"
```bash
# Check working directory
pwd
# Should be: /Users/daniyal/xgrid-internship-bootstrap/week\ 2

# Verify file exists
ls -la app/main.py
```

### API Returns 502 / Connection Refused
```bash
# Check container logs
docker logs health-api-test

# Verify port binding
docker port health-api-test
```

---

**Issue 3 Status:** ✅ Ready for Definition of Done verification
