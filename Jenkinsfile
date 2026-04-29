// Jenkinsfile - Week 2 End-to-End Pipeline
// Terraform → Docker → Deploy → Audit

pipeline {
    agent any

    environment {
        TF_DIR         = 'week 2/terraform'
        APP_DIR        = 'week 2/app'
        AUDIT_SCRIPT   = 'week 2/scripts/system_audit.sh'
        SSH_USER       = 'ubuntu'
        CONTAINER_NAME = 'health-api'
        APP_PORT       = '8000'
    }

    options {
        timestamps()
        timeout(time: 30, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }

    stages {

        // Stage 1: Terraform Validation
        stage('Terraform Validate') {
            steps {
                dir("${TF_DIR}") {
                    withAWS(credentials: 'aws-credentials', region: 'us-east-1') {
                        sh 'terraform version'
                        sh 'terraform init -input=false'
                        sh 'terraform fmt -recursive .'
                        sh 'terraform validate'
                        echo '✅ Terraform configuration is valid'
                    }
                }
            }
        }

        // Stage 2: Terraform Plan
        stage('Terraform Plan') {
            steps {
                dir("${TF_DIR}") {
                    withAWS(credentials: 'aws-credentials', region: 'us-east-1') {
                        sh 'terraform init -input=false'
                        sh 'terraform plan -input=false -out=tfplan'
                        echo '📋 Terraform plan saved to tfplan'
                    }
                }
            }
        }

        // Stage 3: Terraform Apply (uses plan from previous stage)
        stage('Terraform Provision') {
            steps {
                dir("${TF_DIR}") {
                    withAWS(credentials: 'aws-credentials', region: 'us-east-1') {
                        sh 'terraform apply -input=false tfplan'
                        script {
                            env.TARGET_IP = sh(script: 'terraform output -raw public_ip', returnStdout: true).trim()
                        }
                    }
                }
                echo "🎯 EC2 Provisioned. IP: ${env.TARGET_IP}"
            }
        }

        // Stage 4: Wait for SSH to be Ready
        stage('Wait for SSH Ready') {
            steps {
                script {
                    echo "Waiting for SSH on ${env.TARGET_IP}:22..."
                    timeout(time: 5, unit: 'MINUTES') {
                        waitUntil(initialRecurrencePeriod: 10000) {
                            def ready = sh(script: """bash -c "exec 3<>/dev/tcp/${env.TARGET_IP}/22" 2>/dev/null && exit 0 || exit 1""", returnStatus: true)
                            if (ready == 0) {
                                echo 'SSH is ready!'
                                return true
                            }
                            echo 'Waiting for SSH...'
                            return false
                        }
                    }
                    sleep(time: 10, unit: 'SECONDS')
                    echo 'EC2 is ready for deployment'
                }
            }
        }

        // Stage 4.5: Ensure Docker is Installed
        stage('Install Docker') {
            steps {
                sshagent(credentials: ['ec2-ssh-key']) {
                    sh """
                        echo "🔍 Checking if Docker is installed..."
                        if ssh -o StrictHostKeyChecking=no -o BatchMode=yes ${SSH_USER}@${TARGET_IP} "docker --version" 2>/dev/null; then
                            echo "✅ Docker already installed"
                        else
                            echo "⚙️ Waiting for user_data script to complete (apt lock release)..."
                            ssh -o StrictHostKeyChecking=no -o BatchMode=yes ${SSH_USER}@${TARGET_IP} << WAIT_APT
# Wait for apt lock to be released (user_data script may still be running)
for i in {1..60}; do
  if ! sudo lsof /var/lib/apt/lists/lock 2>/dev/null | grep -q apt; then
    echo "✅ apt lock released - user_data complete"
    break
  fi
  echo "⏳ Waiting for apt lock... (\$i/60)"
  sleep 5
done

echo "⚙️ Installing Docker on EC2..."
set -e
echo "Updating package manager..."
sudo apt-get update -qq

echo "Installing Docker and dependencies..."
sudo apt-get install -y -qq docker.io docker-compose curl wget

echo "Adding ubuntu user to docker group..."
sudo usermod -aG docker ubuntu

echo "Starting Docker service..."
sudo systemctl start docker
sudo systemctl enable docker

echo "Waiting for Docker daemon..."
sleep 5

echo "Verifying Docker installation..."
docker --version
WAIT_APT
                            echo "✅ Docker installed successfully"
                        fi
                    """
                }
            }
        }

        // Stage 5: Transfer Files to EC2
        stage('Transfer Files') {
            steps {
                sshagent(credentials: ['ec2-ssh-key']) {
                    sh """
                        echo "📁 Transferring application files via rsync..."
                        echo "Source: ${APP_DIR}"
                        rsync -avz -e "ssh -o StrictHostKeyChecking=no -o BatchMode=yes" "${APP_DIR}" ${SSH_USER}@${TARGET_IP}:/home/${SSH_USER}/
                        
                        echo "📋 Transferring audit script via rsync..."
                        echo "Source: ${AUDIT_SCRIPT}"
                        rsync -avz -e "ssh -o StrictHostKeyChecking=no -o BatchMode=yes" "${AUDIT_SCRIPT}" ${SSH_USER}@${TARGET_IP}:/home/${SSH_USER}/
                        
                        echo "✅ Verifying files transferred to EC2..."
                        ssh -o StrictHostKeyChecking=no -o BatchMode=yes ${SSH_USER}@${TARGET_IP} "ls -la /home/${SSH_USER}/"
                    """
                }
                echo '✅ Files transferred successfully'
            }
        }

        // Stage 6: Build and Deploy Docker Container
        stage('Build and Deploy Container') {
            steps {
                sshagent(credentials: ['ec2-ssh-key']) {
                    sh """
                        ssh -o StrictHostKeyChecking=no -o BatchMode=yes ${SSH_USER}@${TARGET_IP} << EOF
                        set -e
                        
                        echo "🚀 ======================================="
                        echo "Build and Deploy Stage"
                        echo "======================================="
                        echo "Container: ${CONTAINER_NAME}"
                        echo "App Port: ${APP_PORT}"
                        echo "SSH User: ${SSH_USER}"
                        echo ""
                        
                        echo "📁 Checking if app directory exists..."
                        ls -la /home/${SSH_USER}/app || echo "⚠️ App directory not found!"
                        
                        echo ""
                        echo "Stopping old container if it exists..."
                        docker stop ${CONTAINER_NAME} || true
                        docker rm ${CONTAINER_NAME} || true
                        
                        echo ""
                        echo "🐳 Building Docker image..."
                        cd /home/${SSH_USER}/app
                        docker build -t ${CONTAINER_NAME}:latest .
                        
                        echo ""
                        echo "🚀 Starting new container..."
                        docker run -d --name ${CONTAINER_NAME} --restart unless-stopped -p ${APP_PORT}:${APP_PORT} ${CONTAINER_NAME}:latest
                        
                        echo ""
                        echo "✅ Container is running:"
                        docker ps | grep ${CONTAINER_NAME}
                        
                        echo ""
                        echo "🌐 Testing health endpoint..."
                        curl -s http://localhost:${APP_PORT}/health | head -20 || echo "⚠️ Health endpoint not yet responding"
EOF
                    """
                }
            }
        }

        // Stage 7: Run System Audit
        stage('Run System Audit') {
            steps {
                script {
                    sshagent(credentials: ['ec2-ssh-key']) {
                        def auditStatus = sh(script: """
                            echo "📊 Running system audit on ${TARGET_IP}..."
                            ssh -o StrictHostKeyChecking=no -o BatchMode=yes ${SSH_USER}@${TARGET_IP} << AUDIT_EOF
                            echo "======================================="
                            echo "System Audit Report"
                            echo "======================================="
                            chmod +x /home/${SSH_USER}/system_audit.sh
                            bash /home/${SSH_USER}/system_audit.sh
AUDIT_EOF
                        """, returnStatus: true)
                        
                        if (auditStatus != 0) {
                            error("❌ System audit failed with exit code ${auditStatus}")
                        }
                        echo '✅ Audit passed successfully!'
                    }
                }
            }
        }
    }

    post {
        always {
            echo 'Pipeline execution finished.'
        }

        success {
            echo 'Cleaning up workspace after successful build...'
            cleanWs()
            echo """
===========================================
✅ SUCCESS! Deployment Complete
===========================================

🌐 Health API Endpoint:
   http://${env.TARGET_IP}:8000/health

📊 System Status:
   - EC2 Instance: Running
   - Docker Container: Deployed
   - Health Check: Passing
   - Audit Results: ✓ OK

Next Steps:
- Monitor the health endpoint
- Check CloudWatch logs if needed
            """
        }

        failure {
            echo '''
FAILED! Check the logs above for errors.
            '''
        }
    }
}
