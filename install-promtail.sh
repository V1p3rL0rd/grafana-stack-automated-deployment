#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- CONFIGURATION ---
LOKI_SERVER_IP="YOUR_CENTRAL_LOKI_IP" # <-- Specify your central Loki server IP here
PROMT_VERSION="2.9.8"
CURRENT_HOSTNAME=$(hostname)

echo ">>> 1. Installing dependencies (unzip)..."
apt update && apt install -y unzip

echo ">>> 2. Downloading and installing Promtail v${PROMT_VERSION}..."
rm -f promtail-linux-amd64.zip promtail-linux-amd64
curl -fSL -o promtail-linux-amd64.zip "https://github.com/grafana/loki/releases/download/v${PROMT_VERSION}/promtail-linux-amd64.zip"

unzip promtail-linux-amd64.zip
mv promtail-linux-amd64 /usr/local/bin/promtail
chmod +x /usr/local/bin/promtail
rm promtail-linux-amd64.zip

echo ">>> 3. Creating configuration for host: ${CURRENT_HOSTNAME}..."
mkdir -p /etc/promtail

cat << EOF > /etc/promtail/promtail-config.yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://${LOKI_SERVER_IP}:3100/loki/api/v1/push

scrape_configs:
  - job_name: system-logs
    static_configs:
      - targets:
          - localhost
        labels:
          job: varlogs
          host: ${CURRENT_HOSTNAME}
          __path__: /var/log/*.log

  - job_name: auth-logs
    static_configs:
      - targets:
          - localhost
        labels:
          job: auth
          host: ${CURRENT_HOSTNAME}
          __path__: /var/log/auth.log

  - job_name: journal
    journal:
      max_age: 12h
      path: /var/log/journal
      labels:
        job: systemd-journal
        host: ${CURRENT_HOSTNAME}
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: 'unit'
      - source_labels: ['__journal_priority_keyword']
        target_label: 'level'
EOF

echo ">>> 4. Configuring and starting the systemd service..."
cat << 'EOF' > /etc/systemd/system/promtail.service
[Unit]
Description=Promtail service for log shipping
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/promtail-config.yaml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now promtail

echo ">>> Done! Service status:"
systemctl status promtail --no-pager
