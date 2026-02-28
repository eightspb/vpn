#!/usr/bin/env bash
# =============================================================================
# add_phone_peer.sh — добавляет нового WireGuard-пира на VPS1 (awg1)
#
# Использование:
#   bash add_phone_peer.sh [OPTIONS]
#
# Источники настроек (по приоритету):
#   1) Аргументы CLI
#   2) ./.env
#   3) ./vpn-output/keys.env
#
# Опции:
#   --vps1-ip IP          IP-адрес VPS1
#   --vps1-user USER      SSH-пользователь VPS1 (default: root)
#   --vps1-key PATH       SSH-ключ для VPS1
#   --vps1-pass PASS      SSH-пароль для VPS1 (если без ключа)
#   --peer-ip IP          IP нового пира (default: автоопределение)
#   --peer-name NAME      Имя пира для комментария (default: phone)
#   --tun-net NET         Сеть туннеля без последнего октета (default: 10.9.0)
#   --output-dir DIR      Директория для сохранения конфига (default: ./vpn-output)
#   --help                Показать эту справку
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
cd "$SCRIPT_DIR"

VPS1_IP=""
VPS1_USER=""
VPS1_KEY=""
VPS1_PASS=""
PEER_IP=""
PEER_NAME="phone"
TUN_NET="10.9.0"
OUTPUT_DIR="./vpn-output"
SSH_TIMEOUT=15

usage() {
    cat <<'EOF'
add_phone_peer.sh — добавляет нового WireGuard-пира на VPS1 (awg1).

Использование:
  bash add_phone_peer.sh [OPTIONS]

Опции:
  --vps1-ip IP          IP-адрес VPS1 (или из .env VPS1_IP)
  --vps1-user USER      SSH-пользователь VPS1 (default: root)
  --vps1-key PATH       SSH-ключ для VPS1 (или из .env VPS1_KEY)
  --vps1-pass PASS      SSH-пароль для VPS1
  --peer-ip IP          IP нового пира (default: автоопределение следующего свободного)
  --peer-name NAME      Имя пира для комментария (default: phone)
  --tun-net NET         Сеть туннеля без последнего октета (default: 10.9.0)
  --output-dir DIR      Директория для сохранения конфига (default: ./vpn-output)
  --help                Показать эту справку

Примеры:
  bash add_phone_peer.sh --vps1-ip 130.193.41.13 --vps1-user slava --vps1-key ~/.ssh/ssh-key-1772056840349
  bash add_phone_peer.sh --peer-name tablet --peer-ip 10.9.0.5
  # Если .env заполнен — достаточно:
  bash add_phone_peer.sh
EOF
}

# ---------------------------------------------------------------------------
# SSH helper
# ---------------------------------------------------------------------------

ssh_exec() {
    local cmd="$1"
    local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    -o BatchMode=no -o ConnectTimeout="$SSH_TIMEOUT")
    if [[ -n "$VPS1_KEY" ]]; then
        ssh "${ssh_opts[@]}" -i "$VPS1_KEY" "${VPS1_USER}@${VPS1_IP}" "$cmd"
    elif [[ -n "$VPS1_PASS" ]]; then
        sshpass -p "$VPS1_PASS" ssh "${ssh_opts[@]}" "${VPS1_USER}@${VPS1_IP}" "$cmd"
    else
        ssh "${ssh_opts[@]}" "${VPS1_USER}@${VPS1_IP}" "$cmd"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

load_defaults_from_files

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps1-ip)     VPS1_IP="$2";     shift 2 ;;
        --vps1-user)   VPS1_USER="$2";   shift 2 ;;
        --vps1-key)    VPS1_KEY="$2";    shift 2 ;;
        --vps1-pass)   VPS1_PASS="$2";   shift 2 ;;
        --peer-ip)     PEER_IP="$2";     shift 2 ;;
        --peer-name)   PEER_NAME="$2";   shift 2 ;;
        --tun-net)     TUN_NET="$2";     shift 2 ;;
        --output-dir)  OUTPUT_DIR="$2";  shift 2 ;;
        --help|-h)     usage; exit 0 ;;
        *) echo "Неизвестный параметр: $1" >&2; usage; exit 1 ;;
    esac
done

VPS1_USER="${VPS1_USER:-root}"

[[ -z "$VPS1_IP" ]] && { echo "Ошибка: укажите VPS1_IP в .env или --vps1-ip" >&2; exit 1; }
[[ -z "$VPS1_KEY" && -z "$VPS1_PASS" ]] && { echo "Ошибка: укажите VPS1_KEY в .env или --vps1-key / --vps1-pass" >&2; exit 1; }

VPS1_KEY="$(expand_tilde "$VPS1_KEY")"

if [[ -n "$VPS1_PASS" ]]; then
    command -v sshpass >/dev/null 2>&1 || { echo "Для пароля нужен sshpass (sudo apt install sshpass)" >&2; exit 1; }
fi

mkdir -p "$OUTPUT_DIR"

echo "=== Добавление нового пира (${PEER_NAME}) на VPS1 (${VPS1_IP}) ==="
echo ""

# ---------------------------------------------------------------------------
# Автоопределение следующего свободного IP в туннельной сети
# ---------------------------------------------------------------------------

if [[ -z "$PEER_IP" ]]; then
    echo "[1/4] Определяю занятые IP в ${TUN_NET}.0/24..."
    USED_IPS="$(ssh_exec "sudo awg show awg1 allowed-ips 2>/dev/null | awk '{print \$2}' | grep -oE '${TUN_NET//./\\.}\\.[0-9]+' || true")"
    # Также учитываем .1 (сервер) и .2 (зарезервировано)
    NEXT_IP=""
    for i in $(seq 3 254); do
        candidate="${TUN_NET}.${i}"
        if ! echo "$USED_IPS" | grep -qF "$candidate"; then
            NEXT_IP="$candidate"
            break
        fi
    done
    if [[ -z "$NEXT_IP" ]]; then
        echo "Ошибка: нет свободных IP в диапазоне ${TUN_NET}.3-254" >&2
        exit 1
    fi
    PEER_IP="$NEXT_IP"
    echo "      Следующий свободный IP: ${PEER_IP}"
else
    echo "[1/4] Использую заданный IP: ${PEER_IP}"
fi

# ---------------------------------------------------------------------------
# Генерация ключей и добавление пира на сервере
# ---------------------------------------------------------------------------

echo "[2/4] Генерирую ключи и добавляю пира на VPS1..."

PEER_DATA="$(ssh_exec "
PHONE_PRIV=\$(sudo awg genkey)
PHONE_PUB=\$(echo \"\$PHONE_PRIV\" | sudo awg pubkey)
# Добавляем пира в конфиг (для персистентности при перезапуске)
printf '\n# %s\n[Peer]\nPublicKey  = %s\nAllowedIPs = %s/32\n' \
    '${PEER_NAME}' \"\$PHONE_PUB\" '${PEER_IP}' | sudo tee -a /etc/amnezia/amneziawg/awg1.conf >/dev/null
# Добавляем пира в живой интерфейс без перезапуска
sudo awg set awg1 peer \"\$PHONE_PUB\" allowed-ips '${PEER_IP}/32' 2>/dev/null || true
printf 'PHONE_PRIV=%s\nPHONE_PUB=%s\n' \"\$PHONE_PRIV\" \"\$PHONE_PUB\"
")"

PHONE_PRIV="$(printf '%s\n' "$PEER_DATA" | awk -F= '/^PHONE_PRIV=/{print substr($0,12)}')"
PHONE_PUB="$(printf '%s\n' "$PEER_DATA" | awk -F= '/^PHONE_PUB=/{print substr($0,11)}')"

if [[ -z "$PHONE_PRIV" || -z "$PHONE_PUB" ]]; then
    echo "Ошибка: не удалось получить ключи с сервера" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Получаем публичный ключ сервера и endpoint
# ---------------------------------------------------------------------------

echo "[3/4] Получаю параметры сервера..."

SERVER_PUB="$(ssh_exec "sudo awg show awg1 public-key 2>/dev/null || sudo cat /etc/amnezia/amneziawg/awg1.conf | awk '/^PrivateKey/{print \$3}' | sudo awg pubkey")"
SERVER_PUB="$(clean_value "$SERVER_PUB")"

# Получаем junk-параметры из конфига сервера для AmneziaWG
JUNK_PARAMS="$(ssh_exec "sudo awk '/^\[Interface\]/{found=1} found && /^(Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4)=/{print}' /etc/amnezia/amneziawg/awg1.conf 2>/dev/null || true")"

# ---------------------------------------------------------------------------
# Генерируем клиентский конфиг
# ---------------------------------------------------------------------------

echo "[4/4] Генерирую клиентский конфиг..."

CLIENT_CONF_FILE="${OUTPUT_DIR}/peer_${PEER_NAME}_${PEER_IP//./_}.conf"

{
    echo "[Interface]"
    echo "PrivateKey = ${PHONE_PRIV}"
    echo "Address    = ${PEER_IP}/24"
    echo "DNS        = ${TUN_NET}.1"
    echo "MTU        = 1280"
    if [[ -n "$JUNK_PARAMS" ]]; then
        echo ""
        echo "# AmneziaWG junk parameters"
        echo "$JUNK_PARAMS"
    fi
    echo ""
    echo "[Peer]"
    echo "PublicKey  = ${SERVER_PUB}"
    echo "AllowedIPs = 0.0.0.0/0"
    echo "Endpoint   = ${VPS1_IP}:51820"
    echo "PersistentKeepalive = 25"
} > "$CLIENT_CONF_FILE"

echo ""
echo "=== ГОТОВО ==="
echo ""
echo "  Пир:        ${PEER_NAME}"
echo "  IP пира:    ${PEER_IP}/24"
echo "  Публичный ключ пира: ${PHONE_PUB}"
echo ""
echo "  Конфиг сохранён: ${CLIENT_CONF_FILE}"
echo ""
echo "  Для подключения:"
echo "    1. Скопируйте ${CLIENT_CONF_FILE} на устройство"
echo "    2. Импортируйте в AmneziaWG"
echo ""
