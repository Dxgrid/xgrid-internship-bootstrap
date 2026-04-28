# Issue 1: Jenkins Controller Orchestration (Local Docker)

## Why This Matters (SRE Perspective)

Jenkins will be your **Command Center** for the entire Sprint. It orchestrates:
1. **Terraform** to provision AWS resources
2. **Docker** to build and deploy your application
3. **Audit scripts** to verify deployment health

If Jenkins loses its data (#FAIL), you lose all your job configurations, credentials, and history. **That's why persistence is critical.**

---

## Architecture Overview

```
┌─────────────────────┐
│   Your Local Machine │
│                      │
│  Jenkins Container   │
│  - Pipeline jobs     │
│  - Build history     │
│  - Credentials       │
│                      │
│  Docker Socket ──→ Docker Daemon on Host
└─────────────────────┘
```

**Key Design:**
- Jenkins runs in a container
- Jenkins uses your host's Docker daemon (via socket passthrough)
- Jenkins home directory is stored in a named volume (persists across restarts)

---

## Files Included

| File | Purpose |
|------|---------|
| `docker-compose.jenkins.yml` | Orchestrates the Jenkins container |
| `Dockerfile.jenkins` | Custom image with Docker CLI pre-installed |
| `plugins.txt` | List of required Jenkins plugins |
| `ISSUE-1-README.md` | This guide |

---

## Quick Start (3 Commands)

```bash
# 1. Go to week 2 directory
cd /Users/daniyal/xgrid-internship-bootstrap/week\ 2

# 2. Start Jenkins
docker-compose -f docker-compose.jenkins.yml up -d

# 3. Get the initial password
docker-compose -f docker-compose.jenkins.yml logs jenkins-controller | grep "initialAdminPassword"
```

---

## Step-by-Step Setup

### Step 1: Start Jenkins Container

```bash
cd /Users/daniyal/xgrid-internship-bootstrap/week\ 2

# Start Jenkins in background
docker-compose -f docker-compose.jenkins.yml up -d

# Verify it's running
docker-compose -f docker-compose.jenkins.yml ps

# Expected output:
# NAME                  STATUS
# jenkins-controller    Up X seconds
```

**What's happening:**
- Docker builds the custom image from `Dockerfile.jenkins`
- Container starts with persistent volume at `jenkins_home`
- Docker socket is passed through (Jenkins can run Docker commands)

### Step 2: Find the Initial Admin Password

Jenkins requires a one-time password to unlock it. Get it from the logs:

```bash
docker-compose -f docker-compose.jenkins.yml logs jenkins-controller | grep "initialAdminPassword"

# Output looks like:
# *************************************************************
# *                                                           *
# *  Jenkins initial setup is required. An admin user has    *
# *  been created and a password generated.                  *
# *  Please use the following password to proceed to         *
# *  installation:                                           *
# *                                                           *
# *  1a2b3c4d5e6f7g8h9i0j                                    *
# *                                                           *
# *************************************************************
```

**Copy that password** (the long alphanumeric string).

### Step 3: Unlock Jenkins and Install Plugins

1. Open your browser: http://localhost:8080

2. Paste the password you copied

3. Click "Continue"

4. Select **"Install suggested plugins"**
   - This installs: Pipeline, Git, Docker Pipeline, etc.
   - Takes ~2-3 minutes

5. Create your first admin user:
   - Username: `admin`
   - Password: (choose something secure)
   - Full name: Your name
   - Email: your@email.com

6. Click "Save and Continue"

7. Keep "Jenkins URL" as `http://localhost:8080`

8. Click "Start using Jenkins"

---

### Step 4: Verify Docker Access

Now verify that Jenkins can access Docker. This is **critical** for your pipeline to work.

#### Option A: Using Jenkins UI (Easiest)

1. Click **"New Item"** in the left menu
2. Name: `test-docker`
3. Select **"Pipeline"**
4. Click **OK**
5. In the **Pipeline** section, paste:
   ```groovy
   pipeline {
       agent any
       stages {
           stage('Test Docker') {
               steps {
                   sh 'docker version'
                   sh 'docker ps'
               }
           }
       }
   }
   ```
6. Click **"Build Now"**
7. Click on the build in **Build History** (left menu)
8. Click **"Console Output"**

**Expected output:**
```
Starting Docker build...
Client:
 Version: 24.0.0
 ...
Server:
 Version: 24.0.0
 ...

CONTAINER ID  IMAGE   ...
```

If you see this, Docker access is working! ✅

#### Option B: Using Jenkins Terminal (Quick Test)

```bash
# SSH into the Jenkins container
docker exec -it jenkins-controller bash

# Inside the container, test Docker
docker version
docker ps

# Exit
exit
```

---

## File Explanations

### `docker-compose.jenkins.yml`

```yaml
version: '3.8'

services:
  jenkins:
    build:
      context: .
      dockerfile: Dockerfile.jenkins    # Use custom image
    
    container_name: jenkins-controller
    
    ports:
      - "8080:8080"    # Web UI access
      - "50000:50000"  # Agent communication (for distributed builds)
    
    user: root         # Run as root to access Docker socket
    
    volumes:
      - jenkins_home:/var/jenkins_home  # PERSISTENCE! Jobs survive restarts
      - /var/run/docker.sock:/var/run/docker.sock  # Docker socket passthrough
      - /usr/bin/docker:/usr/bin/docker  # Docker CLI
    
    privileged: true   # Needed for Docker socket access
    restart: unless-stopped  # Auto-restart if container crashes

volumes:
  jenkins_home:        # Named volume (survives docker-compose down)
    driver: local
```

**Why each piece matters:**

| Setting | Why It's Important |
|---------|-------------------|
| `build: Dockerfile.jenkins` | Ensures Docker CLI is installed |
| `user: root` | Allows accessing Docker socket (non-root won't work) |
| `jenkins_home:/var/jenkins_home` | **PERSISTENCE** - Your jobs aren't deleted on restart |
| `/var/run/docker.sock` | **Docker Access** - Jenkins can run Docker commands |
| `restart: unless-stopped` | Container auto-starts if it crashes |

---

### `Dockerfile.jenkins`

```dockerfile
FROM jenkins/jenkins:lts

USER root

# Install Docker CLI (NOT the full Docker daemon)
RUN apt-get update && apt-get install -y \
    ...docker-ce-cli...

# Add jenkins user to docker group
RUN usermod -aG docker jenkins

USER jenkins
```

**Why:** Jenkins needs the `docker` command to build and run Docker images. We install the CLI only (not the daemon) because we're using the host's Docker via socket passthrough.

---

## Common Issues & Fixes

### Issue: "Permission Denied" when Jenkins tries to run Docker

**Cause:** Jenkins user doesn't have access to Docker socket

**Fix:** Already handled! The docker-compose.yml has:
```yaml
user: root
privileged: true
volumes:
  - /var/run/docker.sock:/var/run/docker.sock
```

### Issue: "Cannot connect to Docker daemon"

**Cause:** Docker daemon isn't running on your Mac

**Fix:**
```bash
# Make sure Docker Desktop is running, then
docker ps

# If it works, Jenkins should work too
```

### Issue: Jenkins is stuck or not responding

**Fix:**
```bash
# Restart Jenkins
docker-compose -f docker-compose.jenkins.yml restart jenkins-controller

# Or completely restart (data is safe in volume)
docker-compose -f docker-compose.jenkins.yml down
docker-compose -f docker-compose.jenkins.yml up -d
```

### Issue: "Lost all my Jenkins jobs!"

**This should NOT happen** because we use a named volume. But if it does:

```bash
# Check if volume exists
docker volume ls | grep jenkins

# If it's there, data is safe. Restart containers.
docker-compose -f docker-compose.jenkins.yml up -d
```

---

## Useful Commands

| Command | What It Does |
|---------|-------------|
| `docker-compose -f docker-compose.jenkins.yml up -d` | Start Jenkins |
| `docker-compose -f docker-compose.jenkins.yml down` | Stop Jenkins (data persists) |
| `docker-compose -f docker-compose.jenkins.yml logs -f` | View live logs |
| `docker-compose -f docker-compose.jenkins.yml ps` | Show container status |
| `docker exec -it jenkins-controller bash` | SSH into Jenkins |
| `docker volume ls` | List all volumes |
| `docker volume inspect jenkins_home` | See where data is stored |

---

## Definition of Done - Verification Checklist

### ✅ Jenkins accessible at localhost:8080
```bash
curl http://localhost:8080
# Should see Jenkins login page HTML
```

### ✅ Jenkins can run Docker commands
```bash
# Create test pipeline (see Step 4 above)
# Check console output shows "docker version" output
```

### ✅ Jenkins configuration persists after restart
```bash
# Stop Jenkins
docker-compose -f docker-compose.jenkins.yml down

# Start again
docker-compose -f docker-compose.jenkins.yml up -d

# Your test pipeline should still exist in the UI
# Visit http://localhost:8080
```

---

## What's Next?

Once this Issue is complete, you move to **Issue 5: Jenkins Pipeline**, which will:
1. Read your Terraform code (Issue #2)
2. Build your Docker image (Issue #3)
3. Deploy to AWS
4. Run your audit script (Issue #4)

All orchestrated from Jenkins!

---

**Issue 1 Status:** ✅ Production-Ready Jenkins Command Center
