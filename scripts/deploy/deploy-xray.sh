#!/usr/bin/env bash
# =============================================================================
# deploy-xray.sh — деплой XRAY Reality (VLESS+Reality маскировка VPN-трафика)
#
# XRAY Reality маскирует VPN-трафик под TLS-соединение к популярному сайту.
# Провайдер видит обычный HTTPS. Работает на iOS (Streisand, V2Box, FoXray),
# Android (v2rayNG), Windows/macOS/Linux (v2rayN, Nekoray).
#
# Схема:
#   [Клиент] → VLESS+Reality (TLS, SNI=yahoo.com) → [VPS1 XRAY:443] → Интернет
#
# Использование:
#   bash deploy-xray.sh [опции]
#
# Опции:
#   --vps1-ip        IP адрес VPS1
#   --vps1-user      Пользователь на VPS1 (default: root)
#   --vps1-key       Путь к SSH ключу для VPS1
#   --vps1-pass      Пароль для VPS1 (если нет ключа)
#   --dest-domain    Домен для маскировки (default: yahoo.com)
#   --xray-port      Порт XRAY на VPS1 (default: 443)
#   --output-dir     Куда сохранить клиентский конфиг (default: ./vpn-output)
#   --help           Справка
#
# Примеры:
#   bash deploy-xray.sh --vps1-ip 130.193.41.13 --vps1-key .ssh/ssh-key
#   bash deploy-xray.sh --vps1-ip 130.193.41.13 --vps1-key .ssh/ssh-key --dest-domain microsoft.com
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$SCRIPT_DIR" =~ ^/[A-Za-z]/ ]]; then
    DRIVE=$(echo "$SCRIPT_DIR" | cut -c2 | tr '[:upper:]' '[:lower:]')
    REST=$(echo "$SCRIPT_DIR" | cut -c3-)
    SCRIPT_DIR="/mnt/${DRIVE}${REST}"
fi

source "${SCRIPT_DIR}/../../lib/common.sh"

SSH_BIN="${SSH_BIN:-ssh}"
SCP_BIN="${SCP_BIN:-scp}"
SSHPASS_BIN="${SSHPASS_BIN:-sshpass}"

# XRAY release version
XRAY_VERSION="25.1.30"

# ── Параметры по умолчанию ─────────────────────────────────────────────────
VPS1_IP=""; VPS1_USER=""; VPS1_KEY=""; VPS1_PASS=""
DEST_DOMAIN="www.microsoft.com"
XRAY_PORT=443
OUTPUT_DIR="./vpn-output"

load_defaults_from_files

# ── Парсинг аргументов ─────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps1-ip)       VPS1_IP="$2";       shift 2 ;;
        --vps1-user)     VPS1_USER="$2";     shift 2 ;;
        --vps1-key)      VPS1_KEY="$2";      shift 2 ;;
        --vps1-pass)     VPS1_PASS="$2";     shift 2 ;;
        --dest-domain)   DEST_DOMAIN="$2";   shift 2 ;;
        --xray-port)     XRAY_PORT="$2";     shift 2 ;;
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
require_vars "deploy-xray.sh" VPS1_IP
[[ -z "$VPS1_KEY" && -z "$VPS1_PASS" ]] && err "Укажите --vps1-key или --vps1-pass (или VPS1_KEY в .env)"

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
echo -e "${BOLD}║   XRAY Reality — VLESS+Reality маскировка VPN              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
log "VPS1: ${BOLD}${VPS1_USER}@${VPS1_IP}${NC}"
log "Маскировка: ${BOLD}${DEST_DOMAIN}${NC} (Reality dest)"
log "Порт XRAY: ${BOLD}${XRAY_PORT}${NC}"
echo ""

mkdir -p "$OUTPUT_DIR"

# ── Шаг 1: Проверка SSH ───────────────────────────────────────────────────
step "Шаг 1/5: Проверка SSH к VPS1"
VPS1_OS=$(run1 "cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"'") \
    || err "Не удалось подключиться к VPS1 (${VPS1_IP})"
ok "VPS1: $VPS1_OS"

# ── Шаг 2: Остановка Cloak (если запущен) ────────────────────────────────
step "Шаг 2/5: Остановка Cloak (если запущен) и установка XRAY"

log "Проверяю и останавливаю Cloak..."
run1 "
if systemctl is-active --quiet cloak-server 2>/dev/null; then
    systemctl stop cloak-server
    systemctl disable cloak-server
    echo 'CLOAK_STOPPED=true'
else
    echo 'CLOAK_STOPPED=false'
fi
" || true

log "Устанавливаю XRAY v${XRAY_VERSION}..."
XRAY_KEYS=$(run_script1 "
set -euo pipefail

# Скачиваем XRAY
cd /tmp
XRAY_URL=\"https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip\"

if ! curl -fsSL \"\${XRAY_URL}\" -o /tmp/xray.zip; then
    echo 'ОШИБКА: не удалось скачать XRAY'
    exit 1
fi

# Распаковываем
mkdir -p /tmp/xray-install
cd /tmp/xray-install
unzip -o /tmp/xray.zip
cp xray /usr/local/bin/xray
chmod +x /usr/local/bin/xray
rm -rf /tmp/xray.zip /tmp/xray-install

# Создаём директорию конфигов
mkdir -p /etc/xray

# Генерируем ключи Reality (x25519)
XRAY_KEYPAIR=\$(/usr/local/bin/xray x25519 2>&1)
XRAY_PRIV=\$(echo \"\$XRAY_KEYPAIR\" | grep 'Private' | awk '{print \$NF}')
XRAY_PUB=\$(echo \"\$XRAY_KEYPAIR\" | grep 'Public' | awk '{print \$NF}')

# Генерируем UUID для первого клиента
XRAY_UUID=\$(/usr/local/bin/xray uuid 2>&1)

# Генерируем short ID (8 символов hex)
XRAY_SHORT_ID=\$(openssl rand -hex 4)

echo \"XRAY_PRIV=\${XRAY_PRIV}\"
echo \"XRAY_PUB=\${XRAY_PUB}\"
echo \"XRAY_UUID=\${XRAY_UUID}\"
echo \"XRAY_SHORT_ID=\${XRAY_SHORT_ID}\"

# Создаём конфигурацию сервера
cat > /etc/xray/config.json << XEOF
{
  \"log\": {
    \"loglevel\": \"warning\"
  },
  \"inbounds\": [{
    \"listen\": \"0.0.0.0\",
    \"port\": ${XRAY_PORT},
    \"protocol\": \"vless\",
    \"settings\": {
      \"clients\": [
        {
          \"id\": \"\${XRAY_UUID}\",
          \"flow\": \"xtls-rprx-vision\"
        }
      ],
      \"decryption\": \"none\"
    },
    \"streamSettings\": {
      \"network\": \"tcp\",
      \"security\": \"reality\",
      \"realitySettings\": {
        \"show\": false,
        \"dest\": \"${DEST_DOMAIN}:443\",
        \"xver\": 0,
        \"serverNames\": [\"${DEST_DOMAIN}\"],
        \"privateKey\": \"\${XRAY_PRIV}\",
        \"shortIds\": [\"\${XRAY_SHORT_ID}\"]
      }
    },
    \"sniffing\": {
      \"enabled\": true,
      \"destOverride\": [\"http\", \"tls\", \"quic\"]
    }
  }],
  \"outbounds\": [{
    \"protocol\": \"freedom\",
    \"tag\": \"direct\"
  }, {
    \"protocol\": \"blackhole\",
    \"tag\": \"block\"
  }]
}
XEOF
chmod 600 /etc/xray/config.json

# Создаём systemd сервис
cat > /etc/systemd/system/xray.service << 'SVCEOF'
[Unit]
Description=XRAY Reality (VLESS+Reality traffic masking)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -c /etc/xray/config.json
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVCEOF

# Открываем порт в iptables (idempotent)
iptables -C INPUT -p tcp --dport ${XRAY_PORT} -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 5 -p tcp --dport ${XRAY_PORT} -j ACCEPT

# Освобождаем порт ${XRAY_PORT} если занят
if ss -tlnp | grep -q ':${XRAY_PORT} '; then
    BLOCKING_PROC=\$(ss -tlnp | grep ':${XRAY_PORT} ' | grep -oP '\"\\K[^\"]+' | head -1)
    echo \"PORT_BLOCKED_BY=\${BLOCKING_PROC}\"
    if [[ \"\$BLOCKING_PROC\" == \"nginx\" ]]; then
        iptables -C INPUT -p tcp --dport 8443 -j ACCEPT 2>/dev/null || \
            iptables -I INPUT 5 -p tcp --dport 8443 -j ACCEPT
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save 2>/dev/null || true
        fi
        systemctl stop nginx
        systemctl disable nginx
        echo \"NGINX_STOPPED=true\"
    fi
fi

# Запускаем
systemctl daemon-reload
systemctl enable xray
systemctl restart xray
sleep 2

# Проверяем
if systemctl is-active --quiet xray; then
    echo 'XRAY_STATUS=active'
else
    echo 'XRAY_STATUS=failed'
    journalctl -u xray --no-pager -n 10
fi
") || err "Не удалось установить XRAY"

# Парсим ключи
get_xr() { echo "$XRAY_KEYS" | grep "^${1}=" | cut -d= -f2-; }
XRAY_PRIV=$(get_xr "XRAY_PRIV")
XRAY_PUB=$(get_xr "XRAY_PUB")
XRAY_UUID=$(get_xr "XRAY_UUID")
XRAY_SHORT_ID=$(get_xr "XRAY_SHORT_ID")
XRAY_STATUS=$(get_xr "XRAY_STATUS")

[[ -z "$XRAY_PUB" ]] && err "Не удалось получить ключи XRAY"
[[ "$XRAY_STATUS" != "active" ]] && err "XRAY не запустился. Проверьте логи: journalctl -u xray"

ok "XRAY установлен и запущен"
log "XRAY PublicKey: $XRAY_PUB"
log "XRAY UUID: $XRAY_UUID"
log "XRAY ShortId: $XRAY_SHORT_ID"

# ── Шаг 3: Генерация клиентского конфига ─────────────────────────────────
step "Шаг 3/5: Генерация клиентских конфигов"

# VLESS URL для клиента
VLESS_URL="vless://${XRAY_UUID}@${VPS1_IP}:${XRAY_PORT}?type=tcp&security=reality&pbk=${XRAY_PUB}&fp=chrome&sni=${DEST_DOMAIN}&sid=${XRAY_SHORT_ID}&flow=xtls-rprx-vision#VPN-XRAY"

echo "$VLESS_URL" > "${OUTPUT_DIR}/xray-vless-url.txt"
ok "VLESS URL: ${BOLD}${OUTPUT_DIR}/xray-vless-url.txt${NC}"

# Сохраняем ключи XRAY
XRAY_KEYS_FILE="${OUTPUT_DIR}/xray-keys.env"
cat > "$XRAY_KEYS_FILE" << EOF
# XRAY Reality keys (ХРАНИТЬ В ТАЙНЕ)
XRAY_PRIV=${XRAY_PRIV}
XRAY_PUB=${XRAY_PUB}
XRAY_UUID=${XRAY_UUID}
XRAY_SHORT_ID=${XRAY_SHORT_ID}
DEST_DOMAIN=${DEST_DOMAIN}
XRAY_PORT=${XRAY_PORT}
EOF
chmod 600 "$XRAY_KEYS_FILE"
ok "Ключи XRAY: ${BOLD}${XRAY_KEYS_FILE}${NC}"

# ── Шаг 4: Инструкция для клиента ────────────────────────────────────────
step "Шаг 4/5: Генерация инструкции"

XRAY_README="${OUTPUT_DIR}/xray-setup.md"
cat > "$XRAY_README" << EOF
# Настройка XRAY Reality на клиенте

## Что это даёт
Провайдер видит обычный TLS-трафик к ${DEST_DOMAIN} вместо VPN.

## VLESS URL (для импорта)
\`\`\`
${VLESS_URL}
\`\`\`

## iOS (Streisand / V2Box / FoXray)
1. Установите **Streisand** из App Store (рекомендуется) или V2Box / FoXray
2. Скопируйте VLESS URL выше
3. В приложении: + → Импорт из буфера обмена
4. Подключитесь

## Android (v2rayNG)
1. Установите **v2rayNG** из Google Play или GitHub
2. Скопируйте VLESS URL
3. В приложении: + → Импорт из буфера обмена
4. Подключитесь

## Windows (v2rayN / Nekoray)
1. Скачайте **v2rayN** или **Nekoray**
2. Импортируйте VLESS URL
3. Подключитесь

## macOS / Linux (Nekoray)
1. Скачайте **Nekoray**
2. Импортируйте VLESS URL
3. Подключитесь

## Проверка
После подключения провайдер увидит только TLS-соединение к ${DEST_DOMAIN}.
EOF

ok "Инструкция: ${BOLD}${XRAY_README}${NC}"

# ── Шаг 5: Верификация ────────────────────────────────────────────────────
step "Шаг 5/5: Проверка работоспособности"

VERIFY=$(run1 "
if ss -tlnp | grep -q ':${XRAY_PORT}'; then
    echo 'PORT_OK=true'
else
    echo 'PORT_OK=false'
fi
if systemctl is-active --quiet xray; then
    echo 'SERVICE_OK=true'
else
    echo 'SERVICE_OK=false'
fi
") || warn "Не удалось выполнить проверку"

PORT_OK=$(echo "$VERIFY" | grep "^PORT_OK=" | cut -d= -f2-)
SERVICE_OK=$(echo "$VERIFY" | grep "^SERVICE_OK=" | cut -d= -f2-)

[[ "$PORT_OK" == "true" ]]    && ok "XRAY слушает порт ${XRAY_PORT}" || warn "Порт ${XRAY_PORT} не открыт"
[[ "$SERVICE_OK" == "true" ]] && ok "Сервис xray активен" || warn "Сервис xray не активен"

# ── Итог ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║             XRAY REALITY ДЕПЛОЙ ЗАВЕРШЁН ✓                  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}Что видит провайдер:${NC}"
echo -e "  TLS-соединение к ${BOLD}${VPS1_IP}:${XRAY_PORT}${NC} с SNI=${BOLD}${DEST_DOMAIN}${NC}"
echo -e "  (неотличимо от обычного HTTPS)"
echo ""
echo -e "  ${GREEN}VLESS URL (для импорта в клиент):${NC}"
echo -e "  ${BOLD}${VLESS_URL}${NC}"
echo ""
echo -e "  ${GREEN}Клиенты:${NC}"
echo -e "  iOS:     ${BOLD}Streisand${NC} (App Store) / V2Box / FoXray"
echo -e "  Android: ${BOLD}v2rayNG${NC} (Google Play)"
echo -e "  Windows: ${BOLD}v2rayN${NC} / Nekoray"
echo -e "  macOS:   ${BOLD}Nekoray${NC}"
echo ""
echo -e "  ${GREEN}Файлы:${NC}"
echo -e "  VLESS URL:   ${BOLD}${OUTPUT_DIR}/xray-vless-url.txt${NC}"
echo -e "  Ключи:       ${BOLD}${XRAY_KEYS_FILE}${NC}"
echo -e "  Инструкция:  ${BOLD}${XRAY_README}${NC}"
echo ""
