#!/usr/bin/env bash
###############################################################################
# deploy-observability-stack.sh
#
# Universal deployment of the observability stack on Ubuntu 24.04 LTS:
#   - Prometheus
#   - Alertmanager
#   - Blackbox Exporter (including HTTPS probing with self-signed certificates)
#   - Node Exporter
#   - Postgres Exporter
#   - Loki
#   - Grafana (with datasource auto-provisioning)
#
# All services are deployed via docker-compose (docker compose plugin).
#
# Usage:
#   sudo bash deploy-observability-stack.sh
#
# Re-running is safe (idempotent): the existing .env file is not overwritten,
# configurations are recreated, and data is stored in named Docker volumes
# without being lost.
###############################################################################

set -euo pipefail

# ----------------------------------------------------------------------------
# 0. Basic Settings / Variables
# ----------------------------------------------------------------------------

BASE_DIR="/opt/observability"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
ENV_FILE="${BASE_DIR}/.env"

# Image versions (pinned for predictability and stack stability)
PROMETHEUS_VERSION="v2.53.0"
ALERTMANAGER_VERSION="v0.27.0"
BLACKBOX_VERSION="v0.25.0"
NODE_EXPORTER_VERSION="v1.8.2"
POSTGRES_EXPORTER_VERSION="v0.15.0"
LOKI_VERSION="2.9.8"
GRAFANA_VERSION="11.1.0"

# Externally published ports (can be changed via .env before startup)
GRAFANA_PORT_DEFAULT=3000
PROMETHEUS_PORT_DEFAULT=9090
ALERTMANAGER_PORT_DEFAULT=9093
BLACKBOX_PORT_DEFAULT=9115
NODE_EXPORTER_PORT_DEFAULT=9100
POSTGRES_EXPORTER_PORT_DEFAULT=9187
LOKI_PORT_DEFAULT=3100

# ----------------------------------------------------------------------------
# Logging Utilities
# ----------------------------------------------------------------------------

c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_reset='\033[0m'
log()  { echo -e "${c_green}[INFO]${c_reset} $*"; }
warn() { echo -e "${c_yellow}[WARN]${c_reset} $*"; }
err()  { echo -e "${c_red}[ERROR]${c_reset} $*" >&2; }
die()  { err "$*"; exit 1; }

# ----------------------------------------------------------------------------
# 1. Environment Checks
# ----------------------------------------------------------------------------

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo). Example: sudo bash $0"
    fi
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        if [[ "${ID:-}" != "ubuntu" ]]; then
            warn "Detected OS '${ID:-unknown}'; this script is designed for Ubuntu 24.04 LTS. Proceeding at your own risk..."
        elif [[ "${VERSION_ID:-}" != "24.04" ]]; then
            warn "Detected Ubuntu ${VERSION_ID:-unknown}; this script is tested on 24.04. Proceeding..."
        else
            log "Ubuntu 24.04 LTS confirmed."
        fi
    else
        warn "Could not determine OS (/etc/os-release is missing). Proceeding..."
    fi
}

# ----------------------------------------------------------------------------
# 2. Docker + Docker Compose Plugin Installation
# ----------------------------------------------------------------------------

install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        log "Docker and Docker Compose plugin are already installed: $(docker --version)"
        return 0
    fi

    log "Installing Docker and Docker Compose from standard Ubuntu repositories (docker.io + docker-compose-v2)..."

    # On some Ubuntu 24.04 builds, the command-not-found (cnf-update-db) hook,
    # which apt triggers after a successful update/install, fails with a Segmentation fault.
    # The apt operation itself completes successfully, but due to the non-zero exit code
    # of the hook, apt-get returns an error, causing the script to fail under set -e.
    # We disable this hook as it is unnecessary for headless automation.
    if [[ ! -f /etc/apt/apt.conf.d/99-disable-post-invoke-hooks ]]; then
        cat <<'EOF' > /etc/apt/apt.conf.d/99-disable-post-invoke-hooks
#clear APT::Update::Post-Invoke-Success;
EOF
        log "Disabled the command-not-found apt post-invoke hook (known segfault on Ubuntu 24.04)."
    fi

    apt-get update -y
    # docker.io — Docker Engine from Ubuntu repositories (universe)
    # docker-compose-v2 — "docker compose" plugin (v2) from Ubuntu repositories
    apt-get install -y docker.io docker-compose-v2

    systemctl enable --now docker

    # Add the user who invoked sudo to the docker group (if applicable)
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        usermod -aG docker "${SUDO_USER}" || true
        log "User '${SUDO_USER}' added to the docker group (re-login to apply changes)."
    fi

    log "Docker installed: $(docker --version)"
    log "Docker Compose plugin: $(docker compose version)"
}

# ----------------------------------------------------------------------------
# 3. Host IP Detection (for node-exporter, which runs in the host network)
# ----------------------------------------------------------------------------

detect_host_ip() {
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ -z "${ip}" ]]; then
        ip="127.0.0.1"
        warn "Could not automatically detect host IP, using 127.0.0.1. Please fix manually in ${BASE_DIR}/prometheus/prometheus.yml"
    fi
    echo "${ip}"
}

# ----------------------------------------------------------------------------
# 4. Directory Structure Creation
# ----------------------------------------------------------------------------

create_dirs() {
    log "Creating directory structure in ${BASE_DIR}..."
    mkdir -p \
        "${BASE_DIR}/prometheus" \
        "${BASE_DIR}/alertmanager" \
        "${BASE_DIR}/blackbox" \
        "${BASE_DIR}/loki" \
        "${BASE_DIR}/grafana/provisioning/datasources" \
        "${BASE_DIR}/grafana/provisioning/dashboards" \
        "${BASE_DIR}/grafana/dashboards"
}

# ----------------------------------------------------------------------------
# 5. .env Generation (created once, not overwritten afterwards)
# ----------------------------------------------------------------------------

# Adds a variable to the existing .env if it doesn't exist yet (leaves existing values untouched)
ensure_env_var() {
    local key="$1" default_value="$2" comment="${3:-}"
    if ! grep -qE "^${key}=" "${ENV_FILE}" 2>/dev/null; then
        [[ -n "$comment" ]] && echo -e "\n${comment}" >> "${ENV_FILE}"
        echo "${key}=${default_value}" >> "${ENV_FILE}"
        log "Added new variable to ${ENV_FILE}: ${key}"
    fi
}

generate_env() {
    if [[ -f "${ENV_FILE}" ]]; then
        log ".env already exists, supplementing with missing variables (existing values untouched): ${ENV_FILE}"
        ensure_env_var "TELEGRAM_BOT_TOKEN" "CHANGE_ME_telegram_bot_token" \
            "# --- Alertmanager: Telegram notifications (added during upgrade) ---"
        ensure_env_var "TELEGRAM_CHAT_ID" "CHANGE_ME_telegram_chat_id"
        # shellcheck disable=SC1090
        source "${ENV_FILE}"
        return 0
    fi

    log "Generating ${ENV_FILE}..."

    local host_ip grafana_admin_pass pg_exporter_pass
    host_ip="$(detect_host_ip)"
    grafana_admin_pass="$(openssl rand -base64 18 | tr -d '=+/' | cut -c1-20)"
    pg_exporter_pass="CHANGE_ME_password"

    cat <<EOF > "${ENV_FILE}"
###############################################################################
# Observability stack configuration. Edit to suit your environment.
###############################################################################

# --- Ports published on the host ---
GRAFANA_PORT=${GRAFANA_PORT_DEFAULT}
PROMETHEUS_PORT=${PROMETHEUS_PORT_DEFAULT}
ALERTMANAGER_PORT=${ALERTMANAGER_PORT_DEFAULT}
BLACKBOX_PORT=${BLACKBOX_PORT_DEFAULT}
NODE_EXPORTER_PORT=${NODE_EXPORTER_PORT_DEFAULT}
POSTGRES_EXPORTER_PORT=${POSTGRES_EXPORTER_PORT_DEFAULT}
LOKI_PORT=${LOKI_PORT_DEFAULT}

# --- Host IP where the stack runs (needed by node-exporter because it uses the host network) ---
HOST_IP=${host_ip}

# --- Grafana ---
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=${grafana_admin_pass}

# --- Alertmanager: Telegram notifications ---
# 1) Create a bot via @BotFather and get TELEGRAM_BOT_TOKEN (format 123456:ABC-DEF...)
# 2) Find chat_id: add the bot to the desired chat/channel and open
#    https://api.telegram.org/bot<TOKEN>/getUpdates after sending any message to the chat,
#    or use @userinfobot / @getmyid_bot for private chats.
# 3) For channels, chat_id is typically negative (e.g., -1001234567890).
TELEGRAM_BOT_TOKEN=CHANGE_ME_telegram_bot_token
TELEGRAM_CHAT_ID=CHANGE_ME_telegram_chat_id

# --- Postgres Exporter: connection string to your DB ---
# REPLACE with your real host/port/database/user/password.
# The DB user must have at least pg_monitor privileges (PostgreSQL 10+):
#   CREATE USER postgres_exporter WITH PASSWORD 'strong_password';
#   GRANT pg_monitor TO postgres_exporter;
POSTGRES_EXPORTER_DSN=postgresql://postgres_exporter:${pg_exporter_pass}@192.168.1.50:5432/postgres?sslmode=disable

# --- Blackbox Exporter: comma-separated list of HTTP(S) targets to check ---
# Probed by default using the https_selfsigned module (allows self-signed certificates)
# and http_2xx for standard http. REPLACE with your actual addresses/sites.
BLACKBOX_TARGETS=https://192.168.1.10,https://192.168.1.20:8443,http://192.168.1.30:80

# --- List of node-exporter hosts, if you have multiple (comma-separated, host:port) ---
# Defaults to HOST_IP:9100 (the server itself). Add other hosts if necessary.
NODE_EXPORTER_TARGETS=${host_ip}:9100

# --- Prometheus data retention ---
PROMETHEUS_RETENTION=30d
EOF

    chmod 600 "${ENV_FILE}"
    log ".env file created. Generated Grafana admin password: ${grafana_admin_pass}"
    warn "MAKE SURE to edit POSTGRES_EXPORTER_DSN and BLACKBOX_TARGETS in ${ENV_FILE} to match your actual addresses, then re-run the script."
}

# ----------------------------------------------------------------------------
# 6. Prometheus Configuration Generation
# ----------------------------------------------------------------------------

generate_prometheus_config() {
    log "Generating prometheus.yml..."

    # shellcheck disable=SC1090
    source "${ENV_FILE}"

    # Build the YAML list of blackbox targets from BLACKBOX_TARGETS (comma-separated)
    local blackbox_targets_yaml=""
    IFS=',' read -ra _BB_ARR <<< "${BLACKBOX_TARGETS}"
    for t in "${_BB_ARR[@]}"; do
        t="$(echo "$t" | xargs)"  # trim
        [[ -z "$t" ]] && continue
        blackbox_targets_yaml+="          - ${t}"$'\n'
    done
    [[ -z "$blackbox_targets_yaml" ]] && blackbox_targets_yaml="          []"$'\n'
    blackbox_targets_yaml="${blackbox_targets_yaml%$'\n'}"

    # Build the YAML list of node-exporter targets
    local node_targets_yaml=""
    IFS=',' read -ra _NE_ARR <<< "${NODE_EXPORTER_TARGETS}"
    for t in "${_NE_ARR[@]}"; do
        t="$(echo "$t" | xargs)"
        [[ -z "$t" ]] && continue
        node_targets_yaml+="          - ${t}"$'\n'
    done
    [[ -z "$node_targets_yaml" ]] && node_targets_yaml="          []"$'\n'
    node_targets_yaml="${node_targets_yaml%$'\n'}"

    # List for ICMP (host/IP only, without :port) — based on NODE_EXPORTER_TARGETS
    local node_targets_hosts_only=""
    for t in "${_NE_ARR[@]}"; do
        t="$(echo "$t" | xargs)"
        [[ -z "$t" ]] && continue
        node_targets_hosts_only+="          - ${t%%:*}"$'\n'
    done
    [[ -z "$node_targets_hosts_only" ]] && node_targets_hosts_only="          []"$'\n'
    node_targets_hosts_only="${node_targets_hosts_only%$'\n'}"

    # Write the resulting file directly using a bash heredoc (without external interpreters —
    # resilient to platform issues such as python3 / system binary segfaults).
    cat <<EOF > "${BASE_DIR}/prometheus/prometheus.yml"
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager:9093

rule_files:
  - "/etc/prometheus/alert.rules.yml"

scrape_configs:

  # Prometheus itself
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  # Alertmanager
  - job_name: "alertmanager"
    static_configs:
      - targets: ["alertmanager:9093"]

  # Node Exporter (host metrics)
  - job_name: "node-exporter"
    static_configs:
      - targets:
${node_targets_yaml}

  # Postgres Exporter
  - job_name: "postgres-exporter"
    static_configs:
      - targets: ["postgres-exporter:9187"]

  # Loki (internal metrics)
  - job_name: "loki"
    static_configs:
      - targets: ["loki:3100"]

  # Blackbox Exporter: HTTP(S) targets, including those with self-signed certificates.
  # The https_selfsigned module is also safe for regular http:// targets — TLS settings
  # are simply not applied when the address scheme is not https. Therefore, a single job
  # is sufficient for all targets from BLACKBOX_TARGETS — a separate job for "strict"
  # HTTP would only duplicate metrics for the exact same target.
  - job_name: "blackbox-https-selfsigned"
    metrics_path: /probe
    params:
      module: [https_selfsigned]
    static_configs:
      - targets:
${blackbox_targets_yaml}
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter:9115

  # Blackbox Exporter: ICMP ping (requires cap_add: NET_RAW on the container)
  - job_name: "blackbox-icmp"
    metrics_path: /probe
    params:
      module: [icmp]
    static_configs:
      - targets:
${node_targets_hosts_only}
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter:9115
EOF

    # Empty alert rules file (can be populated with custom rules later)
    if [[ ! -f "${BASE_DIR}/prometheus/alert.rules.yml" ]]; then
        cat <<'EOF' > "${BASE_DIR}/prometheus/alert.rules.yml"
groups:
  - name: basic-alerts
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Instance {{ $labels.instance }} down"
          description: "{{ $labels.instance }} (job {{ $labels.job }}) has been unreachable for more than 2 minutes."

      - alert: HighNodeCPU
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage on {{ $labels.instance }}"
          description: "CPU usage exceeds 90% for more than 5 minutes."

      - alert: HighNodeMemory
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 90
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage on {{ $labels.instance }}"
          description: "Memory usage exceeds 90% for more than 5 minutes."

      - alert: BlackboxProbeFailed
        expr: probe_success == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Probe failed for {{ $labels.instance }}"
          description: "Blackbox probe for {{ $labels.instance }} has been failing for more than 2 minutes."
EOF
    fi
}

# ----------------------------------------------------------------------------
# 7. Alertmanager Configuration Generation
# ----------------------------------------------------------------------------

generate_alertmanager_config() {
    # shellcheck disable=SC1090
    source "${ENV_FILE}"

    # The chat_id in Alertmanager's Telegram config must be a valid number (can be negative
    # for channels/supergroups). If the token/chat_id are not yet set (placeholders) or chat_id is not a number —
    # generate a safe null-receiver so Alertmanager doesn't enter a crash loop due to an invalid config.
    local telegram_ready=true
    if [[ "${TELEGRAM_BOT_TOKEN}" == "CHANGE_ME_telegram_bot_token" || -z "${TELEGRAM_BOT_TOKEN}" ]]; then
        telegram_ready=false
    fi
    if [[ "${TELEGRAM_CHAT_ID}" == "CHANGE_ME_telegram_chat_id" || -z "${TELEGRAM_CHAT_ID}" ]]; then
        telegram_ready=false
    fi
    if ! [[ "${TELEGRAM_CHAT_ID}" =~ ^-?[0-9]+$ ]]; then
        telegram_ready=false
    fi

    if [[ "${telegram_ready}" == "true" ]]; then
        log "Generating alertmanager.yml (recipient: Telegram, chat_id=${TELEGRAM_CHAT_ID})..."
        cat <<EOF > "${BASE_DIR}/alertmanager/alertmanager.yml"
global:
  resolve_timeout: 5m

route:
  receiver: "telegram-default"
  group_by: ["alertname", "instance"]
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h

receivers:
  - name: "telegram-default"
    telegram_configs:
      - bot_token: "${TELEGRAM_BOT_TOKEN}"
        chat_id: ${TELEGRAM_CHAT_ID}
        parse_mode: "HTML"
        send_resolved: true
        message: |
          {{- if eq .Status "firing" -}}
          🚨 <b>[ISSUE] {{ .CommonLabels.alertname }}</b>
          {{- else -}}
          ✅ <b>[RESOLVED] {{ .CommonLabels.alertname }}</b>
          {{- end }}
          {{ range .Alerts }}
          <b>Node:</b> {{ .Labels.instance | html }}
          <b>Job:</b> {{ .Labels.job | html }}
          <b>Severity:</b> {{ .Labels.severity | html }}
          <b>Description:</b> {{ .Annotations.description | html }}
          <b>Change Time:</b> {{ (.StartsAt.Add 10800000000000).Format "2006-01-02 15:04:05" }} MSK
          {{ end }}

inhibit_rules:
  - source_match:
      severity: "critical"
    target_match:
      severity: "warning"
    equal: ["alertname", "instance"]
EOF
    else
        warn "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID are not set or are invalid in ${ENV_FILE}."
        warn "Generating alertmanager.yml with a null-receiver (alerts will accumulate but NOT be sent) to avoid a crash loop."
        warn "Once you fill in the variables, re-run the script — the config will switch to the actual Telegram receiver."
        cat <<'EOF' > "${BASE_DIR}/alertmanager/alertmanager.yml"
global:
  resolve_timeout: 5m

route:
  receiver: "null-receiver"
  group_by: ["alertname", "instance"]
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h

receivers:
  # FILL IN TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in .env and re-run the script —
  # the real Telegram receiver will be connected automatically.
  - name: "null-receiver"

inhibit_rules:
  - source_match:
      severity: "critical"
    target_match:
      severity: "warning"
    equal: ["alertname", "instance"]
EOF
    fi
}

# ----------------------------------------------------------------------------
# 8. Blackbox Exporter Configuration Generation (with self-signed TLS support)
# ----------------------------------------------------------------------------

generate_blackbox_config() {
    log "Generating blackbox.yml (with self-signed certificate module)..."
    cat <<'EOF' > "${BASE_DIR}/blackbox/blackbox.yml"
modules:

  # Standard HTTP(S) with certificate validation (for sites with proper CA certificates)
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: []   # defaults to 2xx
      method: GET
      preferred_ip_protocol: "ip4"
      tls_config:
        insecure_skip_verify: false

  # HTTPS with self-signed / untrusted certificates — TLS verification disabled
  https_selfsigned:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: []
      method: GET
      preferred_ip_protocol: "ip4"
      fail_if_ssl: false
      fail_if_not_ssl: false
      tls_config:
        insecure_skip_verify: true   # key setting for self-signed certificates

  # TCP port check
  tcp_connect:
    prober: tcp
    timeout: 5s

  # ICMP ping
  icmp:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: "ip4"

  # DNS check (example)
  dns_udp:
    prober: dns
    timeout: 5s
    dns:
      query_name: "example.com"
      query_type: "A"
      valid_rcodes:
        - NOERROR
EOF
}

# ----------------------------------------------------------------------------
# 9. Loki Configuration Generation
# ----------------------------------------------------------------------------

generate_loki_config() {
    log "Generating loki-config.yml..."
    cat <<'EOF' > "${BASE_DIR}/loki/loki-config.yml"
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096
  log_level: info

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100

schema_config:
  configs:
    - from: 2020-10-24
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: 720h
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  max_cache_freshness_per_query: 10m
  ingestion_rate_mb: 8
  ingestion_burst_size_mb: 16

compactor:
  working_directory: /loki/compactor
  compaction_interval: 10m
  retention_enabled: true
  retention_delete_delay: 2h
  compactor_ring:
    kvstore:
      store: inmemory

ruler:
  storage:
    type: local
    local:
      directory: /loki/rules
  rule_path: /loki/rules-temp
  alertmanager_url: http://alertmanager:9093
  ring:
    kvstore:
      store: inmemory
  enable_api: true
EOF
}

# ----------------------------------------------------------------------------
# 10. Grafana Datasource Provisioning Generation
# ----------------------------------------------------------------------------

generate_grafana_provisioning() {
    log "Generating Grafana provisioning datasources..."
    cat <<'EOF' > "${BASE_DIR}/grafana/provisioning/datasources/datasources.yml"
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true

  - name: Alertmanager
    type: alertmanager
    access: proxy
    url: http://alertmanager:9093
    jsonData:
      implementation: prometheus
    editable: true

  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    editable: true
EOF

    cat <<'EOF' > "${BASE_DIR}/grafana/provisioning/dashboards/dashboards.yml"
apiVersion: 1

providers:
  - name: "default"
    orgId: 1
    folder: ""
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
EOF
}

# ----------------------------------------------------------------------------
# 11. docker-compose.yml Generation
# ----------------------------------------------------------------------------

generate_compose_file() {
    log "Generating docker-compose.yml..."
    cat <<EOF > "${COMPOSE_FILE}"
name: observability

networks:
  monitoring:
    driver: bridge

volumes:
  prometheus_data:
  alertmanager_data:
  loki_data:
  grafana_data:

services:

  prometheus:
    image: prom/prometheus:${PROMETHEUS_VERSION}
    container_name: prometheus
    restart: unless-stopped
    user: root
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/alert.rules.yml:/etc/prometheus/alert.rules.yml:ro
      - prometheus_data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=\${PROMETHEUS_RETENTION}"
      - "--web.enable-lifecycle"
    ports:
      - "\${PROMETHEUS_PORT}:9090"
    networks:
      - monitoring

  alertmanager:
    image: prom/alertmanager:${ALERTMANAGER_VERSION}
    container_name: alertmanager
    restart: unless-stopped
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - alertmanager_data:/alertmanager
    command:
      - "--config.file=/etc/alertmanager/alertmanager.yml"
      - "--storage.path=/alertmanager"
    ports:
      - "\${ALERTMANAGER_PORT}:9093"
    networks:
      - monitoring

  blackbox-exporter:
    image: prom/blackbox-exporter:${BLACKBOX_VERSION}
    container_name: blackbox-exporter
    restart: unless-stopped
    cap_add:
      - NET_RAW
    volumes:
      - ./blackbox/blackbox.yml:/etc/blackbox_exporter/config.yml:ro
    command:
      - "--config.file=/etc/blackbox_exporter/config.yml"
    ports:
      - "\${BLACKBOX_PORT}:9115"
    networks:
      - monitoring

  node-exporter:
    image: prom/node-exporter:${NODE_EXPORTER_VERSION}
    container_name: node-exporter
    restart: unless-stopped
    pid: host
    network_mode: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - "--path.procfs=/host/proc"
      - "--path.sysfs=/host/sys"
      - "--path.rootfs=/rootfs"
      - "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)(\$\$|/)"
      - "--web.listen-address=:\${NODE_EXPORTER_PORT}"

  postgres-exporter:
    image: prometheuscommunity/postgres-exporter:${POSTGRES_EXPORTER_VERSION}
    container_name: postgres-exporter
    restart: unless-stopped
    environment:
      DATA_SOURCE_NAME: "\${POSTGRES_EXPORTER_DSN}"
    ports:
      - "\${POSTGRES_EXPORTER_PORT}:9187"
    networks:
      - monitoring

  loki:
    image: grafana/loki:${LOKI_VERSION}
    container_name: loki
    restart: unless-stopped
    volumes:
      - ./loki/loki-config.yml:/etc/loki/local-config.yaml:ro
      - loki_data:/loki
    command:
      - "-config.file=/etc/loki/local-config.yaml"
    ports:
      - "\${LOKI_PORT}:3100"
    networks:
      - monitoring

  grafana:
    image: grafana/grafana:${GRAFANA_VERSION}
    container_name: grafana
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_USER: "\${GF_SECURITY_ADMIN_USER}"
      GF_SECURITY_ADMIN_PASSWORD: "\${GF_SECURITY_ADMIN_PASSWORD}"
      GF_USERS_ALLOW_SIGN_UP: "false"
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
    ports:
      - "\${GRAFANA_PORT}:3000"
    networks:
      - monitoring
    depends_on:
      - prometheus
      - loki
      - alertmanager
EOF
}

# ----------------------------------------------------------------------------
# 12. Deployment
# ----------------------------------------------------------------------------

deploy_stack() {
    log "Checking docker-compose.yml syntax..."
    (cd "${BASE_DIR}" && docker compose config -q) \
        || die "Error in docker-compose.yml, see output above."

    log "Starting the stack via docker compose (pull + up -d)..."
    (cd "${BASE_DIR}" && docker compose pull)
    (cd "${BASE_DIR}" && docker compose up -d)

    # IMPORTANT: docker compose up -d does NOT recreate or restart an already running
    # container if its service definition in docker-compose.yml hasn't changed (image,
    # ports, environment variables). Docker compose does not track changes to the CONTENT
    # of files mounted as volumes (prometheus.yml, alertmanager.yml, blackbox.yml, loki-config.yml,
    # grafana provisioning) — they are simply files on disk. Furthermore, these services
    # only read their configuration when the process starts, with no hot-reload by default.
    # Therefore, after every configuration regeneration, you must explicitly restart the
    # containers that read them; otherwise, they will continue running with the old configuration
    # from memory, even though the disk has been updated long ago.
    log "Restarting services that read config files to apply current settings..."
    (cd "${BASE_DIR}" && docker compose restart prometheus alertmanager blackbox-exporter loki grafana)

    log "Stack started. Waiting 10 seconds before checking status..."
    sleep 10
    (cd "${BASE_DIR}" && docker compose ps)
}

# ----------------------------------------------------------------------------
# 13. Service Health Check
# ----------------------------------------------------------------------------

health_check() {
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    log "Checking service availability..."

    local endpoints=(
        "Prometheus|http://localhost:${PROMETHEUS_PORT}/-/healthy"
        "Alertmanager|http://localhost:${ALERTMANAGER_PORT}/-/healthy"
        "Grafana|http://localhost:${GRAFANA_PORT}/api/health"
        "Loki|http://localhost:${LOKI_PORT}/ready"
        "Blackbox Exporter|http://localhost:${BLACKBOX_PORT}/-/healthy"
        "Node Exporter|http://${HOST_IP}:${NODE_EXPORTER_PORT}/metrics"
        "Postgres Exporter|http://localhost:${POSTGRES_EXPORTER_PORT}/metrics"
    )

    for entry in "${endpoints[@]}"; do
        local name="${entry%%|*}"
        local url="${entry##*|}"
        if curl -fsS --max-time 5 "$url" -o /dev/null 2>/dev/null; then
            echo -e "  ${c_green}OK${c_reset}   ${name} (${url})"
        else
            echo -e "  ${c_red}FAIL${c_reset} ${name} (${url})"
        fi
    done
}

# ----------------------------------------------------------------------------
# 14. Final Summary
# ----------------------------------------------------------------------------

print_summary() {
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    local ip; ip="${HOST_IP}"

    cat <<EOF

===============================================================================
 Observability stack deployed.
===============================================================================
 Stack directory:    ${BASE_DIR}
 Environment file:   ${ENV_FILE}
 Compose file:       ${COMPOSE_FILE}

 Service Access:
    Grafana:            http://${ip}:${GRAFANA_PORT}
                        login: ${GF_SECURITY_ADMIN_USER} / password: ${GF_SECURITY_ADMIN_PASSWORD}
    Prometheus:         http://${ip}:${PROMETHEUS_PORT}
    Alertmanager:       http://${ip}:${ALERTMANAGER_PORT}
    Blackbox Exporter:  http://${ip}:${BLACKBOX_PORT}
    Node Exporter:      http://${ip}:${NODE_EXPORTER_PORT}/metrics
    Postgres Exporter:  http://${ip}:${POSTGRES_EXPORTER_PORT}/metrics
    Loki:               http://${ip}:${LOKI_PORT}

 IMPORTANT — make sure to edit before production use:
    1) ${ENV_FILE}
        - POSTGRES_EXPORTER_DSN    -> real connection string to your DB
        - BLACKBOX_TARGETS         -> real websites/hosts to check
        - NODE_EXPORTER_TARGETS    -> additional hosts, if any
    2) ${BASE_DIR}/alertmanager/alertmanager.yml
        - configure a real notification channel (email/telegram/slack/webhook)

    After editing .env, re-run the script (it is idempotent) or execute:
      cd ${BASE_DIR} && docker compose up -d --force-recreate prometheus postgres-exporter

 Self-signed certificates:
    For HTTPS targets with self-signed certificates, Blackbox uses the
    "https_selfsigned" module (tls_config.insecure_skip_verify: true), configured
    in ${BASE_DIR}/blackbox/blackbox.yml and already included in prometheus.yml
    as the "blackbox-https-selfsigned" job.

 Useful commands:
    Logs:       cd ${BASE_DIR} && docker compose logs -f [service]
    Status:     cd ${BASE_DIR} && docker compose ps
    Stop:       cd ${BASE_DIR} && docker compose down
    Update:     cd ${BASE_DIR} && docker compose pull && docker compose up -d
===============================================================================
EOF
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    check_root
    check_os
    install_docker
    create_dirs
    generate_env
    generate_prometheus_config
    generate_alertmanager_config
    generate_blackbox_config
    generate_loki_config
    generate_grafana_provisioning
    generate_compose_file
    deploy_stack
    health_check
    print_summary
}

main "$@"
