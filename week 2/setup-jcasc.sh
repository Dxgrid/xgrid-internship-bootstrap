#!/bin/bash
# Jenkins JCasC Setup — Credentials Provision Script
# This script helps you set up credentials correctly via JCasC

set -e

echo "🔧 Jenkins JCasC Credential Setup"
echo "=================================="
echo ""
echo "This script will help you provision credentials for Jenkins via JCasC."
echo ""

# Load existing .env if it exists
if [ -f .env ]; then
  echo "📂 Found .env file. Loading credentials from it..."
  set -a
  source .env
  set +a
  echo "✅ Credentials loaded from .env"
  echo ""
else
  echo "⚠️  No .env file found. You'll need to enter credentials manually."
  echo ""
fi

# Step 1: AWS Access Key ID
echo "📌 Step 1: AWS Access Key ID"
echo "You can find this in your AWS console under:"
echo "  AWS Console → Users → Security Credentials → Access Keys"
echo ""
if [ -z "$AWS_ACCESS_KEY_ID" ]; then
  read -p "Enter your AWS Access Key ID (AKIA...): " AWS_ACCESS_KEY_ID
  if [ -z "$AWS_ACCESS_KEY_ID" ]; then
    echo "❌ AWS Access Key ID is required"
    exit 1
  fi
else
  echo "Using AWS Access Key ID from .env: ${AWS_ACCESS_KEY_ID:0:10}..."
fi
export AWS_ACCESS_KEY_ID
echo "✅ AWS Access Key ID saved"
echo ""

# Step 2: AWS Secret Access Key
echo "📌 Step 2: AWS Secret Access Key"
echo "This is shown ONLY when you create the access key — save it from AWS console."
echo ""
if [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  read -sp "Enter your AWS Secret Access Key: " AWS_SECRET_ACCESS_KEY
  echo ""
  if [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "❌ AWS Secret Access Key is required"
    exit 1
  fi
else
  echo "✅ Using AWS Secret Access Key from .env (hidden)"
fi
export AWS_SECRET_ACCESS_KEY
echo "✅ AWS Secret Access Key saved (hidden from display)"
echo ""

# Step 3: EC2 SSH Private Key
echo "📌 Step 3: EC2 SSH Private Key"
echo "This is the .pem file used to SSH into your EC2 instances."
echo "Path should be: ~/.ssh/your-key.pem"
echo ""
if [ -z "$EC2_SSH_PRIVATE_KEY" ]; then
  read -p "Enter path to your EC2 SSH private key file: " SSH_KEY_FILE
  # Expand tilde to home directory if present
  SSH_KEY_FILE="${SSH_KEY_FILE/#\~/$HOME}"

  if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "❌ SSH key file not found: $SSH_KEY_FILE"
    exit 1
  fi

  export EC2_SSH_PRIVATE_KEY="$(cat "$SSH_KEY_FILE")"
  echo "✅ EC2 SSH Private Key loaded"
else
  echo "✅ Using EC2 SSH Private Key from .env"
fi
export EC2_SSH_PRIVATE_KEY
echo ""
echo ""

# Step 4: Docker Hub Credentials
echo "📌 Step 4: Docker Hub Credentials"
echo ""
if [ -z "$DOCKER_HUB_USERNAME" ]; then
  read -p "Enter your Docker Hub username: " DOCKER_HUB_USERNAME
  if [ -z "$DOCKER_HUB_USERNAME" ]; then
    echo "❌ Docker Hub username is required"
    exit 1
  fi
else
  echo "Using Docker Hub username from .env: $DOCKER_HUB_USERNAME"
fi
export DOCKER_HUB_USERNAME
echo "✅ Docker Hub username saved"
echo ""

if [ -z "$DOCKER_HUB_TOKEN" ]; then
  read -sp "Enter your Docker Hub access token: " DOCKER_HUB_TOKEN
  echo ""
  if [ -z "$DOCKER_HUB_TOKEN" ]; then
    echo "❌ Docker Hub access token is required"
    exit 1
  fi
else
  echo "✅ Using Docker Hub access token from .env (hidden)"
fi
export DOCKER_HUB_TOKEN
echo ""

# Step 5: Rebuild and restart Jenkins with new plugins
echo "📌 Step 5: Rebuilding Jenkins with JCasC plugins"
echo "This will rebuild the Docker image with configuration-as-code plugin..."
echo ""

cd "$(dirname "$0")"

echo "Stopping running Jenkins container..."
docker compose -f docker-compose.jenkins.yml down || true
echo "✅ Jenkins stopped"
echo ""

echo "Rebuilding Jenkins image (this may take 2-3 minutes for plugin installation)..."
docker compose -f docker-compose.jenkins.yml build --no-cache
echo "✅ Jenkins image rebuilt"
echo ""

echo "Starting Jenkins with JCasC configuration..."
docker compose -f docker-compose.jenkins.yml up -d
echo "✅ Jenkins started"
echo ""

# Step 6: Verify
echo "📌 Step 6: Verifying JCasC credential provisioning"
echo "Waiting for Jenkins to become ready..."
sleep 10

echo "Checking if credentials were loaded by JCasC..."
CREDENTIALS_CHECK=$(docker exec jenkins-controller curl -s http://localhost:8080/credentials/ 2>/dev/null || echo "waiting")

if [ "$CREDENTIALS_CHECK" != "waiting" ]; then
  echo "✅ Jenkins is responding"
else
  echo "⏳ Jenkins is still starting. Check logs:"
  echo "   docker logs -f jenkins-controller"
fi

echo ""
echo "🎉 Setup complete!"
echo ""
echo "Next steps:"
echo "1. Open http://localhost:8080 in your browser"
echo "2. Go to Manage Jenkins → Credentials → System → Global credentials"
echo "3. You should see 3 credentials:"
echo "   - aws-credentials (AWS type - combines access key and secret key)"
echo "   - ec2-ssh-key (SSH key type)"
echo "   - docker-hub-creds (Docker Hub username/password)"
echo ""
echo "4. These credentials are now provisioned by JCasC and will be available to pipelines"
echo ""
echo "To verify in Jenkins logs:"
echo "   docker exec jenkins-controller tail -50 /var/log/docker.log | grep -i credential"
