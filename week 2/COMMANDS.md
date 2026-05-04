# Week 2 Project: Complete Command Reference

This document contains **all commands needed** to set up, run, and manage the Week 2 CI/CD pipeline and infrastructure.

---

## Table of Contents

1. [Prerequisites & Prerequisites](#prerequisites--prerequisites)
2. [Initial Setup](#initial-setup)
3. [AWS Configuration](#aws-configuration)
4. [Terraform State Backend Setup](#terraform-state-backend-setup)
5. [Jenkins Docker Container Setup](#jenkins-docker-container-setup)
6. [Generate and Manage EC2 SSH Keys](#generate-and-manage-ec2-ssh-keys)
7. [Running the Pipeline](#running-the-pipeline)
8. [Monitoring & Troubleshooting](#monitoring--troubleshooting)
9. [Cleanup & Teardown](#cleanup--teardown)

---

## Prerequisites & Prerequisites

### System Requirements

```bash
# Check macOS version (require 10.15+)
sw_vers

# Check if Homebrew is installed
brew --version

# Check if Docker is installed
docker --version

# Check if AWS CLI is installed
aws --version

# Check if Terraform is installed
terraform --version

# Check if Git is installed
git --version
```

### If Any Tools Are Missing, Install Them

```bash
# Install Homebrew (if needed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install Docker (via Homebrew or Docker Desktop)
brew install docker
# OR download Docker Desktop: https://www.docker.com/products/docker-desktop

# Install AWS CLI v2
brew install awscliv2

# Install Terraform
brew install terraform

# Install Git
brew install git
```

---

## Initial Setup

### 1. Clone or Navigate to Repository

```bash
# If you don't have the repo yet
git clone https://github.com/Dxgrid/xgrid-internship-bootstrap.git
cd xgrid-internship-bootstrap

# Navigate to week 2 directory
cd "week 2"
```

### 2. Create or Verify `.env` File

```bash
# Copy the example file
cp .env.example .env

# Edit the .env file with your actual credentials
# Use your preferred editor (nano, vim, VS Code)
nano .env
# OR
code .env
```

### 3. Populate `.env` with Your Credentials

```bash
# In the .env file, populate these values:

# AWS Credentials (from AWS IAM console)
AWS_ACCESS_KEY_ID=AKIXXXXXXXXX...
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

# EC2 SSH Private Key (from ~/.ssh/xgrid-key.pem)
# Paste the ENTIRE private key content
EC2_SSH_PRIVATE_KEY=-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA...
... (full private key)
-----END RSA PRIVATE KEY-----
```

**⚠️ Important**: Never commit `.env` to Git — it contains secrets!

```bash
# Verify .env is in .gitignore
cat .gitignore | grep ".env"
# Should output: .env
```

---

## AWS Configuration

### 1. Get Your AWS Access Keys

```bash
# Log into AWS Console:
# https://console.aws.amazon.com/

# Go to: IAM → Users → (your user) → Security Credentials → Access Keys
# Create a new access key and note both:
# - AWS_ACCESS_KEY_ID (starts with AKIA...)
# - AWS_SECRET_ACCESS_KEY (shown only once)
```

### 2. Configure AWS CLI

```bash
# Set credentials in AWS CLI (optional, but useful for testing)
aws configure

# During the prompt, enter:
# AWS Access Key ID: AKIA...
# AWS Secret Access Key: wJalr...
# Default region: us-east-1
# Default output format: json

# Verify AWS CLI is working
aws sts get-caller-identity
# Should output: { "UserId": "...", "Account": "1234567890", "Arn": "arn:aws:iam::..." }
```

### 3. Check Your AWS Account Status

```bash
# Verify you have free tier eligibility (for t2.micro)
aws ec2 describe-account-attributes --attribute-names default-vpc

# List existing key pairs (to see if xgrid-key exists)
aws ec2 describe-key-pairs --region us-east-1
```

---

## Terraform State Backend Setup

### 1. Bootstrap Remote State Infrastructure (Run Once!)

This creates the S3 bucket and DynamoDB table for Terraform state management.

```bash
# Navigate to terraform directory
cd "week 2"

# Review the bootstrap script
cat bootstrap-remote-state.sh

# Run the bootstrap script
bash bootstrap-remote-state.sh
```

**Expected Output:**
```
🔧 Terraform Remote State Bootstrap
====================================
📦 Step 1: Creating S3 bucket for state storage...
✅ S3 bucket created
🔄 Step 2: Enabling versioning on S3 bucket...
✅ Versioning enabled
🔐 Step 3: Enabling encryption on S3 bucket...
✅ Encryption enabled
✅ Public access blocked
🔒 Step 5: Creating DynamoDB table for state locking...
✅ DynamoDB table created and active
```

### 2. Verify Remote State Infrastructure

```bash
# List S3 bucket
aws s3 ls s3://xgrid-terraform-state/

# Describe DynamoDB table
aws dynamodb describe-table --table-name terraform-locks --region us-east-1

# List DynamoDB table items (state locks)
aws dynamodb scan --table-name terraform-locks --region us-east-1
```

---

## Jenkins Docker Container Setup

### 1. Review Configuration Files

```bash
# Check Dockerfile.jenkins (custom Jenkins image with Docker)
cat Dockerfile.jenkins

# Check docker-compose.jenkins.yml (Jenkins container configuration)
cat docker-compose.jenkins.yml

# Check jenkins.yaml (JCasC configuration)
cat jenkins.yaml

# Check plugins.txt (pre-installed plugins)
cat plugins.txt
```

### 2. Build Jenkins Docker Image

```bash
# Navigate to week 2 directory
cd "week 2"

# Build the custom Jenkins image
docker build -f Dockerfile.jenkins -t week2-jenkins .

# Verify the image was created
docker images | grep week2-jenkins
```

### 3. Start Jenkins Container

```bash
# Start Jenkins container (with credentials from .env)
docker compose -f docker-compose.jenkins.yml up -d

# Verify container is running
docker compose -f docker-compose.jenkins.yml ps

# Check Jenkins logs
docker logs jenkins-controller

# Wait for Jenkins to fully initialize (30-60 seconds)
sleep 30

# Check if Jenkins is responding
curl -s http://localhost:8080 | head -20
```

### 4. Access Jenkins

```bash
# Open Jenkins in browser
# http://localhost:8080

# Initial admin password is in logs or:
docker logs jenkins-controller | grep "Please use the following password to proceed to installation:"

# OR retrieve from Jenkins home:
docker exec jenkins-controller cat /var/jenkins_home/secrets/initialAdminPassword
```

### 5. Verify JCasC Configuration

```bash
# Check if credentials were automatically loaded via JCasC
docker exec jenkins-controller curl -s http://localhost:8080/manage/credentials/ | grep -i "ec2\|aws"

# Or log into Jenkins UI and check:
# Manage Jenkins → Credentials → System → Global credentials
```

### 6. Stop Jenkins (if needed)

```bash
# Stop the Jenkins container
docker compose -f docker-compose.jenkins.yml down

# Remove the container and image (for fresh start)
docker compose -f docker-compose.jenkins.yml down --rmi all
```

---

## Generate and Manage EC2 SSH Keys

### 1. Check if xgrid-key Already Exists Locally

```bash
# List SSH keys on your Mac
ls -la ~/.ssh/ | grep -i xgrid

# If it exists, skip to "Add to AWS" section
```

### 2. Generate xgrid-key Locally (if it doesn't exist)

```bash
# Generate a new RSA key pair
ssh-keygen -t rsa -b 4096 -f ~/.ssh/xgrid-key -N ""

# Verify key was created
ls -la ~/.ssh/xgrid-key*

# Display public key (needed for AWS)
cat ~/.ssh/xgrid-key.pub
```

### 3. Add Public Key to AWS

```bash
# Import the public key to AWS
aws ec2 import-key-pair \
  --key-name xgrid-key \
  --public-key-material fileb://~/.ssh/xgrid-key.pub \
  --region us-east-1

# Verify key pair is in AWS
aws ec2 describe-key-pairs --key-names xgrid-key --region us-east-1
```

### 4. Set Correct Permissions on Private Key

```bash
# SSH requires strict permissions (400 = read-only for owner)
chmod 400 ~/.ssh/xgrid-key

# Verify permissions
ls -lh ~/.ssh/xgrid-key
# Should show: -r--------
```

### 5. Add Private Key to `.env` File

```bash
# Copy private key to .env (for Jenkins)
cat ~/.ssh/xgrid-key
# Copy the output (entire key including BEGIN/END lines)

# Edit .env and paste into EC2_SSH_PRIVATE_KEY field
nano .env
```

### 6. Test SSH Access (after EC2 is running)

```bash
# After Terraform provisions the EC2 instance, get its IP:
cd "week 2/terraform"
terraform output -raw public_ip
# Example output: 54.221.175.126

# SSH into the instance
ssh -i ~/.ssh/xgrid-key ubuntu@54.221.175.126

# If successful, you should see:
# ubuntu@ip-172-31-23-140:~$

# Exit SSH
exit
```

---

## Running the Pipeline

### 1. Verify Terraform Configuration

```bash
# Navigate to terraform directory
cd "week 2/terraform"

# Initialize Terraform (downloads plugins, sets up backend)
terraform init

# Format Terraform files for consistency
terraform fmt -recursive .

# Validate the Terraform configuration
terraform validate

# Plan infrastructure changes (dry run)
terraform plan -out=tfplan
```

### 2. Create Terraform Variables Override File (Optional)

```bash
# To provision with different settings (e.g., restricted SSH IP):
cat > terraform.tfvars << EOF
aws_region    = "us-east-1"
instance_type = "t2.micro"
allowed_ssh_ip = "YOUR.IP.ADDRESS/32"  # Replace with your IP
app_port      = 8000
EOF

# Verify the file was created
cat terraform.tfvars
```

### 3. Trigger Pipeline from Jenkins UI

```bash
# Open Jenkins in browser (if not already open)
# http://localhost:8080

# Log in (if prompted)

# Find job: "feature_issue-5-jenkins-pipeline"

# Click the job name

# Click "Build Now" button

# Watch the build progress in real-time
# Jenkins will:
#  1. Fetch Jenkinsfile from GitHub
#  2. Run Terraform (validate → plan → apply)
#  3. Wait for EC2 to be ready
#  4. Transfer files via SCP
#  5. Build and run Docker container
#  6. Run system audit
```

### 4. Trigger Pipeline from Command Line (Alternative)

```bash
# Get Jenkins CSRF token
JENKINS_TOKEN=$(curl -s 'http://localhost:8080/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,":",//crumb)')

# Trigger build
curl -X POST http://localhost:8080/job/feature_issue-5-jenkins-pipeline/build \
  -H "$JENKINS_TOKEN" \
  -v
```

### 5. Monitor Pipeline Execution

```bash
# Get job status (Jenkins CLI - if installed)
java -jar jenkins-cli.jar -s http://localhost:8080 get-job feature_issue-5-jenkins-pipeline

# Or use Jenkins REST API to get build info
curl -s http://localhost:8080/job/feature_issue-5-jenkins-pipeline/lastBuild/api/json | jq '.result'
```

### 6. View Final Output

```bash
# After pipeline completes successfully, get EC2 public IP:
cd "week 2/terraform"
terraform output

# Expected output:
# instance_id = "i-088ed653913f9a0d3"
# public_ip = "54.221.175.126"

# Test the health endpoint
curl http://54.221.175.126:8000/health

# Expected response:
# {"status":"healthy","version":"1.0.0"}
```

---

## Monitoring & Troubleshooting

### 1. Check Terraform State

```bash
# View current state
cd "week 2/terraform"
terraform state list

# Show details of a specific resource
terraform state show aws_instance.app_server

# Get outputs
terraform output
```

### 2. Check EC2 Instance Status

```bash
# List running EC2 instances
aws ec2 describe-instances \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,PublicIpAddress]' \
  --region us-east-1

# Check instance health status
aws ec2 describe-instance-status \
  --instance-ids i-088ed653913f9a0d3 \
  --region us-east-1

# View EC2 system logs (useful for diagnosing boot issues)
aws ec2 get-console-output --instance-id i-088ed653913f9a0d3 --region us-east-1
```

### 3. SSH into EC2 and Inspect

```bash
# SSH into the instance
ssh -i ~/.ssh/xgrid-key ubuntu@INSTANCE_IP

# Once connected, run diagnostic commands:

# Check Docker is running
docker --version
docker ps

# Check if container is running
docker ps | grep health-api

# View container logs
docker logs health-api

# Check disk usage
df -h

# Check memory usage
free -h

# Check listening ports
sudo netstat -tlnp | grep 8000

# Test health endpoint from EC2
curl http://localhost:8000/health

# Check system audit script output
cat /home/ubuntu/system_audit.sh
bash /home/ubuntu/system_audit.sh

# Exit SSH
exit
```

### 4. View Jenkins Logs

```bash
# Tail Jenkins logs (last 50 lines)
docker logs -n 50 jenkins-controller

# Tail continuously (live logs)
docker logs -f jenkins-controller

# View specific build logs from Jenkins UI:
# http://localhost:8080/job/feature_issue-5-jenkins-pipeline/[BUILD_NUMBER]/log
```

### 5. Common Issues & Fixes

#### Issue: "Error loading key: error in libcrypto"

```bash
# Fix: EC2_SSH_PRIVATE_KEY is malformed in .env
# Solution: Re-copy the key carefully:
cat ~/.ssh/xgrid-key | pbcopy
# Paste into .env (make sure BEGIN/END lines are intact)
# Restart Jenkins
docker compose -f docker-compose.jenkins.yml restart
```

#### Issue: "No changes in Terraform plan" but instance isn't responding

```bash
# Fix: Check EC2 user_data is still running
ssh -i ~/.ssh/xgrid-key ubuntu@INSTANCE_IP
# Check user_data log:
cat /var/log/cloud-init-output.log

# Or wait a few moments (user_data takes 30-60 seconds)
sleep 60
```

#### Issue: "SCP: command not found" or SSH timeout

```bash
# Fix: Ensure security group allows SSH/SCP:
aws ec2 describe-security-groups \
  --group-ids sg-XXXXX \
  --region us-east-1

# Ensure inbound rule for port 22 exists
# If not, add it:
aws ec2 authorize-security-group-ingress \
  --group-id sg-XXXXX \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0 \
  --region us-east-1
```

#### Issue: Docker build fails on EC2

```bash
# SSH into EC2
ssh -i ~/.ssh/xgrid-key ubuntu@INSTANCE_IP

# Check Docker daemon is running
sudo systemctl status docker

# Free up disk space if needed
docker system prune -a

# Check internet connectivity
ping -c 1 8.8.8.8

# Exit
exit
```

---

## Cleanup & Teardown

### 1. Stop and Remove Jenkins Container

```bash
# Stop Jenkins
docker compose -f docker-compose.jenkins.yml down

# Remove Jenkins image
docker rmi week2-jenkins

# Clean up Docker resources
docker system prune -a
```

### 2. Destroy AWS Infrastructure (Careful!)

```bash
# Navigate to terraform directory
cd "week 2/terraform"

# Destroy all AWS resources created by Terraform
terraform destroy

# You'll be prompted to confirm — type 'yes'

# Verify EC2 instance is terminated
aws ec2 describe-instances \
  --query 'Reservations[].Instances[].State.Name' \
  --region us-east-1
```

### 3. Delete Terraform State (Optional)

```bash
# This is only needed if you want to remove remote state entirely
# WARNING: This cannot be undone easily!

# Remove state file from S3
aws s3 rm s3://xgrid-terraform-state/week2/terraform.tfstate

# Remove DynamoDB locks (if any remain)
aws dynamodb scan --table-name terraform-locks --region us-east-1

# To completely delete state infrastructure:
# Delete S3 bucket
aws s3 rb s3://xgrid-terraform-state --force

# Delete DynamoDB table
aws dynamodb delete-table --table-name terraform-locks --region us-east-1
```

### 4. Clean Up Local Files

```bash
# Remove .env (contains secrets)
rm .env

# Remove Terraform local state cache
rm -rf "week 2/terraform/.terraform"
rm "week 2/terraform/.terraform.lock.hcl"
rm "week 2/terraform/tfplan"
```

### 5. Remove AWS Key Pair (Optional)

```bash
# Delete the EC2 key pair from AWS
aws ec2 delete-key-pair --key-name xgrid-key --region us-east-1

# WARNING: Keep the local key file (~/.ssh/xgrid-key) for backup
# You can delete it after confirming AWS key is removed:
# rm ~/.ssh/xgrid-key ~/.ssh/xgrid-key.pub
```

---

## Quick Reference: Most Common Commands

```bash
# 1. Start everything
cd "week 2"
docker compose -f docker-compose.jenkins.yml up -d

# 2. Check Jenkins is running
curl -s http://localhost:8080 | head -5

# 3. Open Jenkins UI
open http://localhost:8080

# 4. Trigger build
curl -X POST http://localhost:8080/job/feature_issue-5-jenkins-pipeline/build

# 5. Get EC2 public IP
cd terraform && terraform output -raw public_ip

# 6. SSH into EC2
ssh -i ~/.ssh/xgrid-key ubuntu@$(cd terraform && terraform output -raw public_ip)

# 7. Check container status on EC2
docker ps

# 8. Check health endpoint
curl http://$(cd terraform && terraform output -raw public_ip):8000/health

# 9. View Jenkins logs
docker logs -f jenkins-controller

# 10. Stop everything
docker compose -f docker-compose.jenkins.yml down
```

---

## Environment Variables Summary

| Variable | Value | Required | Notes |
|----------|-------|----------|-------|
| `AWS_ACCESS_KEY_ID` | AKIA... | Yes | From AWS IAM console |
| `AWS_SECRET_ACCESS_KEY` | wJalr... | Yes | From AWS IAM console |
| `EC2_SSH_PRIVATE_KEY` | -----BEGIN RSA... | Yes | Content of ~/.ssh/xgrid-key |
| `AWS_REGION` | us-east-1 | No | Default in terraform |
| `INSTANCE_TYPE` | t2.micro | No | Default in terraform |
| `CONTAINER_NAME` | health-api | No | Set in Jenkinsfile |
| `APP_PORT` | 8000 | No | Set in terraform |

---

## Useful Links

- **GitHub Repository**: https://github.com/Dxgrid/xgrid-internship-bootstrap
- **AWS Console**: https://console.aws.amazon.com/
- **Jenkins**: http://localhost:8080 (when running)
- **EC2 Instance Health**: `http://<PUBLIC_IP>:8000/health`
- **Terraform Docs**: https://www.terraform.io/docs/
- **Jenkins Docs**: https://www.jenkins.io/doc/

---

**Last Updated**: April 28, 2026  
**Project**: Week 2 DevOps Sprint - CI/CD Pipeline  
**Status**: Production Ready ✅
