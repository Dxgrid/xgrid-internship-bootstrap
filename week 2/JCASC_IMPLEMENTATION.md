# Jenkins JCasC Credentials Fix — Complete Implementation Guide

## Problem Diagnosis

Your Jenkins instance is using a **Docker managed volume**, but credentials added via the UI were **not being persisted** to `credentials.xml`. This occurs because:

1. **UI credentials are stored in `$JENKINS_HOME/credentials.xml`** — a file that only gets written when you explicitly save credentials in the Jenkins UI
2. **Docker volume permissions or encryption key issues** can prevent this file from being created
3. **The Jenkins container runs as root**, which can interfere with the Jenkins user's file ownership expectations
4. **Without valid encryption keys**, the credentials become inaccessible even if the file is created

**Why other data (plugins, jobs, configs) persisted but credentials didn't:**
- Plugins are copied from the Docker image to the volume at startup (initial setup)
- Job configs are written by triggered pipeline runs (active writes)
- Credentials.xml is ONLY written during UI save (manual write) — this is where the permission/persistence wall hit

## Solution: Jenkins Configuration as Code (JCasC)

JCasC is the **production-recommended** approach for containerized Jenkins. It:

✅ **Provisions credentials from environment variables at startup** — no UI needed  
✅ **Survives container rebuilds and restarts** — credentials are defined in code, not stored in fragile XML files  
✅ **Never exposes secrets in the Dockerfile or docker-compose** — secrets come from host environment only  
✅ **Works reliably in Docker** — bypasses all the permission/permission issues because Jenkins applies the config before writing any files  

---

## Implementation Steps

### 1. Review the Changes Made

We've updated three files:

**`week 2/plugins.txt`** — Added JCasC plugins:
```
configuration-as-code
configuration-as-code-groovy
```

**`week 2/jenkins.yaml`** — JCasC configuration that defines credentials as environment variable references (never hardcoded):
```yaml
credentials:
  system:
    domainCredentials:
      - credentials:
          - string:
              scope: GLOBAL
              id: "aws-access-key-id"
              secret: "${AWS_ACCESS_KEY_ID}"  # <-- sourced from container env var
```

**`week 2/docker-compose.jenkins.yml`** — Updated to:
```yaml
environment:
  - CASC_JENKINS_CONFIG=/var/jenkins_home/jenkins.yaml
  - AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}          # from host shell
  - AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}  # from host shell
  - EC2_SSH_PRIVATE_KEY=${EC2_SSH_PRIVATE_KEY}      # from host shell

volumes:
  - ./jenkins.yaml:/var/jenkins_home/jenkins.yaml:ro  # mount config file
```

### 2. Prepare Your Credentials

You'll need three things from your AWS/local setup:

**a) AWS Access Key ID**
- Get from: AWS Console → IAM → Users → Your User → Security Credentials → Access Keys
- Format: `AKIA...` (20 characters starting with AKIA)
- Example: `AKIAIOSFODNN7EXAMPLE`

**b) AWS Secret Access Key**
- Get from: Same location as above (only shown when key is created)
- Format: 40-character string
- Example: `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY`

**c) EC2 SSH Private Key (PEM file)**
- Get from: The `.pem` file you downloaded when creating the EC2 key pair
- Location: Usually `~/.ssh/your-key.pem`
- You'll paste the ENTIRE contents (including `-----BEGIN RSA PRIVATE KEY-----` and `-----END RSA PRIVATE KEY-----`)

### 3. Export Credentials & Start Jenkins

**Quick Option: Use the provided setup script**

```bash
cd /Users/daniyal/xgrid-internship-bootstrap/week\ 2

# This script will prompt you for each credential and restart Jenkins
./setup-jcasc.sh
```

The script will:
- Ask for AWS Access Key ID
- Ask for AWS Secret Access Key
- Ask for path to EC2 SSH private key
- Rebuild Jenkins with JCasC plugins
- Restart the container
- Verify credentials are loaded

**Manual Option: Do it yourself**

```bash
# 1. Get your credentials ready (see Step 2 above)

# 2. Export them to your shell (don't commit these!)
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="wJalr..."
export EC2_SSH_PRIVATE_KEY="$(cat ~/.ssh/your-ec2-key.pem)"

# 3. Stop and remove old containers
docker-compose -f docker-compose.jenkins.yml down

# 4. Rebuild Jenkins with new plugins
docker-compose -f docker-compose.jenkins.yml build --no-cache

# 5. Start Jenkins with credentials in environment
docker-compose -f docker-compose.jenkins.yml up -d
```

### 4. Verify Credentials Are Loaded

```bash
# Check Jenkins logs for JCasC initialization
docker exec jenkins-controller tail -50 /var/jenkins_home/logs/jenkins.log | grep -i "casc\|credentials"

# Expected output: Lines confirming JCasC loaded jenkins.yaml and provisioned credentials
```

Then check the Jenkins UI:
1. Open http://localhost:8080
2. Go to **Manage Jenkins** → **Credentials** → **System** → **Global credentials**
3. You should see three credentials:
   - ✅ `aws-access-key-id` (String type)
   - ✅ `aws-secret-access-key` (String type)
   - ✅ `ec2-ssh-key` (SSH key type)

If you see all three, **JCasC has successfully provisioned the credentials**.

### 5. Test the Pipeline

Now try running the pipeline:

```bash
# In Jenkins UI:
# 1. Go to feature/issue-5-jenkins-pipeline job
# 2. Click "Build Now"
```

The pipeline should now:
- ✅ Pass the Terraform Provision stage (withCredentials block finds the credentials)
- ✅ Run Terraform init
- ✅ Run Terraform apply
- ✅ Continue to Deploy stage and beyond

---

## Troubleshooting

### Credentials Still Not Showing in Jenkins UI

**Check 1: Is JCasC plugin installed?**
```bash
docker exec jenkins-controller ls /var/jenkins_home/plugins/configuration-as-code*
# Should show: configuration-as-code.jpi and configuration-as-code-groovy.jpi
```

**Check 2: Is the jenkins.yaml file mounted correctly?**
```bash
docker exec jenkins-controller cat /var/jenkins_home/jenkins.yaml | head -20
# Should show the credentials definitions
```

**Check 3: Are environment variables being passed to the container?**
```bash
docker exec jenkins-controller env | grep AWS_ACCESS_KEY_ID
# Should show: AWS_ACCESS_KEY_ID=AKIA...
```

**Check 4: Full JCasC debug logs**
```bash
docker exec jenkins-controller tail -100 /var/jenkins_home/logs/jenkins.log | grep -A 5 -B 5 "casc"
```

### Pipeline Still Fails with Credentials Error

This means JCasC applied the config, but the pipeline can't find the credentials at runtime. Possible causes:

1. **Credentials ID mismatch** — The ID in withCredentials doesn't match the ID in jenkins.yaml
   - In `Jenkinsfile`: `credentialsId: 'aws-access-key-id'`
   - In `jenkins.yaml`: `id: "aws-access-key-id"`
   - These MUST match exactly (case-sensitive)

2. **Credentials are Global scope but pipeline scoped differently**
   - Our jenkins.yaml uses `scope: GLOBAL` — this is correct for Multibranch Pipeline jobs
   - If changing, ensure the scope in jenkins.yaml matches what you're trying to access

3. **Restart Jenkins to force JCasC reload**
   ```bash
   docker-compose -f docker-compose.jenkins.yml restart
   ```

### Jenkins Won't Start After JCasC Changes

Check the logs:
```bash
docker logs jenkins-controller 2>&1 | tail -50
```

**Common errors:**
- `YAML syntax error` — incorrect indentation in jenkins.yaml (YAML is whitespace-sensitive)
- `Plugin not found` — configuration-as-code plugin didn't install (wait longer or rebuild with `--no-cache`)
- `Environment variable not set` — AWS_ACCESS_KEY_ID not exported before starting (the `${AWS_ACCESS_KEY_ID}` won't expand)

---

## What Changed & Why

| Component | Before | After | Why |
|-----------|--------|-------|-----|
| Credentials storage | Jenkins UI → `credentials.xml` (fails) | Environment vars → JCasC | No file write permission issues |
| Credential persistence | Docker volume (unreliable) | JCasC yaml + env vars (reliable) | JCasC applies on every startup, guaranteed to work |
| Secret security | Hardcoded in XML (risky if volume backed up) | Sourced from env at runtime | Secrets never stored on disk, only in memory |
| Scalability | Manual UI per instance | Code-defined one time | Deploy 10 Jenkins instances, all identical |

---

## Next Steps

✅ **Immediate:** Run `setup-jcasc.sh` and verify credentials appear in Jenkins UI  
✅ **Then:** Run the `feature/issue-5-jenkins-pipeline` pipeline — it should succeed through Terraform Provision stage  
✅ **Finally:** Once pipeline passes, you've successfully completed Week 2 Issue #5  

---

## Reference: JCasC Documentation

- Jenkins Configuration as Code: https://plugins.jenkins.io/configuration-as-code/
- Using environment variables in JCasC: https://plugins.jenkins.io/configuration-as-code/#Configuration%20as%20Code%20with%20Jenkins%20Configuration%20as%20Code%20Plugin
- Groovy support in JCasC: https://plugins.jenkins.io/configuration-as-code-groovy/

---

## Rollback (if needed)

If JCasC breaks your Jenkins, you can revert:

```bash
# Stop Jenkins
docker-compose -f docker-compose.jenkins.yml down

# Remove JCasC from plugins.txt (remove the two configuration-as-code lines)
# Remove or comment out CASC_JENKINS_CONFIG from docker-compose
# Remove ./jenkins.yaml volume mount

# Restart without JCasC
docker-compose -f docker-compose.jenkins.yml up -d
```
