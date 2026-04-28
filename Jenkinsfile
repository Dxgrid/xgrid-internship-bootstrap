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

        // Stage 1: Checkout
        stage('Checkout') {
            steps {
                echo 'Checking out source from Git...'
                sh 'git clone https://github.com/Dxgrid/xgrid-internship-bootstrap.git . || git pull'
            }
        }

        // Stage 2: Terraform Provision EC2
        stage('Terraform Provision') {
            steps {
                dir("${TF_DIR}") {
                    withCredentials([
                        string(credentialsId: 'aws-access-key-id', variable: 'AWS_ACCESS_KEY_ID'),
                        string(credentialsId: 'aws-secret-access-key', variable: 'AWS_SECRET_ACCESS_KEY')
                    ]) {
                        sh 'terraform init -input=false'
                        sh 'terraform apply -auto-approve -input=false'
                        script {
                            env.TARGET_IP = sh(script: 'terraform output -raw public_ip', returnStdout: true).trim()
                        }
                    }
                }
                echo "EC2 Provisioned. IP: ${env.TARGET_IP}"
            }
        }

        // Stage 3: Wait for SSH to be Ready
        stage('Wait for SSH Ready') {
            steps {
                script {
                    echo "Waiting for SSH on ${env.TARGET_IP}:22..."
                    timeout(time: 5, unit: 'MINUTES') {
                        waitUntil(initialRecurrencePeriod: 10000) {
                            def ready = sh(script: "nc -zw5 ${env.TARGET_IP} 22", returnStatus: true)
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

        // Stage 4: Transfer Files to EC2
        stage('Transfer Files') {
            steps {
                sshagent(credentials: ['ec2-ssh-key']) {
                    sh '''
                        scp -o StrictHostKeyChecking=no -o BatchMode=yes -r ${APP_DIR} ${SSH_USER}@${TARGET_IP}:/home/${SSH_USER}/
                        scp -o StrictHostKeyChecking=no -o BatchMode=yes ${AUDIT_SCRIPT} ${SSH_USER}@${TARGET_IP}:/home/${SSH_USER}/
                    '''
                }
                echo 'Files transferred successfully'
            }
        }

        // Stage 5: Build and Deploy Docker Container
        stage('Build and Deploy Container') {
            steps {
                sshagent(credentials: ['ec2-ssh-key']) {
                    sh '''
                        ssh -o StrictHostKeyChecking=no -o BatchMode=yes ${SSH_USER}@${TARGET_IP} << 'EOF'
                        set -e
                        
                        echo "Stopping old container if it exists..."
                        docker stop ${CONTAINER_NAME} || true
                        docker rm ${CONTAINER_NAME} || true
                        
                        echo "Building Docker image..."
                        cd /home/${SSH_USER}/app
                        docker build -t ${CONTAINER_NAME}:latest .
                        
                        echo "Starting new container..."
                        docker run -d --name ${CONTAINER_NAME} --restart unless-stopped -p ${APP_PORT}:${APP_PORT} ${CONTAINER_NAME}:latest
                        
                        echo "Container is running:"
                        docker ps | grep ${CONTAINER_NAME}
EOF
                    '''
                }
            }
        }

        // Stage 6: Run System Audit
        stage('Run System Audit') {
            steps {
                script {
                    sshagent(credentials: ['ec2-ssh-key']) {
                        def auditStatus = sh(script: '''
                            ssh -o StrictHostKeyChecking=no -o BatchMode=yes ${SSH_USER}@${TARGET_IP} \
                            'chmod +x /home/${SSH_USER}/system_audit.sh && bash /home/${SSH_USER}/system_audit.sh'
                        ''', returnStatus: true)
                        
                        if (auditStatus != 0) {
                            error("System audit failed with exit code ${auditStatus}")
                        }
                        echo 'Audit passed successfully!'
                    }
                }
            }
        }
    }

    post {
        always {
            echo 'Cleaning up workspace...'
            cleanWs()
        }

        success {
            echo '''
SUCCESS! Deployment Complete
Health API: http://${TARGET_IP}:8000/health
            '''
        }

        failure {
            echo '''
FAILED! Check the logs above for errors.
            '''
        }
    }
}
