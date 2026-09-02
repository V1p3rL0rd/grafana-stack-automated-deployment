#!/usr/bin/env bash
###############################################################################
# deploy-observability-stack.sh
#
# Универсальное развёртывание observability-стека на Ubuntu 24.04 LTS:
#   - Prometheus
#   - Alertmanager
#   - Blackbox Exporter (в т.ч. пробинг HTTPS с самоподписанными сертификатами)
#   - Node Exporter
#   - Postgres Exporter
#   - Loki
#   - Grafana (с автопровижининг datasources)
#
# Все сервисы разворачиваются через docker-compose (docker compose plugin).
#
# Использование:
#   sudo bash deploy-observability-stack.sh
#
# Повторный запуск безопасен (идемпотентен): существующий .env не
# перезаписывается, конфиги пересоздаются, данные хранятся в именованных
# docker-томах и не теряются.
###############################################################################

set -euo pipefail

# ----------------------------------------------------------------------------
# 0. Базовые настройки / переменные
# ----------------------------------------------------------------------------

BASE_DIR="/opt/observability"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
ENV_FILE="${BASE_DIR}/.env"

# Версии образов (зафиксированы для предсказуемости и стабильности стека)
PROMETHEUS_VERSION="v2.53.0"
ALERTMANAGER_VERSION="v0.27.0"
BLACKBOX_VERSION="v0.25.0"
NODE_EXPORTER_VERSION="v1.8.2"
POSTGRES_EXPORTER_VERSION="v0.15.0"
LOKI_VERSION="2.9.8"
GRAFANA_VERSION="11.1.0"

# Публикуемые наружу порты (можно поменять до запуска через .env)
GRAFANA_PORT_DEFAULT=3000
PROMETHEUS_PORT_DEFAULT=9090
ALERTMANAGER_PORT_DEFAULT=9093
BLACKBOX_PORT_DEFAULT=9115
NODE_EXPORTER_PORT_DEFAULT=9100
POSTGRES_EXPORTER_PORT_DEFAULT=9187
LOKI_PORT_DEFAULT=3100

# ----------------------------------------------------------------------------
# Утилиты логирования
# ----------------------------------------------------------------------------

c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_reset='\033[0m'
log()  { echo -e "${c_green}[INFO]${c_reset} $*"; }
warn() { echo -e "${c_yellow}[WARN]${c_reset} $*"; }
err()  { echo -e "${c_red}[ERROR]${c_reset} $*" >&2; }
die()  { err "$*"; exit 1; }

# ----------------------------------------------------------------------------
# 1. Проверки окружения
# ----------------------------------------------------------------------------

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Скрипт нужно запускать от root (используйте sudo). Пример: sudo bash $0"
    fi
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        if [[ "${ID:-}" != "ubuntu" ]]; then
            warn "Обнаружена ОС '${ID:-unknown}', скрипт рассчитан на Ubuntu 24.04 LTS. Продолжаю на свой страх и риск..."
        elif [[ "${VERSION_ID:-}" != "24.04" ]]; then
            warn "Обнаружена Ubuntu ${VERSION_ID:-unknown}, скрипт протестирован на 24.04. Продолжаю..."
        else
            log "Ubuntu 24.04 LTS подтверждена."
        fi
    else
        warn "Не удалось определить ОС (/etc/os-release отсутствует). Продолжаю..."
    fi
}

# ----------------------------------------------------------------------------
# 2. Установка Docker + docker compose plugin
# ----------------------------------------------------------------------------

install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        log "Docker и docker compose plugin уже установлены: $(docker --version)"
        return 0
    fi

    log "Устанавливаю Docker и Docker Compose из штатных репозиториев Ubuntu (docker.io + docker-compose-v2)..."

    # На некоторых сборках Ubuntu 24.04 хук command-not-found (cnf-update-db),
    # который apt дёргает после успешного update/install, падает с Segmentation fault.
    # Сама операция apt при этом отрабатывает штатно, но из-за ненулевого кода выхода
    # хука apt-get возвращает ошибку и скрипт падает под set -e. Отключаем хук —
    # для headless-автоматизации он не нужен.
    if [[ ! -f /etc/apt/apt.conf.d/99-disable-post-invoke-hooks ]]; then
        cat <<'EOF' > /etc/apt/apt.conf.d/99-disable-post-invoke-hooks
#clear APT::Update::Post-Invoke-Success;
EOF
        log "Отключён apt post-invoke хук command-not-found (известный segfault на Ubuntu 24.04)."
    fi

    apt-get update -y
    # docker.io — Docker Engine из репозиториев Ubuntu (universe)
    # docker-compose-v2 — плагин "docker compose" (v2) из репозиториев Ubuntu
    apt-get install -y docker.io docker-compose-v2

    systemctl enable --now docker

    # Добавляем пользователя, который вызвал sudo, в группу docker (если применимо)
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        usermod -aG docker "${SUDO_USER}" || true
        log "Пользователь '${SUDO_USER}' добавлен в группу docker (перелогиньтесь для применения)."
    fi

    log "Docker установлен: $(docker --version)"
    log "Docker Compose plugin: $(docker compose version)"
}

# ----------------------------------------------------------------------------
# 3. Определение IP хоста (для node-exporter, который работает в host network)
# ----------------------------------------------------------------------------

detect_host_ip() {
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ -z "${ip}" ]]; then
        ip="127.0.0.1"
        warn "Не удалось автоматически определить IP хоста, использую 127.0.0.1. Поправьте вручную в ${BASE_DIR}/prometheus/prometheus.yml"
    fi
    echo "${ip}"
}

# ----------------------------------------------------------------------------
# 4. Создание структуры каталогов
# ----------------------------------------------------------------------------

create_dirs() {
    log "Создаю структуру каталогов в ${BASE_DIR}..."
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
# 5. Генерация .env (создаётся один раз, дальше не перезаписывается)
# ----------------------------------------------------------------------------

# Добавляет переменную в существующий .env, если её там ещё нет (не трогает уже заданные значения)
ensure_env_var() {
    local key="$1" default_value="$2" comment="${3:-}"
    if ! grep -qE "^${key}=" "${ENV_FILE}" 2>/dev/null; then
        [[ -n "$comment" ]] && echo -e "\n${comment}" >> "${ENV_FILE}"
        echo "${key}=${default_value}" >> "${ENV_FILE}"
        log "В ${ENV_FILE} добавлена новая переменная: ${key}"
    fi
}

generate_env() {
    if [[ -f "${ENV_FILE}" ]]; then
        log ".env уже существует, дополняю недостающими переменными (существующие значения не трогаю): ${ENV_FILE}"
        ensure_env_var "TELEGRAM_BOT_TOKEN" "CHANGE_ME_telegram_bot_token" \
            "# --- Alertmanager: уведомления в Telegram (добавлено при апгрейде) ---"
        ensure_env_var "TELEGRAM_CHAT_ID" "CHANGE_ME_telegram_chat_id"
        # shellcheck disable=SC1090
        source "${ENV_FILE}"
        return 0
    fi

    log "Генерирую ${ENV_FILE}..."

    local host_ip grafana_admin_pass pg_exporter_pass
    host_ip="$(detect_host_ip)"
    grafana_admin_pass="$(openssl rand -base64 18 | tr -d '=+/' | cut -c1-20)"
    pg_exporter_pass="CHANGE_ME_password"

    cat <<EOF > "${ENV_FILE}"
###############################################################################
# Конфигурация observability-стека. Отредактируйте под своё окружение.
###############################################################################

# --- Порты, публикуемые на хосте ---
GRAFANA_PORT=${GRAFANA_PORT_DEFAULT}
PROMETHEUS_PORT=${PROMETHEUS_PORT_DEFAULT}
ALERTMANAGER_PORT=${ALERTMANAGER_PORT_DEFAULT}
BLACKBOX_PORT=${BLACKBOX_PORT_DEFAULT}
NODE_EXPORTER_PORT=${NODE_EXPORTER_PORT_DEFAULT}
POSTGRES_EXPORTER_PORT=${POSTGRES_EXPORTER_PORT_DEFAULT}
LOKI_PORT=${LOKI_PORT_DEFAULT}

# --- IP хоста, на котором крутится стек (нужно node-exporter'у, т.к. он в host network) ---
HOST_IP=${host_ip}

# --- Grafana ---
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=${grafana_admin_pass}

# --- Alertmanager: уведомления в Telegram ---
# 1) Создайте бота через @BotFather, получите TELEGRAM_BOT_TOKEN (вида 123456:ABC-DEF...)
# 2) Узнайте chat_id: добавьте бота в нужный чат/канал и откройте
#    https://api.telegram.org/bot<TOKEN>/getUpdates после отправки любого сообщения в чат,
#    либо используйте @userinfobot / @getmyid_bot для личных чатов.
# 3) Для канала chat_id обычно отрицательный (например -1001234567890).
TELEGRAM_BOT_TOKEN=CHANGE_ME_telegram_bot_token
TELEGRAM_CHAT_ID=CHANGE_ME_telegram_chat_id

# --- Postgres Exporter: строка подключения к вашей БД ---
# ЗАМЕНИТЕ на реальные хост/порт/базу/пользователя/пароль.
# Пользователь БД должен иметь права минимум pg_monitor (PostgreSQL 10+):
#   CREATE USER postgres_exporter WITH PASSWORD 'strong_password';
#   GRANT pg_monitor TO postgres_exporter;
POSTGRES_EXPORTER_DSN=postgresql://postgres_exporter:${pg_exporter_pass}@192.168.1.50:5432/postgres?sslmode=disable

# --- Blackbox Exporter: список HTTP(S) целей для проверки, через запятую ---
# Пробуются по умолчанию модулем https_selfsigned (допускает самоподписанные сертификаты)
# и http_2xx для обычного http. ЗАМЕНИТЕ на свои реальные адреса/сайты.
BLACKBOX_TARGETS=https://192.168.1.10,https://192.168.1.20:8443,http://192.168.1.30:80

# --- Список хостов node-exporter, если у вас их несколько (через запятую, host:port) ---
# По умолчанию сюда подставляется HOST_IP:9100 (сам сервер). Добавьте другие хосты при необходимости.
NODE_EXPORTER_TARGETS=${host_ip}:9100

# --- Данные хранения (retention) Prometheus ---
PROMETHEUS_RETENTION=30d
EOF

    chmod 600 "${ENV_FILE}"
    log "Файл .env создан. Сгенерированный пароль Grafana admin: ${grafana_admin_pass}"
    warn "ОБЯЗАТЕЛЬНО отредактируйте POSTGRES_EXPORTER_DSN и BLACKBOX_TARGETS в ${ENV_FILE} под ваши реальные адреса, затем перезапустите скрипт."
}

# ----------------------------------------------------------------------------
# 6. Генерация конфигурации Prometheus
# ----------------------------------------------------------------------------

generate_prometheus_config() {
    log "Генерирую prometheus.yml..."

    # shellcheck disable=SC1090
    source "${ENV_FILE}"

    # Формируем YAML-список целей blackbox из BLACKBOX_TARGETS (через запятую)
    local blackbox_targets_yaml=""
    IFS=',' read -ra _BB_ARR <<< "${BLACKBOX_TARGETS}"
    for t in "${_BB_ARR[@]}"; do
        t="$(echo "$t" | xargs)"  # trim
        [[ -z "$t" ]] && continue
        blackbox_targets_yaml+="          - ${t}"$'\n'
    done
    [[ -z "$blackbox_targets_yaml" ]] && blackbox_targets_yaml="          []"$'\n'
    blackbox_targets_yaml="${blackbox_targets_yaml%$'\n'}"

    # Формируем YAML-список целей node-exporter
    local node_targets_yaml=""
    IFS=',' read -ra _NE_ARR <<< "${NODE_EXPORTER_TARGETS}"
    for t in "${_NE_ARR[@]}"; do
        t="$(echo "$t" | xargs)"
        [[ -z "$t" ]] && continue
        node_targets_yaml+="          - ${t}"$'\n'
    done
    [[ -z "$node_targets_yaml" ]] && node_targets_yaml="          []"$'\n'
    node_targets_yaml="${node_targets_yaml%$'\n'}"

    # Список для ICMP (только хост/IP, без :port) — на основе NODE_EXPORTER_TARGETS
    local node_targets_hosts_only=""
    for t in "${_NE_ARR[@]}"; do
        t="$(echo "$t" | xargs)"
        [[ -z "$t" ]] && continue
        node_targets_hosts_only+="          - ${t%%:*}"$'\n'
    done
    [[ -z "$node_targets_hosts_only" ]] && node_targets_hosts_only="          []"$'\n'
    node_targets_hosts_only="${node_targets_hosts_only%$'\n'}"

    # Пишем итоговый файл напрямую bash-heredoc'ом (без внешних интерпретаторов —
    # устойчиво к проблемам платформы вроде сегфолтов python3/системных бинарников).
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

  # Сам Prometheus
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  # Alertmanager
  - job_name: "alertmanager"
    static_configs:
      - targets: ["alertmanager:9093"]

  # Node Exporter (метрики хоста/хостов)
  - job_name: "node-exporter"
    static_configs:
      - targets:
${node_targets_yaml}

  # Postgres Exporter
  - job_name: "postgres-exporter"
    static_configs:
      - targets: ["postgres-exporter:9187"]

  # Loki (собственные метрики)
  - job_name: "loki"
    static_configs:
      - targets: ["loki:3100"]

  # Blackbox Exporter: HTTP(S)-цели, в т.ч. с самоподписанными сертификатами.
  # Модуль https_selfsigned безопасен и для обычных http:// целей — TLS-настройки
  # просто не применяются, когда схема адреса не https. Поэтому одного job'а
  # достаточно для всех целей из BLACKBOX_TARGETS — отдельный job для "строгого"
  # HTTP только задваивал бы метрики по одному и тому же таргету.
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

  # Blackbox Exporter: ICMP ping (требует cap_add: NET_RAW у контейнера)
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

    # Пустой файл правил алертинга (можно наполнить своими правилами позже)
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
          description: "{{ $labels.instance }} (job {{ $labels.job }}) недоступен более 2 минут."

      - alert: HighNodeCPU
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Высокая загрузка CPU на {{ $labels.instance }}"
          description: "Загрузка CPU превышает 90% более 5 минут."

      - alert: HighNodeMemory
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 90
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Высокое потребление памяти на {{ $labels.instance }}"
          description: "Использование памяти превышает 90% более 5 минут."

      - alert: BlackboxProbeFailed
        expr: probe_success == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Probe failed для {{ $labels.instance }}"
          description: "Blackbox probe для {{ $labels.instance }} не проходит более 2 минут."
EOF
    fi
}

# ----------------------------------------------------------------------------
# 7. Генерация конфигурации Alertmanager
# ----------------------------------------------------------------------------

generate_alertmanager_config() {
    # shellcheck disable=SC1090
    source "${ENV_FILE}"

    # chat_id в Telegram-конфиге Alertmanager должен быть валидным числом (может быть отрицательным
    # для каналов/супергрупп). Если токен/chat_id ещё не заданы (плейсхолдеры) или chat_id не число —
    # генерируем безопасный null-receiver, чтобы Alertmanager не ушёл в crash-loop из-за невалидного конфига.
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
        log "Генерирую alertmanager.yml (получатель: Telegram, chat_id=${TELEGRAM_CHAT_ID})..."
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
          🚨 <b>[ПРОБЛЕМА] {{ .CommonLabels.alertname }}</b>
          {{- else -}}
          ✅ <b>[ВОССТАНОВЛЕНИЕ] {{ .CommonLabels.alertname }}</b>
          {{- end }}
          {{ range .Alerts }}
          <b>Узел:</b> {{ .Labels.instance | html }}
          <b>Джоб:</b> {{ .Labels.job | html }}
          <b>Критичность:</b> {{ .Labels.severity | html }}
          <b>Описание:</b> {{ .Annotations.description | html }}
          <b>Время изменения:</b> {{ (.StartsAt.Add 10800000000000).Format "2006-01-02 15:04:05" }} MSK
          {{ end }}

inhibit_rules:
  - source_match:
      severity: "critical"
    target_match:
      severity: "warning"
    equal: ["alertname", "instance"]
EOF
    else
        warn "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID не заданы или некорректны в ${ENV_FILE}."
        warn "Генерирую alertmanager.yml с null-receiver (алерты будут накапливаться, но НЕ отправляться), чтобы избежать crash-loop."
        warn "После заполнения переменных перезапустите скрипт — конфиг переключится на реальный Telegram-receiver."
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
  # ЗАПОЛНИТЕ TELEGRAM_BOT_TOKEN и TELEGRAM_CHAT_ID в .env и перезапустите скрипт —
  # автоматически подключится реальный Telegram-receiver.
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
# 8. Генерация конфигурации Blackbox Exporter (с поддержкой self-signed TLS)
# ----------------------------------------------------------------------------

generate_blackbox_config() {
    log "Генерирую blackbox.yml (с модулем для самоподписанных сертификатов)..."
    cat <<'EOF' > "${BASE_DIR}/blackbox/blackbox.yml"
modules:

  # Обычный HTTP(S) с валидацией сертификата (для сайтов с нормальными CA-сертификатами)
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: []   # по умолчанию 2xx
      method: GET
      preferred_ip_protocol: "ip4"
      tls_config:
        insecure_skip_verify: false

  # HTTPS с самоподписанными / недоверенными сертификатами — TLS-верификация отключена
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
        insecure_skip_verify: true   # ключевая настройка для самоподписанных сертификатов

  # Проверка TCP-порта
  tcp_connect:
    prober: tcp
    timeout: 5s

  # ICMP ping
  icmp:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: "ip4"

  # DNS-проверка (пример)
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
# 9. Генерация конфигурации Loki
# ----------------------------------------------------------------------------

generate_loki_config() {
    log "Генерирую loki-config.yml..."
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
# 10. Генерация datasource-провижининга Grafana
# ----------------------------------------------------------------------------

generate_grafana_provisioning() {
    log "Генерирую provisioning datasources для Grafana..."
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
# 11. Генерация docker-compose.yml
# ----------------------------------------------------------------------------

generate_compose_file() {
    log "Генерирую docker-compose.yml..."
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
# 12. Развёртывание
# ----------------------------------------------------------------------------

deploy_stack() {
    log "Проверяю синтаксис docker-compose.yml..."
    (cd "${BASE_DIR}" && docker compose config -q) \
        || die "Ошибка в docker-compose.yml, смотри вывод выше."

    log "Запускаю стек через docker compose (pull + up -d)..."
    (cd "${BASE_DIR}" && docker compose pull)
    (cd "${BASE_DIR}" && docker compose up -d)

    # ВАЖНО: docker compose up -d НЕ пересоздаёт и НЕ перезапускает уже запущенный
    # контейнер, если описание сервиса в docker-compose.yml не изменилось (образ,
    # порты, переменные окружения). Изменение СОДЕРЖИМОГО файла, примонтированного
    # как volume (prometheus.yml, alertmanager.yml, blackbox.yml, loki-config.yml,
    # grafana provisioning), docker compose вообще не отслеживает — это просто файл
    # на диске. А сами эти сервисы читают свой конфиг только при старте процесса,
    # без hot-reload по умолчанию. Поэтому после каждой регенерации конфигов нужно
    # явно перезапустить контейнеры, которые их читают, иначе они продолжат работать
    # со старым конфигом из памяти, хотя на диске давно всё актуально.
    log "Перезапускаю сервисы, читающие конфиги из файлов, чтобы применить актуальные настройки..."
    (cd "${BASE_DIR}" && docker compose restart prometheus alertmanager blackbox-exporter loki grafana)

    log "Стек запущен. Жду 10 секунд перед проверкой состояния..."
    sleep 10
    (cd "${BASE_DIR}" && docker compose ps)
}

# ----------------------------------------------------------------------------
# 13. Проверка здоровья сервисов
# ----------------------------------------------------------------------------

health_check() {
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    log "Проверка доступности сервисов..."

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
# 14. Итоговая сводка
# ----------------------------------------------------------------------------

print_summary() {
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    local ip; ip="${HOST_IP}"

    cat <<EOF

===============================================================================
 Observability-стек развёрнут.
===============================================================================
 Каталог стека:      ${BASE_DIR}
 Файл переменных:    ${ENV_FILE}
 Compose-файл:        ${COMPOSE_FILE}

 Доступ к сервисам:
   Grafana:            http://${ip}:${GRAFANA_PORT}
                        логин: ${GF_SECURITY_ADMIN_USER} / пароль: ${GF_SECURITY_ADMIN_PASSWORD}
   Prometheus:         http://${ip}:${PROMETHEUS_PORT}
   Alertmanager:       http://${ip}:${ALERTMANAGER_PORT}
   Blackbox Exporter:  http://${ip}:${BLACKBOX_PORT}
   Node Exporter:      http://${ip}:${NODE_EXPORTER_PORT}/metrics
   Postgres Exporter:  http://${ip}:${POSTGRES_EXPORTER_PORT}/metrics
   Loki:               http://${ip}:${LOKI_PORT}

 ВАЖНО — обязательно отредактируйте перед боевым использованием:
   1) ${ENV_FILE}
        - POSTGRES_EXPORTER_DSN   -> реальная строка подключения к вашей БД
        - BLACKBOX_TARGETS        -> реальные сайты/хосты для проверки
        - NODE_EXPORTER_TARGETS   -> дополнительные хосты, если есть
   2) ${BASE_DIR}/alertmanager/alertmanager.yml
        - настройте реальный канал уведомлений (email/telegram/slack/webhook)

   После правки .env перезапустите скрипт (он идемпотентен) либо выполните:
     cd ${BASE_DIR} && docker compose up -d --force-recreate prometheus postgres-exporter

 Самоподписанные сертификаты:
   Для HTTPS-целей с self-signed сертификатами Blackbox использует модуль
   "https_selfsigned" (tls_config.insecure_skip_verify: true), настроенный
   в ${BASE_DIR}/blackbox/blackbox.yml и уже подключённый в prometheus.yml
   как job "blackbox-https-selfsigned".

 Полезные команды:
   Логи:        cd ${BASE_DIR} && docker compose logs -f [сервис]
   Статус:      cd ${BASE_DIR} && docker compose ps
   Остановить:  cd ${BASE_DIR} && docker compose down
   Обновить:    cd ${BASE_DIR} && docker compose pull && docker compose up -d
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
