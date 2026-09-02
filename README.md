Grafana Observability Stack Deploy Script

Bash-скрипт для автоматического развёртывания observability-стека на Ubuntu 24.04 LTS через Docker Compose:





Prometheus — сбор метрик



Alertmanager — алертинг с уведомлениями в Telegram



Blackbox Exporter — проверка доступности HTTP(S)/ICMP-целей, включая сайты с самоподписанными сертификатами



Node Exporter — метрики хоста (CPU/RAM/диск/сеть)



Postgres Exporter — метрики PostgreSQL



Loki — агрегация логов



Grafana — визуализация, с автопровижининг datasource'ов (Prometheus, Alertmanager, Loki)

Скрипт идемпотентен: повторный запуск безопасен, конфиги перегенерируются из .env, существующие данные в Docker-томах не теряются.

Требования





Ubuntu 24.04 LTS (на других версиях/дистрибутивах не тестировалось)



root-доступ (sudo)



Доступ из сети сервера к: archive.ubuntu.com/зеркалам Ubuntu, Docker Hub (registry-1.docker.io, auth.docker.io)



Если сеть сегментирована — см. раздел Troubleshooting



Быстрый старт

git clone <URL этого репозитория>
cd <репозиторий>
chmod +x deploy-observability-stack.sh
sudo ./deploy-observability-stack.sh

При первом запуске скрипт:





Устанавливает Docker и Docker Compose plugin из штатных репозиториев Ubuntu (docker.io + docker-compose-v2)



Создаёт /opt/observability со всеми конфигами



Генерирует /opt/observability/.env со случайным паролем Grafana и placeholder-значениями для БД/таргетов/Telegram



Поднимает весь стек (docker compose pull && up -d)



Проверяет здоровье всех сервисов и выводит сводку с адресами и учётными данными

После первого запуска обязательно отредактируйте /opt/observability/.env (см. [.env.example](.env.example) как образец) и запустите скрипт повторно.

Конфигурация

Все настройки — через /opt/observability/.env. Полный список переменных с комментариями — в [.env.example](.env.example). Ключевые:







Переменная



Назначение





POSTGRES_EXPORTER_DSN



Строка подключения к PostgreSQL (нужны права pg_monitor)





BLACKBOX_TARGETS



HTTP(S)-адреса для проверки доступности (через запятую)





NODE_EXPORTER_TARGETS



Хосты с node-exporter, если их несколько





BLACKBOX_ICMP_TARGETS



Отдельный список для ICMP-пинга (независим от остальных)





TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID



Канал алертов в Alertmanager

После правки .env запустите скрипт ещё раз — он перегенерирует конфиги и перезапустит нужные контейнеры автоматически.

Важно: docker compose up -d не перечитывает содержимое уже смонтированных конфиг-файлов и не перезапускает контейнер, если описание сервиса в docker-compose.yml не изменилось. Поэтому скрипт всегда явно перезапускает prometheus, alertmanager, blackbox-exporter, loki и grafana после генерации конфигов — если редактируете конфиги вручную, делайте docker compose restart <сервис> тем же способом.

Дашборды Grafana

Автоматической загрузки community-дашбордов в скрипте нет (сознательно убрано — при недоступности grafana.com из сегментированной сети это создавало проблемы, а provisioning-дашборды сложно удалить из UI). Импортируйте вручную:

Dashboards → New → Import, укажите ID и выберите datasource Prometheus:







ID



Дашборд





1860



Node Exporter Full





7587



Prometheus Blackbox Exporter





9628



PostgreSQL Database



ID актуальны на момент подготовки скрипта — проверьте на grafana.com/dashboards, что дашборд ещё существует и подходит под вашу версию Grafana/exporter'ов.



Самоподписанные сертификаты

Blackbox Exporter использует единый модуль https_selfsigned (tls_config.insecure_skip_verify: true) для всех целей из BLACKBOX_TARGETS — он одинаково корректно работает и с https:// (включая самоподписанные сертификаты), и с http:// (TLS-настройки просто не применяются к нешифрованным целям). Отдельного строгого TLS-режима намеренно нет — это раньше приводило к задвоению метрик на одну и ту же цель.

Структура после развёртывания

/opt/observability/
├── .env                              # все настройки
├── docker-compose.yml
├── prometheus/
│   ├── prometheus.yml                # перегенерируется скриптом
│   └── alert.rules.yml               # создаётся один раз, дальше не трогается — правьте вручную
├── alertmanager/alertmanager.yml
├── blackbox/blackbox.yml
├── loki/loki-config.yml
└── grafana/provisioning/
    ├── datasources/datasources.yml
    └── dashboards/dashboards.yml



Troubleshooting





Сегментированная сеть / нет доступа к download.docker.com — скрипт ставит Docker из штатных репозиториев Ubuntu, отдельный внешний репозиторий не требуется. Убедитесь, что доступны сами зеркала Ubuntu и Docker Hub.



apt update падает с Segmentation fault на хуке command-not-found — известный баг некоторых сборок Ubuntu 24.04 (cnf-update-db). Скрипт отключает этот хук автоматически (#clear APT::Update::Post-Invoke-Success; в /etc/apt/apt.conf.d/).



node-exporter в DOWN / context deadline exceeded — node-exporter работает в network_mode: host (для точных метрик хоста), а Prometheus — в отдельной bridge-сети Docker. Если на хосте включён ufw/iptables с политикой INPUT DROP, трафик от bridge-подсети к порту 9100 может блокироваться. Решение — разрешить эту подсеть на порт 9100:

docker network inspect observability_monitoring | grep -i subnet
ufw allow from <ПОДСЕТЬ> to any port 9100 proto tcp



no pg_hba.conf entry for host ... — на стороне PostgreSQL нет разрешающей строки для нужного пользователя/хоста. Добавьте правило в pg_hba.conf (или через patronictl edit-config, если кластер под Patroni — ручная правка файла в этом случае бессмысленна, Patroni его перезапишет) и перечитайте конфиг (SELECT pg_reload_conf();).



pq: SSL is not enabled on the server — в POSTGRES_EXPORTER_DSN не задан явно sslmode=disable (пустой параметр после ? — не то же самое, что его отсутствие).



Лицензия

MIT
