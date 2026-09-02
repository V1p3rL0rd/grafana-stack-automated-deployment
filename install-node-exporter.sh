#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- CONFIGURATION ---
# Use the latest stable version or specify the required one
NODE_EXP_VERSION="1.8.2"
CURRENT_HOSTNAME=$(hostname)

echo ">>> 1. Creating a dedicated system user for node_exporter..."
sudo useradd --no-create-home --shell /bin/false node_exporter || true

echo ">>> 2. Downloading and installing Node Exporter v${NODE_EXP_VERSION}..."
rm -f node_exporter-${NODE_EXP_VERSION}.linux-amd64.tar.gz
curl -fSL -o node_exporter-${NODE_EXP_VERSION}.linux-amd64.tar.gz "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXP_VERSION}/node_exporter-${NODE_EXP_VERSION}.linux-amd64.tar.gz"

tar xvf node_exporter-${NODE_EXP_VERSION}.linux-amd64.tar.gz
sudo cp node_exporter-${NODE_EXP_VERSION}.linux-amd64/node_exporter /usr/local/bin/
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

# Cleanup temporary files
rm -rf node_exporter-${NODE_EXP_VERSION}.linux-amd64.tar.gz node_exporter-${NODE_EXP_VERSION}.linux-amd64

echo ">>> 3. Configuring and starting the systemd service for host: ${CURRENT_HOSTNAME}..."
cat << 'EOF' > /etc/systemd/system/node_exporter.service
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
    --collector.filesystem.mount-points-exclude="^/(sys|proc|dev|host|etc)($$|/)"

Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter

echo ">>> Done! Node Exporter status:"
sudo systemctl status node_exporter --no-pager
