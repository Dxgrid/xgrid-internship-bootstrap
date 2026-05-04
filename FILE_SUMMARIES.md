# Repository File Summaries

This file contains 2–4 line annotated summaries for each file in the repository to help you understand the Week 2 codebase and related artifacts.

---

**.gitignore**
- Git ignore rules for the whole repository. Hides local artifacts, credentials, and build outputs from commits.

**Jenkinsfile**
- Declarative Jenkins pipeline used by the CI job. Defines the steps Jenkins will run (checkout, build, test, deploy) for the project.

**.github/workflows/monitor.yml**
- GitHub Actions workflow for automated monitoring or CI tasks. Contains steps to run checks or monitoring jobs in GitHub CI.

## Week 1 (Monitoring)

**week 1/prometheus.yml**
- Configuration for Prometheus scraping targets and rules. Defines job(s) and scrape intervals used by the monitoring stack.

**week 1/docker-compose.yml**
- Docker Compose file to run the Week 1 monitoring stack (Prometheus, Grafana, exporters). Useful for local testing.

**week 1/monitor.sh**
- Small helper script to start or test the monitoring stack. Wraps common docker-compose or health-check commands.

**week 1/create_dashboard.py**
- Script to create Grafana dashboards programmatically via API. Automates dashboard provisioning for visualizing metrics.

**week 1/README.md**
- Documentation for the Week 1 monitoring project. Explains how to run the stack and what each component does.

**week 1/prometheus_exporter.py**
- A simple Prometheus exporter exposing custom metrics. Intended to demonstrate metrics collection and scraping.

## Week 2 (CI/CD & Infra)

**week 2/COMMANDS.md**
- A comprehensive runbook for Week 2. Lists all commands and step-by-step instructions to bootstrap remote state, run Terraform, start Jenkins, and debug deployments.

**week 2/.env.example**
- Example environment file showing required variables and secrets for Jenkins JCasC and pipelines. Use as a template for local `.env` (do not commit real secrets).

**week 2/Dockerfile.jenkins**
- Dockerfile for a custom Jenkins image. Installs Docker CLI, Terraform, and preloads required Jenkins plugins to enable CI tasks that run Docker and Terraform.

**week 2/docker-compose.jenkins.yml**
- Docker Compose configuration to run the Jenkins controller locally. Mounts `jenkins_home`, binds ports, injects environment variables and provides Docker socket access.

**week 2/docker-compose.health-api.yml**
- Compose file for running the `health-api` service locally. Defines container, ports, healthcheck, and restart policy for testing the FastAPI app.

**week 2/Dockerfile**
- Multi-stage Dockerfile to build the FastAPI Health API. Uses a builder stage to install dependencies, creates a non-root runtime user, and includes a HEALTHCHECK.

**week 2/plugins.txt**
- List of Jenkins plugins installed into the custom image. Ensures pipeline, Docker, Git, credentials, and JCasC features are available.

**week 2/jenkins.yaml**
- Jenkins Configuration as Code (JCasC) file. Provisions security settings and credentials (AWS and SSH) into Jenkins at startup using environment substitution.

**week 2/setup-jcasc.sh**
- Interactive helper script to load AWS and EC2 SSH credentials into the environment and (re)build start the Jenkins container with JCasC enabled.

**week 2/bootstrap-remote-state.sh**
- Bootstrap script that creates an S3 bucket and DynamoDB table for Terraform remote state and locking. Run once before `terraform init`.

**week 2/scripts/system_audit.sh**
- Post-deploy system audit script intended to run on the EC2 host. Checks disk usage, ports (22/8000), container status, and the `/health` endpoint, returning non-zero on failure.

**week 2/.dockerignore**
- Docker ignore file to reduce build context when building images from `week 2`. Improves build performance and reduces accidental inclusions.

**week 2/.gitignore**
- Git ignore file scoped to the Week 2 directory. Suppresses local state, `.env`, and build artifacts specific to Week 2.

### App (Health API)

**week 2/app/main.py**
- The FastAPI application providing `/health` and `/` endpoints. Minimal, production-minded app with logging and JSON responses used as the deployed service.

**week 2/app/Dockerfile**
- App-specific Dockerfile (if present). Note: the repository also contains `week 2/Dockerfile` which performs a multi-stage build for the app.

**week 2/app/requirements.txt**
- Python dependencies for the FastAPI service (`fastapi`, `uvicorn`). Used by the Docker build to install runtime packages.

### Terraform (Infrastructure)

**week 2/terraform/backend.tf**
- Terraform backend configuration pointing to the S3 bucket and DynamoDB table used for remote state storage and locking.

**week 2/terraform/providers.tf**
- Terraform provider declarations and required versions (AWS provider configuration and Terraform version constraints).

**week 2/terraform/variables.tf**
- Input variable definitions and sensible defaults for region, instance type, SSH restrictions, key pair name, and the app port.

**week 2/terraform/main.tf**
- Core Terraform resources and data sources: fetches caller IP and latest Ubuntu AMI, creates the EC2 instance, associates security group and user-data script.

**week 2/terraform/vpc.tf**
- VPC networking resources: VPC, public subnet, internet gateway, route table and association. Keeps network components modular.

**week 2/terraform/outputs.tf**
- Terraform outputs exposing `public_ip` and `instance_id` of the provisioned EC2 instance for easy consumption by pipelines and scripts.

**week 2/terraform/user_data.sh**
- The EC2 user-data script that runs at boot to install Docker, Docker Compose, utilities and create app directories — prepares the instance to run containers.

**week 2/terraform/.terraform.lock.hcl**
- Terraform dependency lock file that pins provider versions used during `terraform init` to ensure reproducible runs.

**week 2/terraform/.gitignore**
- Terraform-specific ignores to avoid committing local state, `.terraform` caches and plan files.

---

If you'd like, I can commit this file to the repository (already created) and then:

- Add `requests` to `week 2/app/requirements.txt` and update the Dockerfile healthcheck to use `curl` (recommended fix), or
- Produce a per-file annotated diff highlighting important lines to review next.

Tell me which follow-up you'd like.

Test push note: this line exists only to verify that a small commit triggers the GitHub webhook path.
