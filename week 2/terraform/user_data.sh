#!/bin/bash
# EC2 User Data Script - Install Dependencies
# Runs at instance boot time to install Docker and dependencies

set -e  # Exit on error

echo "=========================================="
echo "🚀 Starting EC2 setup at $(date)"
echo "=========================================="

# Update system packages
echo "📦 Updating system packages..."
apt-get update
apt-get upgrade -y

# Install Docker
echo "🐳 Installing Docker..."
apt-get install -y docker.io

# Add ubuntu user to docker group (no sudo needed)
echo "👤 Adding ubuntu user to docker group..."
usermod -aG docker ubuntu

# Enable Docker to start on boot
echo "⚙️  Enabling Docker auto-start..."
systemctl enable docker
systemctl start docker

# Install Docker Compose
echo "📦 Installing Docker Compose..."
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Install additional utilities
echo "📦 Installing utilities..."
apt-get install -y \
    curl \
    wget \
    git \
    htop \
    net-tools

# Create app directory
echo "📁 Creating app directory..."
mkdir -p /home/ubuntu/app
mkdir -p /home/ubuntu/scripts
chown -R ubuntu:ubuntu /home/ubuntu/app
chown -R ubuntu:ubuntu /home/ubuntu/scripts

echo "=========================================="
echo "✅ EC2 setup complete at $(date)"
echo "=========================================="

# Verify installations
echo ""
echo "📋 Installed versions:"
docker --version
docker-compose --version
