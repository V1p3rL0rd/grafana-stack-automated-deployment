#!/usr/bin/env bash
###############################################################################
# deploy-observability-stack.sh
#
# Universal deployment of an observability stack on Ubuntu 24.04 LTS:
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
# Re-running is safe (idempotent): an existing .env is not overwritten,
# configs are regenerated, data is kept in named docker volumes and is
# not lost.
###############################################################################

set -euo pipefail

# ----------------------------------------------------------------------------
# 0. Base settings / variables
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

# Ports published on the host (can be changed before running, via .env)
GRAFANA_PORT_DEFAULT=3000
PROMETHEUS_PORT_DEFAULT=9090
ALERTMANAGER_PORT_DEFAULT=9093
BLACKBOX_PORT_DEFAULT=9115
NODE_EXPORTER_PORT_DEFAULT=9100
POSTGRES_EXPORTER_PORT_DEFAULT=9187
LOKI_PORT_DEFAULT=3100

# ----------------------------------------------------------------------------
# Logging utilities
# ----------------------------------------------------------------------------

c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_reset='\033[0m'
log()  { echo -e "${c_green}[INFO]${c_reset} $*"; }
warn() { echo -e "${c_yellow}[WARN]${c_reset} $*"; }
err()  { echo -e "${c_red}[ERROR]${c_reset} $*" >&2; }
die()  { err "$*"; exit 1; }

# ----------------------------------------------------------------------------
# 1. Environment checks
# ----------------------------------------------------------------------------

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "The script must be run as root (use sudo). Example: sudo bash $0"
    fi
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        if [[ "${ID:-}" != "ubuntu" ]]; then
            warn "Detected OS '${ID:-unknown}', the script is designed for Ubuntu 24.04 LTS. Continuing at your own risk..."
        elif [[ "${VERSION_ID:-}" != "24.04" ]]; then
            warn "Detected Ubuntu ${VERSION_ID:-unknown}, the script is tested on 24.04. Continuing..."
        else
            log "Ubuntu 24.04 LTS verified."
        fi
    else
        warn "Could not determine OS (/etc/os-release missing). Continuing..."
    fi
}

# ----------------------------------------------------------------------------
# 2. Install Docker + docker compose plugin
# ----------------------------------------------------------------------------

install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        log "Docker and docker compose plugin are already installed: $(docker --version)"
        return 0
    fi

    log "Installing Docker and Docker Compose from standard Ubuntu repositories (docker.io + docker-compose-v2)..."

    # On some Ubuntu 24.04 builds, the command-not-found hook (cnf-update-db),
    # which apt triggers after a successful update/install, crashes with a
    # Segmentation fault. The apt operation itself completes fine, but the
    # hook's non-zero exit code makes apt-get return an error, which then
    # kills the script under set -e. Disable the hook — it's not needed for
    # headless automation anyway.
    if [[ ! -f /etc/apt/apt.conf.d/99-disable-post-invoke-hooks ]]; then
        cat <<'EOF' > /etc/apt/apt.conf.d/99-disable-post-invoke-hooks
#clear APT::Update::Post-Invoke-Success;
EOF
        log "Disabled the command-not-found apt post-invoke hook (known segfault on Ubuntu 24.04)."
    fi

    apt-get update -y
    # docker.io          — Docker Engine from Ubuntu's repositories (universe)
    # docker-compose-v2  — the "docker compose" (v2) plugin from Ubuntu's repositories
    apt-get install -y docker.io docker-compose-v2

    systemctl enable --now docker

    # Add the user who invoked sudo to the docker group (if applicable)
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        usermod -aG docker "${SUDO_USER}" || true
        log "User '${SUDO_USER}' added to the docker group (re-login to apply)."
    fi

    log "Docker installed: $(docker --version)"
    log "Docker Compose plugin: $(docker compose version)"
}

# ----------------------------------------------------------------------------
# 3. Detect the host IP (needed by node-exporter, which runs in host network mode)
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
# 4. Create directory structure
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
        "${BASE_DIR}/grafana/dashboards" \
        "${BASE_DIR}/grafana/tls"
}

# ----------------------------------------------------------------------------
# 5. Generate .env (created once, not overwritten afterwards)
# ----------------------------------------------------------------------------

# Adds a variable to an existing .env if it isn't there yet (does not touch already-set values)
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
        log ".env already exists, supplementing with missing variables (leaving existing values untouched): ${ENV_FILE}"
        ensure_env_var "TELEGRAM_BOT_TOKEN" "CHANGE_ME_telegram_bot_token" \
            "# --- Alertmanager: Telegram notifications (added during upgrade) ---"
        ensure_env_var "TELEGRAM_CHAT_ID" "CHANGE_ME_telegram_chat_id"
        ensure_env_var "BLACKBOX_ICMP_TARGETS" "" \
            "# --- Blackbox Exporter: separate ICMP ping target list (added during upgrade) ---
# Comma-separated, host/IP only, no :port. Independent from NODE_EXPORTER_TARGETS
# and BLACKBOX_TARGETS. Empty = ICMP probing disabled."
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
# Observability stack configuration. Edit to match your environment.
###############################################################################

# --- Ports published on the host ---
GRAFANA_PORT=${GRAFANA_PORT_DEFAULT}
PROMETHEUS_PORT=${PROMETHEUS_PORT_DEFAULT}
ALERTMANAGER_PORT=${ALERTMANAGER_PORT_DEFAULT}
BLACKBOX_PORT=${BLACKBOX_PORT_DEFAULT}
NODE_EXPORTER_PORT=${NODE_EXPORTER_PORT_DEFAULT}
POSTGRES_EXPORTER_PORT=${POSTGRES_EXPORTER_PORT_DEFAULT}
LOKI_PORT=${LOKI_PORT_DEFAULT}

# --- Host IP the stack runs on (needed by node-exporter, since it runs in host network mode) ---
HOST_IP=${host_ip}

# --- Grafana ---
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=${grafana_admin_pass}

# --- Alertmanager: Telegram notifications ---
# 1) Create a bot via @BotFather, get TELEGRAM_BOT_TOKEN (looks like 123456:ABC-DEF...)
# 2) Find the chat_id: add the bot to the target chat/channel and open
#    https://api.telegram.org/bot<TOKEN>/getUpdates after sending any message to the chat,
#    or use @userinfobot / @getmyid_bot for personal chats.
# 3) For a channel, chat_id is usually negative (e.g. -1001234567890).
TELEGRAM_BOT_TOKEN=CHANGE_ME_telegram_bot_token
TELEGRAM_CHAT_ID=CHANGE_ME_telegram_chat_id

# --- Postgres Exporter: connection string to your database ---
# REPLACE with the real host/port/database/user/password.
# The DB user needs at least pg_monitor privileges (PostgreSQL 10+):
#   CREATE USER postgres_exporter WITH PASSWORD 'strong_password';
#   GRANT pg_monitor TO postgres_exporter;
POSTGRES_EXPORTER_DSN=postgresql://postgres_exporter:${pg_exporter_pass}@192.168.1.50:5432/postgres?sslmode=disable

# --- Blackbox Exporter: comma-separated list of HTTP(S) targets to check ---
# Probed with the https_selfsigned module (allows self-signed certificates;
# TLS settings simply don't apply to plain http://). REPLACE with your real
# addresses/sites.
BLACKBOX_TARGETS=https://192.168.1.10,https://192.168.1.20:8443,http://192.168.1.30:80

# --- List of node-exporter hosts, if you have more than one (comma-separated, host:port) ---
# Defaults to HOST_IP:9100 (this server). Add more hosts if needed.
NODE_EXPORTER_TARGETS=${host_ip}:9100

# --- Blackbox Exporter: separate list of ICMP ping targets (comma-separated, host/IP only, no :port) ---
# Independent from NODE_EXPORTER_TARGETS and BLACKBOX_TARGETS — leave empty
# if ICMP probing isn't needed at all.
BLACKBOX_ICMP_TARGETS=

# --- Prometheus data retention ---
PROMETHEUS_RETENTION=30d
EOF

    chmod 600 "${ENV_FILE}"
    log ".env file created. Generated Grafana admin password: ${grafana_admin_pass}"
    warn "BE SURE to edit POSTGRES_EXPORTER_DSN and BLACKBOX_TARGETS in ${ENV_FILE} to match your real addresses, then re-run the script."
}

# ----------------------------------------------------------------------------
# 6. Generate Prometheus configuration
# ----------------------------------------------------------------------------

generate_prometheus_config() {
    log "Generating prometheus.yml..."

    # shellcheck disable=SC1090
    source "${ENV_FILE}"

    # Build the YAML target list for blackbox from BLACKBOX_TARGETS (comma-separated)
    local blackbox_targets_yaml=""
    IFS=',' read -ra _BB_ARR <<< "${BLACKBOX_TARGETS}"
    for t in "${_BB_ARR[@]}"; do
        t="$(echo "$t" | xargs)"  # trim
        [[ -z "$t" ]] && continue
        blackbox_targets_yaml+="          - ${t}"$'\n'
    done
    [[ -z "$blackbox_targets_yaml" ]] && blackbox_targets_yaml="          []"$'\n'
    blackbox_targets_yaml="${blackbox_targets_yaml%$'\n'}"

    # Build the YAML target list for node-exporter
    local node_targets_yaml=""
    IFS=',' read -ra _NE_ARR <<< "${NODE_EXPORTER_TARGETS}"
    for t in "${_NE_ARR[@]}"; do
        t="$(echo "$t" | xargs)"
        [[ -z "$t" ]] && continue
        node_targets_yaml+="          - ${t}"$'\n'
    done
    [[ -z "$node_targets_yaml" ]] && node_targets_yaml="          []"$'\n'
    node_targets_yaml="${node_targets_yaml%$'\n'}"

    # ICMP target list — from the separate BLACKBOX_ICMP_TARGETS variable, independent
    # of NODE_EXPORTER_TARGETS (host/IP without :port)
    local node_targets_hosts_only=""
    IFS=',' read -ra _ICMP_ARR <<< "${BLACKBOX_ICMP_TARGETS:-}"
    for t in "${_ICMP_ARR[@]}"; do
        t="$(echo "$t" | xargs)"
        [[ -z "$t" ]] && continue
        node_targets_hosts_only+="          - ${t%%:*}"$'\n'
    done
    [[ -z "$node_targets_hosts_only" ]] && node_targets_hosts_only="          []"$'\n'
    node_targets_hosts_only="${node_targets_hosts_only%$'\n'}"

    # Write the final file directly via a bash heredoc (no external interpreters —
    # resilient to platform issues like python3/system binary segfaults).
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

  # Loki (own metrics)
  - job_name: "loki"
    static_configs:
      - targets: ["loki:3100"]

  # Blackbox Exporter: HTTP(S) targets, including self-signed certificates.
  # The https_selfsigned module is also safe for plain http:// targets — TLS
  # settings simply don't apply when the scheme isn't https. So a single job
  # is enough for all targets in BLACKBOX_TARGETS — a separate "strict" HTTP
  # job would just duplicate metrics for the same target.
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

    # Empty alerting rules file (can be filled with your own rules later)
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
          description: "{{ $labels.instance }} (job {{ $labels.job }}) has been unavailable for more than 2 minutes."

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
          summary: "High memory consumption on {{ $labels.instance }}"
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
# 7. Generate Alertmanager configuration
# ----------------------------------------------------------------------------

generate_alertmanager_config() {
    # shellcheck disable=SC1090
    source "${ENV_FILE}"

    # chat_id in the Alertmanager Telegram config must be a valid number (can be
    # negative for channels/supergroups). If the token/chat_id aren't set yet
    # (placeholders) or chat_id isn't numeric — generate a safe null-receiver so
    # Alertmanager doesn't crash-loop on an invalid config.
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
        log "Generating alertmanager.yml (receiver: Telegram, chat_id=${TELEGRAM_CHAT_ID})..."
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
          🚨 <b>[PROBLEM] {{ .CommonLabels.alertname }}</b>
          {{- else -}}
          ✅ <b>[RESOLVED] {{ .CommonLabels.alertname }}</b>
          {{- end }}
          {{ range .Alerts }}
          <b>Node:</b> {{ .Labels.instance | html }}
          <b>Job:</b> {{ .Labels.job | html }}
          <b>Severity:</b> {{ .Labels.severity | html }}
          <b>Description:</b> {{ .Annotations.description | html }}
          <b>Modification Time:</b> {{ (.StartsAt.Add 10800000000000).Format "2006-01-02 15:04:05" }} MSK
          {{ end }}

inhibit_rules:
  - source_match:
      severity: "critical"
    target_match:
      severity: "warning"
    equal: ["alertname", "instance"]
EOF
    else
        warn "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID are not set or invalid in ${ENV_FILE}."
        warn "Generating alertmanager.yml with a null-receiver (alerts will accumulate but NOT be sent) to prevent a crash-loop."
        warn "After populating the variables, re-run the script — the config will switch to the real Telegram receiver."
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
  # FILL IN TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in .env and re-run the
  # script — it will automatically switch to a real Telegram receiver.
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
# 8. Generate Blackbox Exporter configuration (with self-signed TLS support)
# ----------------------------------------------------------------------------

generate_blackbox_config() {
    log "Generating blackbox.yml (with self-signed certificate module)..."
    cat <<'EOF' > "${BASE_DIR}/blackbox/blackbox.yml"
modules:

  # Regular HTTP(S) with certificate validation (for sites with proper CA certificates)
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: []   # 2xx by default
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
# 9. Generate Loki configuration
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
# 10. Generate a self-signed TLS certificate for Grafana
# ----------------------------------------------------------------------------

# Idempotent: if a certificate already exists, it is left untouched so that
# any browser exception you've already added for it stays valid across
# re-runs of the script. Delete grafana/tls/*.pem manually to force a
# regeneration (e.g. if HOST_IP changes).
generate_grafana_tls_cert() {
    # shellcheck disable=SC1090
    source "${ENV_FILE}"

    local cert_dir="${BASE_DIR}/grafana/tls"
    local cert_file="${cert_dir}/grafana.crt"
    local key_file="${cert_dir}/grafana.key"

    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        log "Grafana TLS certificate already exists, leaving untouched: ${cert_file}"
        return 0
    fi

    log "Generating self-signed TLS certificate for Grafana (CN=${HOST_IP})..."

    # 10-year self-signed cert with the host IP in both CN and SAN — modern
    # browsers require a Subject Alternative Name, a bare CN is not enough.
    openssl req -x509 -nodes -newkey rsa:4096 \
        -days 3650 \
        -keyout "$key_file" \
        -out "$cert_file" \
        -subj "/CN=${HOST_IP}" \
        -addext "subjectAltName=IP:${HOST_IP},DNS:localhost" \
        2>/dev/null

    # The official grafana/grafana image runs as uid:gid 472:472. Since this
    # is a bind mount (no user-namespace remap), the key must be readable by
    # that uid. chown to 472:472 with a tight mode; if that uid doesn't exist
    # on the host (chown by numeric id still works regardless) this simply
    # sets ownership by number, which is fine either way.
    chown 472:472 "$key_file" "$cert_file" 2>/dev/null || true
    chmod 640 "$key_file"
    chmod 644 "$cert_file"

    log "TLS certificate created: ${cert_file} (valid for 10 years)"
}

# ----------------------------------------------------------------------------
# 11. Generate Grafana datasource provisioning
# ----------------------------------------------------------------------------

generate_grafana_provisioning() {
    log "Generating provisioning datasources for Grafana..."
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
# 12. Generate docker-compose.yml
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
      # Self-signed TLS — see generate_grafana_tls_cert() in the deploy script
      GF_SERVER_PROTOCOL: "https"
      GF_SERVER_CERT_FILE: "/etc/grafana/tls/grafana.crt"
      GF_SERVER_CERT_KEY: "/etc/grafana/tls/grafana.key"
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
      - ./grafana/tls:/etc/grafana/tls:ro
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
# 13. Deployment
# ----------------------------------------------------------------------------

deploy_stack() {
    log "Checking docker-compose.yml syntax..."
    (cd "${BASE_DIR}" && docker compose config -q) \
        || die "Error in docker-compose.yml, see output above."

    log "Starting stack via docker compose (pull + up -d)..."
    (cd "${BASE_DIR}" && docker compose pull)
    (cd "${BASE_DIR}" && docker compose up -d)

    # IMPORTANT: docker compose up -d does NOT recreate or restart an already
    # running container if the service definition in docker-compose.yml hasn't
    # changed (image, ports, environment variables). A change to the CONTENT of
    # a file mounted as a volume (prometheus.yml, alertmanager.yml, blackbox.yml,
    # loki-config.yml, grafana provisioning) isn't tracked by docker compose at
    # all — it's just a file on disk. And these services only read their config
    # on process startup, with no hot-reload by default. So after every config
    # regeneration we need to explicitly restart the containers that read them,
    # otherwise they keep running on the old in-memory config even though the
    # file on disk has long since been updated.
    log "Restarting services that read config files to apply current settings..."
    (cd "${BASE_DIR}" && docker compose restart prometheus alertmanager blackbox-exporter loki grafana)

    log "Stack started. Waiting 10 seconds before checking status..."
    sleep 10
    (cd "${BASE_DIR}" && docker compose ps)
}

# ----------------------------------------------------------------------------
# 14. Service health check
# ----------------------------------------------------------------------------

health_check() {
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    log "Checking service availability..."

    local endpoints=(
        "Prometheus|http://localhost:${PROMETHEUS_PORT}/-/healthy"
        "Alertmanager|http://localhost:${ALERTMANAGER_PORT}/-/healthy"
        "Grafana|https://localhost:${GRAFANA_PORT}/api/health"
        "Loki|http://localhost:${LOKI_PORT}/ready"
        "Blackbox Exporter|http://localhost:${BLACKBOX_PORT}/-/healthy"
        "Node Exporter|http://${HOST_IP}:${NODE_EXPORTER_PORT}/metrics"
        "Postgres Exporter|http://localhost:${POSTGRES_EXPORTER_PORT}/metrics"
    )

    for entry in "${endpoints[@]}"; do
        local name="${entry%%|*}"
        local url="${entry##*|}"
        # -k: skip TLS verification — needed for Grafana's self-signed cert,
        # harmless for the plain-http endpoints in this list.
        if curl -fsSk --max-time 5 "$url" -o /dev/null 2>/dev/null; then
            echo -e "  ${c_green}OK${c_reset}   ${name} (${url})"
        else
            echo -e "  ${c_red}FAIL${c_reset} ${name} (${url})"
        fi
    done
}

# ----------------------------------------------------------------------------
# 15. Final summary
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

 Service access:
   Grafana:            https://${ip}:${GRAFANA_PORT}  (self-signed TLS — browser will warn, this is expected)
                        login: ${GF_SECURITY_ADMIN_USER} / password: ${GF_SECURITY_ADMIN_PASSWORD}
   Prometheus:         http://${ip}:${PROMETHEUS_PORT}
   Alertmanager:       http://${ip}:${ALERTMANAGER_PORT}
   Blackbox Exporter:  http://${ip}:${BLACKBOX_PORT}
   Node Exporter:      http://${ip}:${NODE_EXPORTER_PORT}/metrics
   Postgres Exporter:  http://${ip}:${POSTGRES_EXPORTER_PORT}/metrics
   Loki:               http://${ip}:${LOKI_PORT}

 IMPORTANT — be sure to edit before production use:
   1) ${ENV_FILE}
        - POSTGRES_EXPORTER_DSN   -> real connection string to your DB
        - BLACKBOX_TARGETS        -> real sites/hosts to check
        - NODE_EXPORTER_TARGETS   -> additional hosts, if any
   2) ${BASE_DIR}/alertmanager/alertmanager.yml
        - configure a real notification channel (email/telegram/slack/webhook)

   After editing .env, re-run the script (it is idempotent) or run:
     cd ${BASE_DIR} && docker compose up -d --force-recreate prometheus postgres-exporter

 Self-signed certificates:
   For HTTPS targets with self-signed certificates, Blackbox uses the
   "https_selfsigned" module (tls_config.insecure_skip_verify: true), configured
   in ${BASE_DIR}/blackbox/blackbox.yml and already added in prometheus.yml
   as the "blackbox-https-selfsigned" job.

   Grafana itself is also set up with a self-signed TLS certificate
   (${BASE_DIR}/grafana/tls/grafana.crt, valid for 10 years). The browser
   will show an untrusted certificate warning — this is expected, simply
   add an exception. The certificate is created once and is not regenerated
   on subsequent script runs so that your browser exception stays valid.
   To force re-issuance (e.g., when changing HOST_IP), delete the files
   manually: rm ${BASE_DIR}/grafana/tls/grafana.{crt,key}

 Useful commands:
   Logs:        cd ${BASE_DIR} && docker compose logs -f [service]
   Status:      cd ${BASE_DIR} && docker compose ps
   Stop:        cd ${BASE_DIR} && docker compose down
   Update:      cd ${BASE_DIR} && docker compose pull && docker compose up -d
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
    generate_grafana_tls_cert
    generate_grafana_provisioning
    generate_compose_file
    deploy_stack
    health_check
    print_summary
}

main "$@"
