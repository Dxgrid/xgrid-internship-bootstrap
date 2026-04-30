// Jenkinsfile - Week 2 End-to-End Pipeline

def TARGET_IP = ""

pipeline {
    agent any
    
    triggers {
        githubPush()
    }

    environment {
        // Global Config
        TF_DIR          = 'week 2/terraform'
        SCRIPTS_DIR     = 'week 2/scripts'
        
        // Docker Hub Config
        DOCKER_HUB_USER = 'Dxgrid'
        IMAGE_NAME      = 'health-api'
        DOCKER_REPO     = "${DOCKER_HUB_USER}/${IMAGE_NAME}"
        APP_PORT        = '8000'
        
        // Removed TARGET_IP from here
    }

    stages {
        stage('Terraform Validate') {
            steps {
                dir("${env.TF_DIR}") {
                    withAWS(credentials: 'aws-credentials', region: 'us-east-1') {
                        sh 'terraform init -input=false'
                        sh 'terraform fmt -recursive .'
                        sh 'terraform validate'
                        echo '✅ Terraform configuration is valid'
                    }
                }
            }
        }

        stage('Terraform Plan') {
            steps {
                dir("${env.TF_DIR}") {
                    withAWS(credentials: 'aws-credentials', region: 'us-east-1') {
                        sh 'terraform init -input=false'
                        sh 'terraform plan -input=false -out=tfplan'
                        echo '📋 Terraform plan saved to tfplan'
                    }
                }
            }
        }

        stage('Terraform Provision') {
            steps {
                dir("${env.TF_DIR}") {
                    withAWS(credentials: 'aws-credentials', region: 'us-east-1') {
                        sh 'terraform apply -input=false tfplan'
                        script {
                            // Assign to the global Groovy variable
                            TARGET_IP = sh(script: "terraform output -raw public_ip", returnStdout: true).trim()
                        }
                    }
                }
                echo "🎯 EC2 Provisioned. IP: ${TARGET_IP}"
            }
        }

        stage('Wait for SSH Ready') {
            steps {
                script {
                    echo "Waiting for SSH on ${TARGET_IP}:22..."
                    timeout(time: 5, unit: 'MINUTES') {
                        waitUntil(initialRecurrencePeriod: 10000) {
                            def ready = sh(script: "bash -c \"exec 3<>/dev/tcp/${TARGET_IP}/22\" 2>/dev/null && exit 0 || exit 1", returnStatus: true)
                            if (ready == 0) {
                                echo 'SSH is ready!'
                                return true
                            }
                            return false
                        }
                    }
                    sleep 10
                    echo 'EC2 is ready for deployment'
                }
            }
        }

        stage('Build and Push Image') {
            steps {
                script {
                    echo "🐳 Building and Pushing Image: ${env.DOCKER_REPO}:${BUILD_NUMBER}"
                    docker.withRegistry('https://index.docker.io/v1/', 'docker-hub-creds') {
                        // Build from the app directory
                        def customImage = docker.build("${env.DOCKER_REPO}:${BUILD_NUMBER}", "./week\\ 2/app")
                        
                        // Push specific version and 'latest'
                        customImage.push()
                        customImage.push('latest')
                    }
                    echo "✅ Image pushed successfully to Docker Hub"
                }
            }
        }

        stage('Remote Deploy') {
            steps {
                // Use both SSH and Docker credentials
                sshagent(['ec2-ssh-key']) {
                    withCredentials([usernamePassword(credentialsId: 'docker-hub-creds', usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                        sh """
                            ssh -o StrictHostKeyChecking=no ubuntu@${TARGET_IP} << 'EOF'
                                # Login to Docker Hub
                                echo "${DOCKER_PASS}" | docker login -u "${DOCKER_USER}" --password-stdin
                                
                                # Clean up existing containers
                                docker stop ${env.IMAGE_NAME} || true
                                docker rm ${env.IMAGE_NAME} || true
                                
                                # Pull the fresh image
                                echo "📥 Pulling image version: ${BUILD_NUMBER}"
                                docker pull ${env.DOCKER_REPO}:${BUILD_NUMBER}
                                
                                # Run the container
                                echo "🚀 Starting container..."
                                docker run -d \
                                    --name ${env.IMAGE_NAME} \
                                    --restart unless-stopped \
                                    -p ${env.APP_PORT}:${env.APP_PORT} \
                                    ${env.DOCKER_REPO}:${BUILD_NUMBER}
                                
                                # Security cleanup
                                docker logout
                            EOF
                        """
                    }
                }
            }
        }

        stage('Run System Audit') {
            steps {
                sshagent(['ec2-ssh-key']) {
                    sh """
                        echo "📊 Executing system audit on EC2 host..."
                        ssh -o StrictHostKeyChecking=no ubuntu@${TARGET_IP} << 'EOF'
                            STATUS=0
                            
                            # 1. Check Disk
                            USAGE=\$(df / | awk 'NR==2 {print \$5}' | tr -d '%')
                            if [ "\$USAGE" -gt 90 ]; then echo "❌ Disk Full (\$USAGE%)"; STATUS=1; fi
                            
                            # 2. Check if container is running
                            if ! docker ps --format "{{.Names}}" | grep -q "${env.IMAGE_NAME}"; then
                                echo "❌ Container ${env.IMAGE_NAME} NOT running"; STATUS=1
                            fi
                            
                            # 3. Check Health Endpoint
                            CODE=\$(curl -s -o /dev/null -w "%{http_code}" http://localhost:${env.APP_PORT}/health)
                            if [ "\$CODE" != "200" ]; then
                                echo "❌ Health Check Failed (HTTP \$CODE)"; STATUS=1
                            fi
                            
                            if [ \$STATUS -eq 0 ]; then
                                echo "✅ --- AUDIT PASSED ---"
                                exit 0
                            else
                                echo "❌ --- AUDIT FAILED ---"
                                exit 1
                            fi
EOF
                    """
                }
            }
        }
    }

    post {
        always {
            echo "Pipeline execution finished."
            cleanWs()
        }
        success {
            echo """
            ===========================================
            ✅ SUCCESS! Docker-Hub Deployment Complete
            ===========================================
            
            🌐 Health API Endpoint:
               http://${TARGET_IP}:${env.APP_PORT}/health
            
            📦 Image Version:
               ${env.DOCKER_REPO}:${BUILD_NUMBER}
            
            📊 Status:
               - Source Code: Kept on Jenkins (Secured)
               - Build Engine: Jenkins Node
               - Production: Docker Pull Only (Clean)
            ===========================================
            """
        }
        failure {
            echo '''
FAILED! Check the logs above for errors.
            '''
        }
    }
}
