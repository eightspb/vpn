#!/usr/bin/env bash
# =============================================================================
# deploy-cloak.sh — деплой Cloak (TLS-маскировка VPN-трафика под yandex.ru)
#
# Cloak оборачивает AmneziaWG UDP трафик в TLS-соединение с SNI произвольного
# сайта (по умолчанию yandex.ru). Провайдер видит обычный HTTPS к вашему IP,
# не может отличить от настоящего визита на Яндекс.
#
# Схема:
#   [Клиент] → ck-client (TLS, SNI=yandex.ru) → [VPS1 ck-server:443] → awg1:51820 → ...
#
# Компоненты:
#   - ck-server на VPS1: слушает TCP 443, расшифровывает Cloak, пробрасывает в awg1
#   - ck-client на клиенте: принимает UDP, оборачивает в TLS, отправляет на VPS1:443
#
# Использование:
#   bash deploy-cloak.sh [опции]
#
# Опции:
#   --vps1-ip        IP адрес VPS1
#   --vps1-user      Пользователь на VPS1 (default: root)
#   --vps1-key       Путь к SSH ключу для VPS1
#   --vps1-pass      Пароль для VPS1 (если нет ключа)
#   --fake-domain    Домен для маскировки SNI (default: yandex.ru)
#   --cloak-port     Порт Cloak на VPS1 (default: 443)
#   --output-dir     Куда сохранить клиентский конфиг Cloak (default: ./vpn-output)
#   --help           Справка
#
# Примеры:
#   # Базовый (маскировка под yandex.ru):
#   bash deploy-cloak.sh --vps1-ip 130.193.41.13 --vps1-key .ssh/ssh-key
#
#   # Маскировка под другой домен:
#   bash deploy-cloak.sh --vps1-ip 130.193.41.13 --vps1-key .ssh/ssh-key --fake-domain mail.ru
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# On Windows/Git Bash, convert drive-letter paths to /mnt/... style if needed
if [[ "$SCRIPT_DIR" =~ ^/[A-Za-z]/ ]]; then
    DRIVE=$(echo "$SCRIPT_DIR" | cut -c2 | tr '[:upper:]' '[:lower:]')
    REST=$(echo "$SCRIPT_DIR" | cut -c3-)
    SCRIPT_DIR="/mnt/${DRIVE}${REST}"
fi

source "${SCRIPT_DIR}/../../lib/common.sh"

SSH_BIN="${SSH_BIN:-ssh}"
SCP_BIN="${SCP_BIN:-scp}"
SSHPASS_BIN="${SSHPASS_BIN:-sshpass}"

# Cloak release version
CLOAK_VERSION="2.7.0"
CLOAK_ARCH="amd64"

# ── Параметры по умолчанию ─────────────────────────────────────────────────
VPS1_IP=""; VPS1_USER=""; VPS1_KEY=""; VPS1_PASS=""
FAKE_DOMAIN="yandex.ru"
CLOAK_PORT=443
OUTPUT_DIR="./vpn-output"
VPS1_PORT_CLIENTS="${VPS1_PORT_CLIENTS:-51820}"

load_defaults_from_files

# ── Парсинг аргументов ─────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps1-ip)       VPS1_IP="$2";       shift 2 ;;
        --vps1-user)     VPS1_USER="$2";     shift 2 ;;
        --vps1-key)      VPS1_KEY="$2";      shift 2 ;;
        --vps1-pass)     VPS1_PASS="$2";     shift 2 ;;
        --fake-domain)   FAKE_DOMAIN="$2";   shift 2 ;;
        --cloak-port)    CLOAK_PORT="$2";    shift 2 ;;
        --output-dir)    OUTPUT_DIR="$2";    shift 2 ;;
        --help|-h)
            sed -n '/^# Использование/,/^# ====/p' "$0" | grep -v "^# ====" | sed 's/^# \?//'
            exit 0 ;;
        *) err "Неизвестный параметр: $1" ;;
    esac
done

# ── Фоллбэк ───────────────────────────────────────────────────────────────
VPS1_USER="${VPS1_USER:-root}"

# ── Подготовка SSH-ключей ──────────────────────────────────────────────────
VPS1_KEY="$(expand_tilde "$VPS1_KEY")"
VPS1_KEY="$(auto_pick_key_if_missing "$VPS1_KEY")"

# ── Проверка обязательных параметров ───────────────────────────────────────
require_vars "deploy-cloak.sh" VPS1_IP
[[ -z "$VPS1_KEY" && -z "$VPS1_PASS" ]] && err "Укажите --vps1-key или --vps1-pass (или VPS1_KEY в .env)"

# Ключи с /mnt/ (WSL/Windows) копируем во временные файлы
VPS1_KEY="$(prepare_key_for_ssh "$VPS1_KEY")"
trap cleanup_temp_keys EXIT

# ── SSH хелперы ────────────────────────────────────────────────────────────
run1() {
    local -a ssh_opts=(-T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=no)
    if [[ -n "$VPS1_KEY" ]]; then
        "$SSH_BIN" "${ssh_opts[@]}" -i "$VPS1_KEY" "${VPS1_USER}@${VPS1_IP}" "$@" 2>&1
    else
        "$SSHPASS_BIN" -p "$VPS1_PASS" "$SSH_BIN" "${ssh_opts[@]}" "${VPS1_USER}@${VPS1_IP}" "$@" 2>&1
    fi
}

upload1() { local f=$1; local dst=${2:-/tmp/$(basename $f)}
    local -a scp_opts=(-o StrictHostKeyChecking=accept-new)
    local src="$f"
    if [[ "$SCP_BIN" == *".exe" ]]; then
        src="$(_path_for_native_ssh "$f")"
    fi
    if [[ -n "$VPS1_KEY" ]]; then
        "$SCP_BIN" "${scp_opts[@]}" -i "$VPS1_KEY" "$src" "${VPS1_USER}@${VPS1_IP}:${dst}" 2>&1
    else
        "$SSHPASS_BIN" -p "$VPS1_PASS" "$SCP_BIN" "${scp_opts[@]}" "$src" "${VPS1_USER}@${VPS1_IP}:${dst}" 2>&1
    fi
}

run_script1() { local script=$1; local tmp=$(mktemp /tmp/deploy_XXXX.sh)
    echo "$script" > "$tmp"; upload1 "$tmp" /tmp/_deploy_step.sh; rm "$tmp"
    run1 "sudo bash /tmp/_deploy_step.sh"
}

# ── Проверка зависимостей ──────────────────────────────────────────────────
if [[ -n "$VPS1_PASS" ]]; then
    check_deps --need-sshpass
else
    check_deps
fi

# ── Начало деплоя ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Cloak — TLS-маскировка VPN-трафика                        ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
log "VPS1: ${BOLD}${VPS1_USER}@${VPS1_IP}${NC}"
log "Маскировка: ${BOLD}${FAKE_DOMAIN}${NC} (SNI)"
log "Порт Cloak: ${BOLD}${CLOAK_PORT}${NC}"
echo ""

mkdir -p "$OUTPUT_DIR"

# ── Шаг 1: Проверка SSH ───────────────────────────────────────────────────
step "Шаг 1/5: Проверка SSH к VPS1"
VPS1_OS=$(run1 "cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"'") \
    || err "Не удалось подключиться к VPS1 (${VPS1_IP})"
ok "VPS1: $VPS1_OS"

# ── Шаг 2: Установка и настройка Cloak сервера ────────────────────────────
step "Шаг 2/5: Установка Cloak сервера на VPS1"

log "Устанавливаю ck-server v${CLOAK_VERSION}..."
CK_KEYS=$(run_script1 "
set -euo pipefail

# Скачиваем Cloak
cd /tmp
CLOAK_URL=\"https://github.com/cbeuw/Cloak/releases/download/v${CLOAK_VERSION}/ck-server-linux-${CLOAK_ARCH}-v${CLOAK_VERSION}\"
CLOAK_CLIENT_URL=\"https://github.com/cbeuw/Cloak/releases/download/v${CLOAK_VERSION}/ck-client-linux-${CLOAK_ARCH}-v${CLOAK_VERSION}\"

# Скачиваем бинарники
if ! curl -fsSL \"\${CLOAK_URL}\" -o /usr/local/bin/ck-server; then
    echo 'ОШИБКА: не удалось скачать ck-server'
    exit 1
fi
chmod +x /usr/local/bin/ck-server

# Генерируем ключи (keypair для шифрования Cloak)
mkdir -p /etc/cloak
CK_KEYPAIR=\$(/usr/local/bin/ck-server -key 2>&1)
# Формат вывода ck-server -key (v2.7+):
#   Your PUBLIC key is:                      <base64>
#   Your PRIVATE key is (keep it secret):    <base64>
CK_PUB=\$(echo \"\$CK_KEYPAIR\" | grep 'PUBLIC' | awk '{print \$NF}')
CK_PRIV=\$(echo \"\$CK_KEYPAIR\" | grep 'PRIVATE' | awk '{print \$NF}')

# Генерируем UID для клиента
# Формат вывода: Your UID is: <base64>
CK_UID=\$(/usr/local/bin/ck-server -uid 2>&1 | awk '{print \$NF}')

# Генерируем admin UID
CK_ADMIN_UID=\$(/usr/local/bin/ck-server -uid 2>&1 | awk '{print \$NF}')

echo \"CK_PRIV=\${CK_PRIV}\"
echo \"CK_PUB=\${CK_PUB}\"
echo \"CK_UID=\${CK_UID}\"
echo \"CK_ADMIN_UID=\${CK_ADMIN_UID}\"

# Создаём конфигурацию сервера
cat > /etc/cloak/ckserver.json << CKEOF
{
  \"ProxyBook\": {
    \"awg\": [\"udp\", \"127.0.0.1:${VPS1_PORT_CLIENTS}\"]
  },
  \"BindAddr\": [\":${CLOAK_PORT}\"],
  \"BypassUID\": [\"\${CK_ADMIN_UID}\"],
  \"RedirAddr\": \"${FAKE_DOMAIN}\",
  \"PrivateKey\": \"\${CK_PRIV}\",
  \"DatabasePath\": \"/etc/cloak/userinfo.db\",
  \"StreamTimeout\": 300
}
CKEOF
chmod 600 /etc/cloak/ckserver.json

# Создаём systemd сервис
cat > /etc/systemd/system/cloak-server.service << 'SVCEOF'
[Unit]
Description=Cloak Server (TLS traffic masking)
After=network-online.target awg-quick@awg1.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ck-server -c /etc/cloak/ckserver.json
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVCEOF

# Открываем порт в iptables (idempotent)
iptables -C INPUT -p tcp --dport ${CLOAK_PORT} -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 5 -p tcp --dport ${CLOAK_PORT} -j ACCEPT

# Освобождаем порт ${CLOAK_PORT} если занят (nginx и т.п.)
if ss -tlnp | grep -q ':${CLOAK_PORT} '; then
    echo \"PORT_CONFLICT=true\"
    # Определяем что занимает порт
    BLOCKING_PROC=\$(ss -tlnp | grep ':${CLOAK_PORT} ' | grep -oP '\"\\K[^\"]+' | head -1)
    echo \"PORT_BLOCKED_BY=\${BLOCKING_PROC}\"
    if [[ \"\$BLOCKING_PROC\" == \"nginx\" ]]; then
        # Отключаем nginx на 443: убираем listen 443 из конфигов
        # Сохраняем бэкап и останавливаем nginx
        if nginx -t 2>/dev/null; then
            # Удаляем конфиги слушающие 443
            for f in /etc/nginx/sites-enabled/*; do
                if [[ -f \"\$f\" ]] && grep -q 'listen.*443' \"\$f\"; then
                    rm -f \"\$f\"
                    echo \"NGINX_DISABLED_SITE=\$(basename \$f)\"
                fi
            done
            # Если после удаления конфигов nginx не нужен — останавливаем
            if [[ -z \"\$(ls /etc/nginx/sites-enabled/ 2>/dev/null)\" ]]; then
                systemctl stop nginx
                systemctl disable nginx
                echo \"NGINX_STOPPED=true\"
            else
                systemctl reload nginx 2>/dev/null || systemctl restart nginx
                echo \"NGINX_RELOADED=true\"
            fi
        fi
        # Если порт всё ещё занят — принудительно останавливаем nginx
        if ss -tlnp | grep -q ':${CLOAK_PORT} '; then
            systemctl stop nginx
            systemctl disable nginx
            echo \"NGINX_FORCE_STOPPED=true\"
        fi
    else
        echo \"PORT_CONFLICT_UNRESOLVED=true\"
    fi
fi

# Запускаем
systemctl daemon-reload
systemctl enable cloak-server
systemctl restart cloak-server
sleep 2

# Проверяем
if systemctl is-active --quiet cloak-server; then
    echo 'CK_SERVER_STATUS=active'
else
    echo 'CK_SERVER_STATUS=failed'
    journalctl -u cloak-server --no-pager -n 10
fi
") || err "Не удалось установить Cloak сервер"

# Парсим ключи
get_ck() { echo "$CK_KEYS" | grep "^${1}=" | cut -d= -f2-; }
CK_PRIV=$(get_ck "CK_PRIV")
CK_PUB=$(get_ck "CK_PUB")
CK_UID=$(get_ck "CK_UID")
CK_ADMIN_UID=$(get_ck "CK_ADMIN_UID")
CK_STATUS=$(get_ck "CK_SERVER_STATUS")

[[ -z "$CK_PUB" ]] && err "Не удалось получить ключи Cloak"
[[ "$CK_STATUS" != "active" ]] && err "Cloak сервер не запустился. Проверьте логи: journalctl -u cloak-server"

ok "ck-server установлен и запущен"
log "Cloak PublicKey: $CK_PUB"
log "Cloak UID: $CK_UID"

# ── Шаг 3: Генерация клиентского конфига Cloak ────────────────────────────
step "Шаг 3/5: Генерация клиентских конфигов"

# Конфиг ck-client
CK_CLIENT_CONF="${OUTPUT_DIR}/ck-client.json"
cat > "$CK_CLIENT_CONF" << EOF
{
  "Transport": "direct",
  "ProxyMethod": "awg",
  "EncryptionMethod": "aes-gcm",
  "UID": "${CK_UID}",
  "PublicKey": "${CK_PUB}",
  "ServerName": "${FAKE_DOMAIN}",
  "NumConn": 4,
  "BrowserSig": "chrome",
  "StreamTimeout": 300
}
EOF
ok "Конфиг ck-client: ${BOLD}${CK_CLIENT_CONF}${NC}"

# Инструкция для клиента
CK_README="${OUTPUT_DIR}/cloak-setup.md"
cat > "$CK_README" << 'MKEOF'
# Настройка Cloak на клиенте

## Что это даёт
Провайдер видит обычный HTTPS-трафик к yandex.ru вместо VPN.

## Схема работы
```
AmneziaWG → ck-client (localhost:1984) → TLS (SNI=yandex.ru) → VPS1:443 → ck-server → awg1
```

## Установка (Windows)

MKEOF

cat >> "$CK_README" << EOF
1. Скачайте ck-client: https://github.com/cbeuw/Cloak/releases/tag/v${CLOAK_VERSION}
2. Поместите \`ck-client.exe\` и \`ck-client.json\` в одну папку
3. Запустите:
   \`\`\`
   ck-client.exe -c ck-client.json -s ${VPS1_IP} -p ${CLOAK_PORT} -l 127.0.0.1:1984 -u
   \`\`\`
4. В AmneziaWG клиенте измените Endpoint на:
   \`\`\`
   Endpoint = 127.0.0.1:1984
   \`\`\`
EOF

cat >> "$CK_README" << 'MKEOF'

## Установка (Linux/macOS)

1. Скачайте ck-client для вашей платформы
2. Запустите:
   ```
MKEOF

cat >> "$CK_README" << EOF
   ck-client -c ck-client.json -s ${VPS1_IP} -p ${CLOAK_PORT} -l 127.0.0.1:1984 -u
EOF

cat >> "$CK_README" << 'MKEOF'
   ```
3. Настройте AmneziaWG Endpoint на `127.0.0.1:1984`

## Установка (Android)

1. Установите Cloak из [F-Droid](https://f-droid.org/) или скачайте APK
2. Импортируйте `ck-client.json`
MKEOF

cat >> "$CK_README" << EOF
3. Укажите Server: \`${VPS1_IP}\`, Port: \`${CLOAK_PORT}\`, Local port: \`1984\`
EOF

cat >> "$CK_README" << 'MKEOF'
4. В AmneziaWG укажите Endpoint `127.0.0.1:1984`

## Проверка

После запуска ck-client проверьте, что VPN работает.
Провайдер увидит только TLS-соединение к вашему VPS с SNI=yandex.ru.
MKEOF

ok "Инструкция: ${BOLD}${CK_README}${NC}"

# Модифицированный client.conf с Cloak endpoint
if [[ -f "${OUTPUT_DIR}/client.conf" ]]; then
    CK_CLIENT_WG="${OUTPUT_DIR}/client-cloak.conf"
    # Копируем существующий конфиг, меняем Endpoint
    sed "s|^Endpoint.*=.*|Endpoint            = 127.0.0.1:1984|" \
        "${OUTPUT_DIR}/client.conf" > "$CK_CLIENT_WG"
    ok "AmneziaWG конфиг для Cloak: ${BOLD}${CK_CLIENT_WG}${NC}"
fi

# Сохраняем ключи Cloak
CK_KEYS_FILE="${OUTPUT_DIR}/cloak-keys.env"
cat > "$CK_KEYS_FILE" << EOF
# Cloak keys (ХРАНИТЬ В ТАЙНЕ)
CK_PRIV=${CK_PRIV}
CK_PUB=${CK_PUB}
CK_UID=${CK_UID}
CK_ADMIN_UID=${CK_ADMIN_UID}
FAKE_DOMAIN=${FAKE_DOMAIN}
CLOAK_PORT=${CLOAK_PORT}
EOF
chmod 600 "$CK_KEYS_FILE"

# ── Шаг 4: Авторотация доменов ─────────────────────────────────────────────
step "Шаг 4/5: Настройка авторотации доменов"

ROTATE_SCRIPT="${SCRIPT_DIR}/cloak-rotate-domain.sh"
if [[ ! -f "$ROTATE_SCRIPT" ]]; then
    warn "Скрипт ротации не найден: $ROTATE_SCRIPT"
else
    log "Устанавливаю скрипт ротации доменов на VPS1..."
    upload1 "$ROTATE_SCRIPT" /tmp/cloak-rotate-domain.sh
    run1 "sudo mv /tmp/cloak-rotate-domain.sh /etc/cloak/cloak-rotate-domain.sh && \
          sudo chmod +x /etc/cloak/cloak-rotate-domain.sh"

    # Устанавливаем cron (каждые 6 часов, идемпотентно)
    CRON_LINE="0 */6 * * * /etc/cloak/cloak-rotate-domain.sh >> /var/log/cloak-rotate.log 2>&1"
    run1 "( sudo crontab -l 2>/dev/null | grep -v 'cloak-rotate-domain'; echo '${CRON_LINE}' ) | sudo crontab -"
    ok "Авторотация: каждые 6 часов (cron)"

    # Показываем текущий домен
    CURRENT=$(run1 "grep -oP '\"RedirAddr\"\\s*:\\s*\"\\K[^\"]+' /etc/cloak/ckserver.json 2>/dev/null || echo 'N/A'")
    log "Текущий маскировочный домен: ${BOLD}${CURRENT}${NC}"
    log "Список: yandex.ru, mail.ru, vk.com, ok.ru, dzen.ru, avito.ru, ozon.ru..."
fi

# Копируем клиентский скрипт ротации в output
CLIENT_ROTATE="${SCRIPT_DIR}/cloak-rotate-client.sh"
if [[ -f "$CLIENT_ROTATE" ]]; then
    cp "$CLIENT_ROTATE" "${OUTPUT_DIR}/cloak-rotate-client.sh"
    chmod +x "${OUTPUT_DIR}/cloak-rotate-client.sh"
    ok "Клиентский скрипт ротации: ${BOLD}${OUTPUT_DIR}/cloak-rotate-client.sh${NC}"
fi

# ── Шаг 5: Верификация ────────────────────────────────────────────────────
step "Шаг 5/5: Проверка работоспособности"

VERIFY=$(run1 "
# Проверяем что ck-server слушает порт
if ss -tlnp | grep -q ':${CLOAK_PORT}'; then
    echo 'PORT_OK=true'
else
    echo 'PORT_OK=false'
fi

# Проверяем что сервис активен
if systemctl is-active --quiet cloak-server; then
    echo 'SERVICE_OK=true'
else
    echo 'SERVICE_OK=false'
fi

# Проверяем что awg1 тоже активен (Cloak пробрасывает туда)
if systemctl is-active --quiet awg-quick@awg1; then
    echo 'AWG1_OK=true'
else
    echo 'AWG1_OK=false'
fi
") || warn "Не удалось выполнить проверку"

PORT_OK=$(echo "$VERIFY" | grep "^PORT_OK=" | cut -d= -f2-)
SERVICE_OK=$(echo "$VERIFY" | grep "^SERVICE_OK=" | cut -d= -f2-)
AWG1_OK=$(echo "$VERIFY" | grep "^AWG1_OK=" | cut -d= -f2-)

[[ "$PORT_OK" == "true" ]]    && ok "ck-server слушает порт ${CLOAK_PORT}" || warn "Порт ${CLOAK_PORT} не открыт"
[[ "$SERVICE_OK" == "true" ]] && ok "Сервис cloak-server активен" || warn "Сервис cloak-server не активен"
[[ "$AWG1_OK" == "true" ]]    && ok "AmneziaWG (awg1) активен" || warn "awg1 не активен — Cloak не сможет пробросить трафик"

# ── Итог ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║             CLOAK ДЕПЛОЙ ЗАВЕРШЁН ✓                         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}Что видит провайдер:${NC}"
echo -e "  TLS-соединение к ${BOLD}${VPS1_IP}:${CLOAK_PORT}${NC} с SNI=${BOLD}${FAKE_DOMAIN}${NC}"
echo -e "  (неотличимо от обычного HTTPS)"
echo ""
echo -e "  ${GREEN}Файлы клиента:${NC}"
echo -e "  Cloak конфиг:   ${BOLD}${CK_CLIENT_CONF}${NC}"
[[ -f "${OUTPUT_DIR}/client-cloak.conf" ]] && \
echo -e "  AmneziaWG conf: ${BOLD}${OUTPUT_DIR}/client-cloak.conf${NC}"
echo -e "  Инструкция:     ${BOLD}${CK_README}${NC}"
echo ""
echo -e "  ${GREEN}Авторотация доменов:${NC}"
echo -e "  Сервер: cron каждые 6 часов (RedirAddr)"
echo -e "  Клиент: ${BOLD}bash cloak-rotate-client.sh${NC} (ServerName)"
echo -e "  Домены: yandex.ru, mail.ru, vk.com, ok.ru, dzen.ru, avito.ru, ..."
echo ""
echo -e "  ${GREEN}Запуск на клиенте:${NC}"
echo -e "  ${BOLD}ck-client -c ck-client.json -s ${VPS1_IP} -p ${CLOAK_PORT} -l 127.0.0.1:1984 -u${NC}"
echo -e "  Затем в AmneziaWG: Endpoint = 127.0.0.1:1984"
echo ""
