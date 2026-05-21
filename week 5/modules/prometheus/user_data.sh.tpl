#!/bin/bash
set -euo pipefail

# ── System updates ────────────────────────────────────────────────────────────
yum update -y

# ── Install Docker (Amazon Linux 2) ──────────────────────────────────────────
amazon-linux-extras install docker -y
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

# ── Install Docker Compose v2 plugin ─────────────────────────────────────────
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# ── Install Python 3, pip, boto3 for the daily report script ─────────────────
yum install -y python3 python3-pip jq
pip3 install boto3 requests "urllib3<2.0"

# ── Create directory structure ────────────────────────────────────────────────
mkdir -p /opt/monitoring/prometheus/data
mkdir -p /opt/monitoring/prometheus/targets
# Prometheus container runs as UID 65534 (nobody) — data dir must be writable by it
chown -R 65534:65534 /opt/monitoring/prometheus/data
mkdir -p /opt/monitoring/grafana/provisioning/datasources
mkdir -p /opt/monitoring/grafana/provisioning/dashboards
mkdir -p /opt/monitoring/scripts

# ── Write prometheus.yml ──────────────────────────────────────────────────────
# Uses file_sd_configs so Prometheus discovers ECS EC2 targets dynamically
# without needing their private IPs at Terraform apply time.
cat > /opt/monitoring/prometheus/prometheus.yml << 'PROM_EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: '${cluster_name}'
    environment: '${environment}'

rule_files:
  - /etc/prometheus/alert_rules.yml

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: node_exporter
    file_sd_configs:
      - files: ['/etc/prometheus/targets/ecs_nodes.json']
        refresh_interval: 5m
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
PROM_EOF

# ── Write Prometheus alert rules ─────────────────────────────────────────────
cat > /opt/monitoring/prometheus/alert_rules.yml << 'RULES_EOF'
groups:
  - name: host_alerts
    rules:
      - alert: DiskAlmostFull
        expr: node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} < 0.15
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Disk > 85% full on {{ $labels.instance }}"

      - alert: HighMemory
        expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.20
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Memory < 20% free on {{ $labels.instance }}"

      - alert: NodeDown
        expr: up{job="node_exporter"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Node Exporter unreachable: {{ $labels.instance }}"
RULES_EOF

# ── Write ECS node discovery script ──────────────────────────────────────────
# Queries AWS for running EC2 instances managed by ECS and writes a Prometheus
# file_sd JSON so Prometheus can scrape Node Exporter on port 9100.
cat > /opt/monitoring/scripts/discover_ecs_nodes.sh << 'DISCOVER_EOF'
#!/bin/bash
set -euo pipefail
REGION="${aws_region}"
CLUSTER="${cluster_name}"
OUTPUT_FILE="/opt/monitoring/prometheus/targets/ecs_nodes.json"

INSTANCE_IPS=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:AmazonECSManaged,Values=true" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].PrivateIpAddress" \
  --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true)

if [ -z "$INSTANCE_IPS" ]; then
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

TARGETS="["
FIRST=true
for IP in $INSTANCE_IPS; do
  if [ "$FIRST" = true ]; then
    FIRST=false
  else
    TARGETS="$TARGETS,"
  fi
  TARGETS="$TARGETS\"$IP:9100\""
done
TARGETS="$TARGETS]"

echo "[{\"targets\": $TARGETS, \"labels\": {\"cluster\": \"$CLUSTER\", \"job\": \"node_exporter\"}}]" > "$OUTPUT_FILE"
DISCOVER_EOF

chmod +x /opt/monitoring/scripts/discover_ecs_nodes.sh

# ── Write Grafana datasource provisioning ────────────────────────────────────
cat > /opt/monitoring/grafana/provisioning/datasources/datasources.yaml << 'DS_EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    url: http://prometheus:9090
    isDefault: true
    editable: true

  - name: CloudWatch
    type: cloudwatch
    jsonData:
      defaultRegion: ${aws_region}
      authType: default
    editable: true
DS_EOF

# ── Write Grafana dashboard provisioning config ───────────────────────────────
cat > /opt/monitoring/grafana/provisioning/dashboards/dashboards.yaml << 'DASH_EOF'
apiVersion: 1
providers:
  - name: default
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /etc/grafana/dashboards
DASH_EOF

mkdir -p /opt/monitoring/grafana/dashboards

# ── Deploy Grafana dashboard JSON ─────────────────────────────────────────────
aws s3 cp "s3://${monitoring_assets_bucket}/grafana/wordpress-overview.json" \
  /opt/monitoring/grafana/dashboards/wordpress-overview.json \
  --region ${aws_region} || { echo "ERROR: Failed to download Grafana dashboard from S3"; exit 1; }

# ── Write docker-compose.yml ──────────────────────────────────────────────────
cat > /opt/monitoring/docker-compose.yml << COMPOSE_EOF
services:
  prometheus:
    image: prom/prometheus:v2.52.0
    container_name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - /opt/monitoring/prometheus:/etc/prometheus
      - /opt/monitoring/prometheus/data:/prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.retention.time=15d
      - --storage.tsdb.path=/prometheus
      - --web.enable-lifecycle
      - --web.enable-admin-api
    restart: unless-stopped

  grafana:
    image: grafana/grafana:10.4.2
    container_name: grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${grafana_admin_password}
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SERVER_ROOT_URL=http://localhost/grafana
      - GF_SERVER_SERVE_FROM_SUB_PATH=true
      - GF_INSTALL_PLUGINS=grafana-piechart-panel
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_AUTH_ANONYMOUS_ENABLED=false
    volumes:
      - /opt/monitoring/grafana/provisioning:/etc/grafana/provisioning
      - /opt/monitoring/grafana/dashboards:/etc/grafana/dashboards
      - grafana_data:/var/lib/grafana
    depends_on:
      - prometheus
    restart: unless-stopped

volumes:
  grafana_data:
COMPOSE_EOF

# ── Set up cron for ECS node discovery ───────────────────────────────────────
# Run immediately once to pre-populate targets. Use || true so a discovery
# failure (no tagged instances yet) does not abort the bootstrap script.
/opt/monitoring/scripts/discover_ecs_nodes.sh || true

# Schedule every 5 minutes for dynamic target updates
(crontab -l 2>/dev/null || true; echo "*/5 * * * * /opt/monitoring/scripts/discover_ecs_nodes.sh >> /var/log/ecs-discover.log 2>&1") | crontab -

# ── Deploy daily reliability report script ────────────────────────────────────
aws s3 cp "s3://${monitoring_assets_bucket}/scripts/daily-reliability-report.py" \
  /opt/monitoring/scripts/daily-reliability-report.py \
  --region ${aws_region} || { echo "ERROR: Failed to download daily report script from S3"; exit 1; }
chmod +x /opt/monitoring/scripts/daily-reliability-report.py

# Schedule daily at 06:00 UTC
# Reports are published to SNS topic — email subscribers receive them automatically
(crontab -l 2>/dev/null || true; echo "0 6 * * * /usr/bin/python3 /opt/monitoring/scripts/daily-reliability-report.py --cluster ${cluster_name} --rds-identifier ${rds_identifier} --alb-arn-suffix ${alb_arn_suffix} --tg-arn-suffix ${tg_arn_suffix} --sns-topic-arn ${sns_topic_arn} --region ${aws_region} >> /var/log/daily-report.log 2>&1") | crontab -

# ── Create systemd service so Docker Compose starts after cloud-init exits ────
# Running docker compose up -d directly in user_data blocks on image pulls and
# causes cloud-init to time out on a t2.micro. The systemd unit starts after
# docker.service is ready, pulling images in the background on first boot.
cat > /etc/systemd/system/monitoring-stack.service << 'SYSTEMD_EOF'
[Unit]
Description=Prometheus + Grafana monitoring stack
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/monitoring
ExecStart=/usr/bin/docker compose -f /opt/monitoring/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f /opt/monitoring/docker-compose.yml down
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

systemctl daemon-reload
systemctl enable monitoring-stack
systemctl start monitoring-stack

echo "Monitoring stack service started at $(date)" >> /var/log/monitoring-bootstrap.log
