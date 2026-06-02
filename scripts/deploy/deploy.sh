#!/bin/bash
# =============================================================================
# AmneziaWG + AdGuard Home — автоматический деплой двухузлового VPN туннеля
#
# Схема:
#   [Клиент] → AmneziaWG (Junk обфускация) → [VPS1] → AmneziaWG туннель → [VPS2]
#                                                                              ↓
#                                                                       AdGuard Home
#                                                                              ↓
#                                                                         Интернет
#
# Использование:
#   bash deploy.sh [опции]
#
# Опции:
#   --vps1-ip       IP адрес VPS1 (точка входа, обфускация)
#   --vps1-user     Пользователь на VPS1 (default: root)
#   --vps1-key      Путь к SSH ключу для VPS1
#   --vps1-pass     Пароль для VPS1 (если нет ключа)
#   --vps2-ip       IP адрес VPS2 (точка выхода, AdGuard)
#   --vps2-user     Пользователь на VPS2 (default: root)
#   --vps2-key      Путь к SSH ключу для VPS2
#   --vps2-pass     Пароль для VPS2 (если нет ключа)
#   --client-ip     IP клиента в VPN сети (default: 10.9.0.2)
#   --adguard-pass  Пароль для AdGuard Home Web UI (обязательный, без дефолта)
#   --output-dir    Куда сохранить клиентский конфиг (default: ./vpn-output)
#   --help          Показать эту справку
#
# Примеры:
#   # С SSH ключом:
#   bash deploy.sh --vps1-ip 89.169.172.51 --vps1-user slava --vps1-key .ssh/ssh-key-1772056840349 \
#                  --vps2-ip 38.135.122.81  --vps2-key .ssh/id_rsa
#
#   # С паролем (нужен sshpass):
#   bash deploy.sh --vps1-ip 1.2.3.4 --vps1-user root --vps1-pass "mypass" \
#                  --vps2-ip 5.6.7.8 --vps2-user root --vps2-pass "mypass2"
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

SSH_BIN="${SSH_BIN:-ssh}"
SCP_BIN="${SCP_BIN:-scp}"
SSHPASS_BIN="${SSHPASS_BIN:-sshpass}"

# ── Параметры по умолчанию ─────────────────────────────────────────────────
VPS1_IP=""; VPS1_USER=""; VPS1_KEY=""; VPS1_PASS=""
VPS2_IP=""; VPS2_USER=""; VPS2_KEY=""; VPS2_PASS=""
CLIENT_VPN_IP="10.9.0.2"
ADGUARD_PASS=""
OUTPUT_DIR="./vpn-output"
SECURITY_UPDATE_SCRIPT="${SCRIPT_DIR}/security-update.sh"
SECURITY_HARDEN_SCRIPT="${SCRIPT_DIR}/security-harden.sh"

# Внутренняя адресация (менять не нужно)
TUN_NET="10.8.0"       # VPS1=10.8.0.1, VPS2=10.8.0.2
CLIENT_NET="10.9.0"    # VPS1=10.9.0.1, клиент=10.9.0.2
VPS1_PORT_CLIENTS=51820  # порт для клиентов (с Junk)
VPS1_PORT_TUNNEL=51821   # порт туннеля VPS1→VPS2
VPS2_PORT=51820          # порт на VPS2

# Загружаем дефолты из .env и keys.env (CLI-аргументы ниже перезапишут)
load_defaults_from_files

# ── Парсинг аргументов ─────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps1-ip)     VPS1_IP="$2";      shift 2 ;;
        --vps1-user)   VPS1_USER="$2";    shift 2 ;;
        --vps1-key)    VPS1_KEY="$2";     shift 2 ;;
        --vps1-pass)   VPS1_PASS="$2";    shift 2 ;;
        --vps2-ip)     VPS2_IP="$2";      shift 2 ;;
        --vps2-user)   VPS2_USER="$2";    shift 2 ;;
        --vps2-key)    VPS2_KEY="$2";     shift 2 ;;
        --vps2-pass)   VPS2_PASS="$2";    shift 2 ;;
        --client-ip)   CLIENT_VPN_IP="$2"; shift 2 ;;
        --adguard-pass) ADGUARD_PASS="$2"; shift 2 ;;
        --output-dir)  OUTPUT_DIR="$2";   shift 2 ;;
        --with-proxy|--remove-adguard)
            err "$1 удалён: legacy proxy больше не поддерживается. Используйте AdGuard Home через обычный deploy."
            ;;
        --help|-h)
            sed -n '/^# Использование/,/^# ====/p' "$0" | grep -v "^# ====" | sed 's/^# \?//'
            exit 0 ;;
        *) err "Неизвестный параметр: $1" ;;
    esac
done

# ── Фоллбэк: если USER не задан ни в .env, ни через CLI — используем root ──
VPS1_USER="${VPS1_USER:-root}"
VPS2_USER="${VPS2_USER:-root}"

# ── Подготовка SSH-ключей ──────────────────────────────────────────────────
VPS1_KEY="$(expand_tilde "$VPS1_KEY")"
VPS2_KEY="$(expand_tilde "$VPS2_KEY")"
VPS1_KEY="$(auto_pick_key_if_missing "$VPS1_KEY")"
VPS2_KEY="$(auto_pick_key_if_missing "$VPS2_KEY")"

# ── Проверка обязательных параметров ───────────────────────────────────────
require_vars "deploy.sh" VPS1_IP VPS2_IP
[[ -z "$VPS1_KEY" && -z "$VPS1_PASS" ]] && err "Укажите --vps1-key или --vps1-pass (или VPS1_KEY в .env)"
[[ -z "$VPS2_KEY" && -z "$VPS2_PASS" ]] && err "Укажите --vps2-key или --vps2-pass (или VPS2_KEY в .env)"

# Ключи с /mnt/ (WSL/Windows) копируем во временные файлы — иначе SSH может падать по правам
VPS1_KEY="$(prepare_key_for_ssh "$VPS1_KEY")"
VPS2_KEY="$(prepare_key_for_ssh "$VPS2_KEY")"
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

run2() {
    local -a ssh_opts=(-T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=no)
    if [[ -n "$VPS2_KEY" ]]; then
        "$SSH_BIN" "${ssh_opts[@]}" -i "$VPS2_KEY" "${VPS2_USER}@${VPS2_IP}" "$@" 2>&1
    else
        "$SSHPASS_BIN" -p "$VPS2_PASS" "$SSH_BIN" "${ssh_opts[@]}" "${VPS2_USER}@${VPS2_IP}" "$@" 2>&1
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

upload2() { local f=$1; local dst=${2:-/tmp/$(basename $f)}
    local -a scp_opts=(-o StrictHostKeyChecking=accept-new)
    local src="$f"
    if [[ "$SCP_BIN" == *".exe" ]]; then
        src="$(_path_for_native_ssh "$f")"
    fi
    if [[ -n "$VPS2_KEY" ]]; then
        "$SCP_BIN" "${scp_opts[@]}" -i "$VPS2_KEY" "$src" "${VPS2_USER}@${VPS2_IP}:${dst}" 2>&1
    else
        "$SSHPASS_BIN" -p "$VPS2_PASS" "$SCP_BIN" "${scp_opts[@]}" "$src" "${VPS2_USER}@${VPS2_IP}:${dst}" 2>&1
    fi
}

run_script1() { local script=$1; local tmp=$(mktemp /tmp/deploy_XXXX.sh)
    echo "$script" > "$tmp"; upload1 "$tmp" /tmp/_deploy_step.sh; rm "$tmp"
    run1 "sudo bash /tmp/_deploy_step.sh"
}

run_script2() { local script=$1; local tmp=$(mktemp /tmp/deploy_XXXX.sh)
    echo "$script" > "$tmp"; upload2 "$tmp" /tmp/_deploy_step.sh; rm "$tmp"
    run2 "sudo bash /tmp/_deploy_step.sh"
}

# ── Проверка зависимостей ──────────────────────────────────────────────────
if [[ -n "$VPS1_PASS" || -n "$VPS2_PASS" ]]; then
    check_deps --need-sshpass
else
    check_deps
fi

# ── Генерация ключей ───────────────────────────────────────────────────────
gen_key_pair() {
    # Генерируем пару ключей локально через ssh-keygen (curve25519)
    local tmp=$(mktemp)
    # Используем wg или openssl для генерации WireGuard ключей
    if command -v wg &>/dev/null; then
        local priv=$(wg genkey)
        local pub=$(echo "$priv" | wg pubkey)
    else
        # Генерируем через openssl если wg недоступен
        local priv=$(openssl genpkey -algorithm x25519 2>/dev/null | \
            openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64)
        # Fallback: генерируем на VPS1
        local priv="GENERATE_ON_SERVER"
        local pub="GENERATE_ON_SERVER"
    fi
    echo "$priv $pub"
}

# ── Начало деплоя ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   AmneziaWG + AdGuard Home — Автодеплой VPN туннеля         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
log "VPS1 (точка входа):  ${BOLD}${VPS1_USER}@${VPS1_IP}${NC}"
log "VPS2 (точка выхода): ${BOLD}${VPS2_USER}@${VPS2_IP}${NC}"
log "Клиентский IP в VPN: ${BOLD}${CLIENT_VPN_IP}${NC}"
echo ""

mkdir -p "$OUTPUT_DIR"
[[ -f "$SECURITY_UPDATE_SCRIPT" ]] || err "Не найден скрипт обновлений: $SECURITY_UPDATE_SCRIPT"
[[ -f "$SECURITY_HARDEN_SCRIPT" ]] || err "Не найден скрипт hardening: $SECURITY_HARDEN_SCRIPT"
[[ -z "$ADGUARD_PASS" ]] && err "Укажите --adguard-pass (пароль для AdGuard Home). Пароль admin123 запрещён."
[[ "$ADGUARD_PASS" == "admin123" ]] && err "Пароль admin123 слишком слабый. Укажите надёжный пароль через --adguard-pass"

# ── Шаг 1: Проверка подключения ────────────────────────────────────────────
step "Шаг 1/8: Проверка SSH подключений"

log "Подключаюсь к VPS1..."
VPS1_OS=$(run1 "cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"'") || {
    echo -e "${RED}Детали SSH (VPS1):${NC}" >&2
    if [[ -n "$VPS1_KEY" ]]; then
        "$SSH_BIN" -v -o ConnectTimeout=10 -o BatchMode=yes -i "$VPS1_KEY" "${VPS1_USER}@${VPS1_IP}" "echo ok" 2>&1 | tail -20 >&2
    else
        "$SSHPASS_BIN" -p "$VPS1_PASS" "$SSH_BIN" -v -o ConnectTimeout=10 "${VPS1_USER}@${VPS1_IP}" "echo ok" 2>&1 | tail -20 >&2
    fi
    err "Не удалось подключиться к VPS1 (${VPS1_IP}). Проверьте: сеть, ключ (VPS1_KEY), пользователя (VPS1_USER), что sshd слушает порт 22."
}
ok "VPS1: $VPS1_OS"

log "Подключаюсь к VPS2..."
VPS2_OS=$(run2 "cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"'") \
    || err "Не удалось подключиться к VPS2 (${VPS2_IP})"
ok "VPS2: $VPS2_OS"

# ── Шаг 2: Обновления безопасности ─────────────────────────────────────────
step "Шаг 2/8: Обновления безопасности на VPS1 и VPS2"

log "Обновляю VPS1 (upgrade/dist-upgrade)..."
upload1 "$SECURITY_UPDATE_SCRIPT" /tmp/security-update.sh >/dev/null
run1 "sudo bash /tmp/security-update.sh"
ok "Обновления безопасности применены на VPS1"

log "Обновляю VPS2 (upgrade/dist-upgrade)..."
upload2 "$SECURITY_UPDATE_SCRIPT" /tmp/security-update.sh >/dev/null
run2 "sudo bash /tmp/security-update.sh"
ok "Обновления безопасности применены на VPS2"

step "Шаг 2.5/8: Security hardening на VPS1 и VPS2"

log "Hardening VPS1..."
upload1 "$SECURITY_HARDEN_SCRIPT" /tmp/security-harden.sh >/dev/null
run1 "sudo bash /tmp/security-harden.sh --role vps1 --vpn-port ${VPS1_PORT_CLIENTS} --vpn-net ${TUN_NET}.0/24 --client-net ${CLIENT_NET}.0/24"
ok "VPS1 hardening завершён"

log "Hardening VPS2..."
upload2 "$SECURITY_HARDEN_SCRIPT" /tmp/security-harden.sh >/dev/null
run2 "sudo bash /tmp/security-harden.sh --role vps2 --vpn-port ${VPS2_PORT} --vpn-net ${TUN_NET}.0/24 --client-net ${CLIENT_NET}.0/24 --adguard-bind ${TUN_NET}.2"
ok "VPS2 hardening завершён"

# ── Шаг 3: Подготовка ключей на VPS1 ──────────────────────────────────────
step "Шаг 3/8: Подготовка WireGuard ключей"

log "Проверяю существующий tunnel public key на VPS2..."
VPS2_EXISTING_TUNNEL_INFO=$(run_script2 '
read_interface_private_key() {
    local conf="$1"
    awk '"'"'
        /^\[Interface\]/{iface=1; next}
        /^\[/{iface=0}
        iface && /^[[:space:]]*PrivateKey[[:space:]]*=/{
            sub(/^[^=]*=/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            print $0
            exit
        }
    '"'"' "$conf" 2>/dev/null || true
}

CONF=/etc/amnezia/amneziawg/awg0.conf
if [[ ! -f "$CONF" ]]; then
    echo "VPS2_EXISTING_TUNNEL_PUB="
    exit 0
fi

priv="$(read_interface_private_key "$CONF")"
[[ -n "$priv" ]] || { echo "Existing VPS2 awg0.conf has no Interface PrivateKey" >&2; exit 1; }
if command -v awg >/dev/null 2>&1; then
    pub="$(printf "%s\n" "$priv" | awg pubkey)"
elif command -v wg >/dev/null 2>&1; then
    pub="$(printf "%s\n" "$priv" | wg pubkey)"
else
    echo "Existing VPS2 awg0.conf found, but awg/wg is unavailable to derive its public key" >&2
    exit 1
fi
echo "VPS2_EXISTING_TUNNEL_PUB=${pub}"
') || err "Не удалось прочитать существующий tunnel public key на VPS2"
VPS2_EXISTING_TUNNEL_PUB="$(printf "%s\n" "$VPS2_EXISTING_TUNNEL_INFO" | awk '
    /^VPS2_EXISTING_TUNNEL_PUB=/{
        sub(/^[^=]*=/, "", $0)
        print $0
        exit
    }
')"

log "Проверяю существующие ключи на VPS1; новые создаются только если ключ отсутствует..."
KEYS=$(run_script1 '
VPS2_EXISTING_TUNNEL_PUB='"$(printf '%q' "$VPS2_EXISTING_TUNNEL_PUB")"'
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1
apt-get -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install amneziawg-tools 2>/dev/null || true
mkdir -p /etc/amnezia/keys && cd /etc/amnezia/keys

read_interface_private_key() {
    local conf="$1"
    awk '"'"'
        /^\[Interface\]/{iface=1; next}
        /^\[/{iface=0}
        iface && /^[[:space:]]*PrivateKey[[:space:]]*=/{
            sub(/^[^=]*=/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            print $0
            exit
        }
    '"'"' "$conf" 2>/dev/null || true
}

read_first_peer_public_key() {
    local conf="$1"
    awk '"'"'
        /^\[Peer\]/{peer=1; next}
        /^\[/{peer=0}
        peer && /^[[:space:]]*PublicKey[[:space:]]*=/{
            sub(/^[^=]*=/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            print $0
            exit
        }
    '"'"' "$conf" 2>/dev/null || true
}

read_interface_value() {
    local conf="$1" key="$2"
    awk -v k="$key" '"'"'
        /^\[Interface\]/{iface=1; next}
        /^\[/{iface=0}
        iface {
            line=$0
            lhs=line
            sub(/[[:space:]]*=.*$/, "", lhs)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
            if (lhs == k) {
                sub(/^[^=]*=/, "", line)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                print line
                exit
            }
        }
    '"'"' "$conf" 2>/dev/null || true
}

ensure_key_pair() {
    local name="$1" existing_priv="${2:-}" priv
    if [[ -s "${name}_priv" ]]; then
        priv="$(cat "${name}_priv")"
        echo "[preserve] ${name}_priv"
    elif [[ -n "$existing_priv" ]]; then
        priv="$existing_priv"
        printf "%s\n" "$priv" > "${name}_priv"
        echo "[preserve] ${name}_priv from existing config"
    else
        priv="$(awg genkey)"
        printf "%s\n" "$priv" > "${name}_priv"
        echo "[create] ${name}_priv"
    fi
    printf "%s\n" "$priv" | awg pubkey > "${name}_pub"
}

AWG0_CONF=/etc/amnezia/amneziawg/awg0.conf
AWG1_CONF=/etc/amnezia/amneziawg/awg1.conf

ensure_key_pair vps1_tunnel "$(read_interface_private_key "$AWG0_CONF")"
ensure_key_pair vps1_client "$(read_interface_private_key "$AWG1_CONF")"

if [[ -f "$AWG0_CONF" ]]; then
    if [[ -s vps2_tunnel_priv ]]; then
        printf "%s\n" "$(cat vps2_tunnel_priv)" | awg pubkey > vps2_tunnel_pub
        echo "[preserve] vps2_tunnel_priv"
    else
        echo "[preserve] VPS2 peer from existing awg0.conf; vps2_tunnel_priv unavailable"
    fi
elif [[ -n "$VPS2_EXISTING_TUNNEL_PUB" ]]; then
    printf "%s\n" "$VPS2_EXISTING_TUNNEL_PUB" > vps2_tunnel_pub
    echo "[preserve] VPS2 peer from existing VPS2 awg0.conf; vps2_tunnel_priv unavailable on VPS1"
else
    ensure_key_pair vps2_tunnel ""
fi

if [[ -s client_spb_priv ]]; then
    printf "%s\n" "$(cat client_spb_priv)" | awg pubkey > client_spb_pub
    echo "[preserve] client_spb_priv"
elif [[ ! -f "$AWG1_CONF" ]]; then
    awg genkey | tee client_spb_priv | awg pubkey > client_spb_pub
    echo "[create] client_spb_priv"
else
    FIRST_CLIENT_PUB="$(read_first_peer_public_key "$AWG1_CONF")"
    [[ -n "$FIRST_CLIENT_PUB" ]] && printf "%s\n" "$FIRST_CLIENT_PUB" > client_spb_pub
    echo "[preserve] awg1.conf peers; client_spb_priv unavailable"
fi

chmod 600 /etc/amnezia/keys/*

VPS2_PEER_PUB="$(read_first_peer_public_key "$AWG0_CONF")"
[[ -z "$VPS2_PEER_PUB" && -s vps2_tunnel_pub ]] && VPS2_PEER_PUB="$(cat vps2_tunnel_pub)"
VPS2_TUNNEL_PRIV_OUT=""
if [[ -n "$VPS2_PEER_PUB" && -s vps2_tunnel_priv ]]; then
    DERIVED_VPS2_PUB="$(printf "%s\n" "$(cat vps2_tunnel_priv)" | awg pubkey 2>/dev/null || true)"
    [[ "$DERIVED_VPS2_PUB" == "$VPS2_PEER_PUB" ]] && VPS2_TUNNEL_PRIV_OUT="$(cat vps2_tunnel_priv)"
fi

echo "vps1_tunnel_PRIV=$(cat vps1_tunnel_priv)"
echo "vps1_tunnel_PUB=$(cat vps1_tunnel_pub)"
echo "vps2_tunnel_PRIV=${VPS2_TUNNEL_PRIV_OUT}"
echo "vps2_tunnel_PUB=${VPS2_PEER_PUB}"
echo "vps1_client_PRIV=$(cat vps1_client_priv)"
echo "vps1_client_PUB=$(cat vps1_client_pub)"
echo "client_spb_PRIV=$(cat client_spb_priv 2>/dev/null || true)"
echo "client_spb_PUB=$(cat client_spb_pub 2>/dev/null || true)"
echo "Jc=$(read_interface_value "$AWG1_CONF" Jc || true)"
echo "Jmin=$(read_interface_value "$AWG1_CONF" Jmin || true)"
echo "Jmax=$(read_interface_value "$AWG1_CONF" Jmax || true)"
echo "S1=$(read_interface_value "$AWG1_CONF" S1 || true)"
echo "S2=$(read_interface_value "$AWG1_CONF" S2 || true)"
echo "H1=$(read_interface_value "$AWG1_CONF" H1 || true)"
echo "H2=$(read_interface_value "$AWG1_CONF" H2 || true)"
echo "H3=$(read_interface_value "$AWG1_CONF" H3 || true)"
echo "H4=$(read_interface_value "$AWG1_CONF" H4 || true)"
') || err "Не удалось подготовить ключи"

# Парсим ключи
get_key() { echo "$KEYS" | grep "^${1}=" | cut -d= -f2-; }
VPS1_TUNNEL_PRIV=$(get_key "vps1_tunnel_PRIV")
VPS1_TUNNEL_PUB=$(get_key "vps1_tunnel_PUB")
VPS2_TUNNEL_PRIV=$(get_key "vps2_tunnel_PRIV")
VPS2_TUNNEL_PUB=$(get_key "vps2_tunnel_PUB")
VPS1_CLIENT_PRIV=$(get_key "vps1_client_PRIV")
VPS1_CLIENT_PUB=$(get_key "vps1_client_PUB")
CLIENT_PRIV=$(get_key "client_spb_PRIV")
CLIENT_PUB=$(get_key "client_spb_PUB")

[[ -z "$VPS1_TUNNEL_PUB" ]] && err "Не удалось получить ключи. Убедитесь что AmneziaWG установлен."
[[ -z "$VPS2_TUNNEL_PUB" ]] && err "Не удалось получить публичный ключ VPS2 tunnel из существующего конфига или key store."

ok "Ключи подготовлены без ротации существующих значений"
log "VPS1 tunnel pub: $VPS1_TUNNEL_PUB"
log "VPS2 tunnel pub: $VPS2_TUNNEL_PUB"
log "VPS1 client pub: $VPS1_CLIENT_PUB"
log "Client pub:      $CLIENT_PUB"

Jc="$(get_key "Jc")"; Jmin="$(get_key "Jmin")"; Jmax="$(get_key "Jmax")"
S1="$(get_key "S1")"; S2="$(get_key "S2")"
H1="$(get_key "H1")"; H2="$(get_key "H2")"; H3="$(get_key "H3")"; H4="$(get_key "H4")"

Jc="${Jc:-2}"; Jmin="${Jmin:-20}"; Jmax="${Jmax:-200}"
S1="${S1:-15}"; S2="${S2:-20}"
H1="${H1:-$((RANDOM * RANDOM + RANDOM))}"
H2="${H2:-$((RANDOM * RANDOM + RANDOM + 1))}"
H3="${H3:-$((RANDOM * RANDOM + RANDOM + 2))}"
H4="${H4:-$((RANDOM * RANDOM + RANDOM + 3))}"

# ── Шаг 4: Установка AmneziaWG ─────────────────────────────────────────────
step "Шаг 4/8: Установка AmneziaWG"

INSTALL_AWG='
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1
apt-get -qq update
apt-get -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install software-properties-common openresolv
add-apt-repository -y ppa:amnezia/ppa 2>/dev/null
apt-get -qq update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install amneziawg amneziawg-tools
modprobe amneziawg 2>/dev/null || true
awg --version
'

log "Устанавливаю AmneziaWG на VPS1..."
run_script1 "$INSTALL_AWG"
ok "AmneziaWG установлен на VPS1"

log "Устанавливаю AmneziaWG на VPS2..."
run_script2 "$INSTALL_AWG"
ok "AmneziaWG установлен на VPS2"

# ── Шаг 5: Настройка VPS2 (точка выхода) ──────────────────────────────────
step "Шаг 5/8: Настройка VPS2 (точка выхода)"

run_script2 "
export DEBIAN_FRONTEND=noninteractive
MAIN_IF=\$(ip route | grep default | awk '{print \$5}' | head -1)
echo \"Основной интерфейс: \$MAIN_IF\"

mkdir -p /etc/amnezia/amneziawg

if [[ -f /etc/amnezia/amneziawg/awg0.conf ]]; then
    echo '[preserve] /etc/amnezia/amneziawg/awg0.conf already exists; not rewriting keys/peers'
else
[[ -n "${VPS2_TUNNEL_PRIV}" ]] || { echo 'Missing VPS2_TUNNEL_PRIV; refusing to create new VPS2 awg0.conf with an empty key' >&2; exit 1; }
cat > /etc/amnezia/amneziawg/awg0.conf << WGEOF
[Interface]
Address = ${TUN_NET}.2/24
PrivateKey = ${VPS2_TUNNEL_PRIV}
ListenPort = ${VPS2_PORT}

PostUp   = iptables -t nat -A POSTROUTING -s ${TUN_NET}.0/24 -o \${MAIN_IF} -j MASQUERADE
PostUp   = iptables -t nat -A POSTROUTING -s ${CLIENT_NET}.0/24 -o \${MAIN_IF} -j MASQUERADE
PostUp   = iptables -A FORWARD -i awg0 -o \${MAIN_IF} -j ACCEPT
PostUp   = iptables -A FORWARD -i \${MAIN_IF} -o awg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostUp   = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1320
PostDown = iptables -t nat -D POSTROUTING -s ${TUN_NET}.0/24 -o \${MAIN_IF} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${CLIENT_NET}.0/24 -o \${MAIN_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i awg0 -o \${MAIN_IF} -j ACCEPT
PostDown = iptables -D FORWARD -i \${MAIN_IF} -o awg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1320

[Peer]
PublicKey  = ${VPS1_TUNNEL_PUB}
AllowedIPs = ${TUN_NET}.1/32, ${CLIENT_NET}.0/24
PersistentKeepalive = 60
WGEOF
fi

chmod 600 /etc/amnezia/amneziawg/awg0.conf

# Systemd сервис
cat > /etc/systemd/system/awg-quick@.service << 'SVCEOF'
[Unit]
Description=AmneziaWG via awg-quick(8) for %I
After=network-online.target nss-lookup.target
Wants=network-online.target nss-lookup.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/awg-quick up %i
ExecStop=/usr/bin/awg-quick down %i
Environment=WG_ENDPOINT_RESOLUTION_RETRIES=infinity
[Install]
WantedBy=multi-user.target
SVCEOF

sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
sysctl -w net.core.rmem_max=67108864
sysctl -w net.core.wmem_max=67108864
sysctl -w net.core.netdev_max_backlog=16384
sysctl -w net.netfilter.nf_conntrack_max=524288 2>/dev/null || true
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true
sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
sysctl -w net.ipv4.tcp_rmem='4096 131072 16777216' 2>/dev/null || true
sysctl -w net.ipv4.tcp_wmem='4096 65536 16777216' 2>/dev/null || true
sysctl -w net.core.rmem_default=1048576 2>/dev/null || true
sysctl -w net.core.wmem_default=1048576 2>/dev/null || true
sysctl -w net.core.somaxconn=4096 2>/dev/null || true
sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null || true
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 2>/dev/null || true
sysctl -w net.ipv4.tcp_mtu_probing=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_timestamps=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_sack=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_window_scaling=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_no_metrics_save=1 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=7200 2>/dev/null || true
sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
sysctl -w net.ipv4.conf.default.rp_filter=0 2>/dev/null || true
cat > /etc/sysctl.d/99-vpn.conf << 'SYSCTLEOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.netdev_max_backlog=16384
net.netfilter.nf_conntrack_max=524288
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_rmem=4096 131072 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.core.somaxconn=4096
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_no_metrics_save=1
net.netfilter.nf_conntrack_tcp_timeout_established=7200
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
SYSCTLEOF

systemctl daemon-reload
systemctl enable awg-quick@awg0
systemctl restart awg-quick@awg0
sleep 2
awg show awg0
echo VPS2_AWG_OK
"
ok "VPS2 настроен"

# ── Шаг 6: Настройка VPS1 (точка входа) ───────────────────────────────────
step "Шаг 6/8: Настройка VPS1 (точка входа)"

run_script1 "
MAIN_IF=\$(ip route | grep default | awk '{print \$5}' | head -1)
echo \"Основной интерфейс: \$MAIN_IF\"

mkdir -p /etc/amnezia/amneziawg

# awg0: туннель к VPS2
if [[ -f /etc/amnezia/amneziawg/awg0.conf ]]; then
    echo '[preserve] /etc/amnezia/amneziawg/awg0.conf already exists; not rewriting keys/peers'
else
cat > /etc/amnezia/amneziawg/awg0.conf << WGEOF
[Interface]
Address = ${TUN_NET}.1/24
PrivateKey = ${VPS1_TUNNEL_PRIV}
ListenPort = ${VPS1_PORT_TUNNEL}
MTU = 1420
Table = off

PostUp   = iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o awg0 -j MASQUERADE

[Peer]
PublicKey           = ${VPS2_TUNNEL_PUB}
Endpoint            = ${VPS2_IP}:${VPS2_PORT}
AllowedIPs          = 0.0.0.0/0
PersistentKeepalive = 60
WGEOF
fi

# awg1: клиентский интерфейс с Junk обфускацией
if [[ -f /etc/amnezia/amneziawg/awg1.conf ]]; then
    echo '[preserve] /etc/amnezia/amneziawg/awg1.conf already exists; not rewriting keys/peers'
else
cat > /etc/amnezia/amneziawg/awg1.conf << WGEOF
[Interface]
Address = ${CLIENT_NET}.1/24
PrivateKey = ${VPS1_CLIENT_PRIV}
ListenPort = ${VPS1_PORT_CLIENTS}
DNS = ${TUN_NET}.2
MTU = 1360

Jc   = ${Jc}
Jmin = ${Jmin}
Jmax = ${Jmax}
S1   = ${S1}
S2   = ${S2}
H1   = ${H1}
H2   = ${H2}
H3   = ${H3}
H4   = ${H4}

PostUp   = iptables -t nat -A POSTROUTING -s ${CLIENT_NET}.0/24 -o awg0 -j MASQUERADE
PostUp   = iptables -A FORWARD -i awg1 -o awg0 -j ACCEPT
PostUp   = iptables -A FORWARD -i awg0 -o awg1 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostUp   = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1320
PostUp   = ip rule add from ${CLIENT_NET}.0/24 table 200
PostUp   = ip route add default via ${TUN_NET}.2 dev awg0 table 200
PostUp   = iptables -t nat -A PREROUTING -i awg1 -p udp --dport 53 -j DNAT --to-destination ${TUN_NET}.2:53
PostUp   = iptables -t nat -A PREROUTING -i awg1 -p tcp --dport 53 -j DNAT --to-destination ${TUN_NET}.2:53
PostUp   = iptables -A FORWARD -i awg1 -d 8.8.8.8,8.8.4.4,1.1.1.1,1.0.0.1 -p tcp -m multiport --dports 443,853 -j REJECT
PostDown = iptables -t nat -D POSTROUTING -s ${CLIENT_NET}.0/24 -o awg0 -j MASQUERADE
PostDown = iptables -D FORWARD -i awg1 -o awg0 -j ACCEPT
PostDown = iptables -D FORWARD -i awg0 -o awg1 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1320
PostDown = ip rule del from ${CLIENT_NET}.0/24 table 200 || true
PostDown = ip route del default via ${TUN_NET}.2 dev awg0 table 200 || true
PostDown = iptables -t nat -D PREROUTING -i awg1 -p udp --dport 53 -j DNAT --to-destination ${TUN_NET}.2:53
PostDown = iptables -t nat -D PREROUTING -i awg1 -p tcp --dport 53 -j DNAT --to-destination ${TUN_NET}.2:53
PostDown = iptables -D FORWARD -i awg1 -d 8.8.8.8,8.8.4.4,1.1.1.1,1.0.0.1 -p tcp -m multiport --dports 443,853 -j REJECT

[Peer]
PublicKey  = ${CLIENT_PUB}
AllowedIPs = ${CLIENT_VPN_IP}/32
WGEOF
fi

chmod 600 /etc/amnezia/amneziawg/*.conf

# Systemd сервис
cat > /etc/systemd/system/awg-quick@.service << 'SVCEOF'
[Unit]
Description=AmneziaWG via awg-quick(8) for %I
After=network-online.target nss-lookup.target
Wants=network-online.target nss-lookup.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/awg-quick up %i
ExecStop=/usr/bin/awg-quick down %i
Environment=WG_ENDPOINT_RESOLUTION_RETRIES=infinity
[Install]
WantedBy=multi-user.target
SVCEOF

sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
sysctl -w net.core.rmem_max=67108864
sysctl -w net.core.wmem_max=67108864
sysctl -w net.core.netdev_max_backlog=16384
sysctl -w net.netfilter.nf_conntrack_max=524288 2>/dev/null || true
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true
sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
sysctl -w net.ipv4.tcp_rmem='4096 131072 16777216' 2>/dev/null || true
sysctl -w net.ipv4.tcp_wmem='4096 65536 16777216' 2>/dev/null || true
sysctl -w net.core.rmem_default=1048576 2>/dev/null || true
sysctl -w net.core.wmem_default=1048576 2>/dev/null || true
sysctl -w net.core.somaxconn=4096 2>/dev/null || true
sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null || true
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 2>/dev/null || true
sysctl -w net.ipv4.tcp_mtu_probing=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_timestamps=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_sack=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_window_scaling=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_no_metrics_save=1 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=7200 2>/dev/null || true
sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
sysctl -w net.ipv4.conf.default.rp_filter=0 2>/dev/null || true
cat > /etc/sysctl.d/99-vpn.conf << 'SYSCTLEOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.netdev_max_backlog=16384
net.netfilter.nf_conntrack_max=524288
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_rmem=4096 131072 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.core.somaxconn=4096
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_no_metrics_save=1
net.netfilter.nf_conntrack_tcp_timeout_established=7200
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
SYSCTLEOF

systemctl daemon-reload
systemctl enable awg-quick@awg0 awg-quick@awg1
systemctl restart awg-quick@awg0
sleep 1
systemctl restart awg-quick@awg1
sleep 2
awg show all
echo VPS1_AWG_OK
"
ok "VPS1 настроен"

# ── Шаг 7: Проверка AdGuard Home на VPS2 ──────────────────────────────────
step "Шаг 7/8: Проверка AdGuard Home на VPS2"

ADGUARD_PASS_SHELL="$(printf '%q' "$ADGUARD_PASS")"

run_script2 "
export DEBIAN_FRONTEND=noninteractive
set -e
ADGUARD_PASS=${ADGUARD_PASS_SHELL}

# Освобождаем порт 53 от systemd-resolved
mkdir -p /etc/systemd/resolved.conf.d
RESOLVED_CONF=/etc/systemd/resolved.conf.d/adguard.conf
RESOLVED_TMP=\$(mktemp)
cat > \"\$RESOLVED_TMP\" << 'EOF'
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
EOF
if [[ ! -f \"\$RESOLVED_CONF\" ]] || ! cmp -s \"\$RESOLVED_TMP\" \"\$RESOLVED_CONF\"; then
    cp -f \"\$RESOLVED_TMP\" \"\$RESOLVED_CONF\"
    systemctl restart systemd-resolved 2>/dev/null || true
    sleep 1
else
    echo '[preserve] /etc/systemd/resolved.conf.d/adguard.conf unchanged; not restarting systemd-resolved'
fi
rm -f \"\$RESOLVED_TMP\"

ADGUARD_WAS_ACTIVE=0
if systemctl is-active --quiet AdGuardHome 2>/dev/null || systemctl is-active --quiet adguardhome 2>/dev/null; then
    ADGUARD_WAS_ACTIVE=1
fi
LEGACY_YOUTUBE_PROXY_ACTIVE=0
if systemctl is-active --quiet youtube-proxy 2>/dev/null; then
    LEGACY_YOUTUBE_PROXY_ACTIVE=1
fi
ADGUARD_CONFIG_BACKUP=/tmp/AdGuardHome.yaml.pre-deploy
ADGUARD_CONFIG_EXISTED=0
if [[ -f /opt/AdGuardHome/AdGuardHome.yaml ]]; then
    ADGUARD_CONFIG_EXISTED=1
    cp -f /opt/AdGuardHome/AdGuardHome.yaml \"\$ADGUARD_CONFIG_BACKUP\"
else
    rm -f \"\$ADGUARD_CONFIG_BACKUP\"
fi

# Скачиваем и устанавливаем AdGuard Home
cd /tmp
rm -rf /tmp/AdGuardHome /tmp/agh.tar.gz
curl -fsSL https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz -o agh.tar.gz
tar -xzf agh.tar.gz
cd AdGuardHome
./AdGuardHome -s install 2>/dev/null || true
sleep 2

if [[ ! -x /opt/AdGuardHome/AdGuardHome ]]; then
    echo 'AdGuard Home binary not found after install; keeping existing DNS service intact' >&2
    exit 1
fi

/opt/AdGuardHome/AdGuardHome -s stop 2>/dev/null || true
sleep 1

# Конфиг
if [[ \"\$ADGUARD_CONFIG_EXISTED\" == \"1\" ]]; then
    echo '[preserve] /opt/AdGuardHome/AdGuardHome.yaml already exists; not rewriting AdGuard config'
else
generate_adguard_hash() {
    local hash
    if command -v python3 >/dev/null 2>&1; then
        hash=\$(AGH_PLAIN_PASS=\"\$ADGUARD_PASS\" python3 - <<'PY' 2>/dev/null
import os
import bcrypt

print(bcrypt.hashpw(os.environ['AGH_PLAIN_PASS'].encode(), bcrypt.gensalt(10)).decode())
PY
)
        if [[ -n \"\$hash\" ]]; then
            printf '%s\n' \"\$hash\"
            return 0
        fi
    fi

    if ! command -v htpasswd >/dev/null 2>&1; then
        apt-get -y -qq -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\" install apache2-utils >/dev/null 2>&1 || true
    fi
    if command -v htpasswd >/dev/null 2>&1; then
        hash=\$(printf '%s\n' \"\$ADGUARD_PASS\" | htpasswd -Bni admin 2>/dev/null | sed 's/^[^:]*://')
        if [[ -n \"\$hash\" ]]; then
            printf '%s\n' \"\$hash\"
            return 0
        fi
    fi
    return 1
}

AGH_PASS_HASH=\$(generate_adguard_hash) || {
    echo 'Не удалось сгенерировать bcrypt-хэш пароля AdGuard Home на VPS2 (python3-bcrypt или apache2-utils недоступны)' >&2
    exit 1
}

cat > /opt/AdGuardHome/AdGuardHome.yaml << AGHEOF
http:
  address: ${TUN_NET}.2:3000
users:
  - name: admin
    password: '\${AGH_PASS_HASH}'
dns:
  bind_hosts:
    - ${TUN_NET}.2
    - 127.0.0.1
  port: 53
  upstream_dns:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
    - tls://1.1.1.1
    - tls://8.8.8.8
  bootstrap_dns:
    - 9.9.9.10
    - 149.112.112.10
  upstream_mode: load_balance
  cache_size: 4194304
  enable_dnssec: true
  refuse_any: true
  ratelimit: 20
filtering:
  filtering_enabled: true
  protection_enabled: true
  filters_update_interval: 24
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
    name: AdAway Default Blocklist
    id: 2
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_4.txt
    name: Dan Pollock's List
    id: 4
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_24.txt
    name: NoCoin Filter List
    id: 24
querylog:
  interval: 24h
  enabled: true
  file_enabled: false
statistics:
  interval: 168h
  enabled: true
schema_version: 28
AGHEOF
fi

restore_previous_dns() {
    /opt/AdGuardHome/AdGuardHome -s stop 2>/dev/null || true
    if [[ -f \"\$ADGUARD_CONFIG_BACKUP\" ]]; then
        cp -f \"\$ADGUARD_CONFIG_BACKUP\" /opt/AdGuardHome/AdGuardHome.yaml
    fi
    if [[ \"\$ADGUARD_WAS_ACTIVE\" == \"1\" ]]; then
        /opt/AdGuardHome/AdGuardHome -s start 2>/dev/null || \
            systemctl start AdGuardHome 2>/dev/null || \
            systemctl start adguardhome 2>/dev/null || true
    elif [[ \"\$LEGACY_YOUTUBE_PROXY_ACTIVE\" == \"1\" ]]; then
        systemctl start youtube-proxy 2>/dev/null || true
    fi
}

systemctl stop youtube-proxy 2>/dev/null || true
if ! /opt/AdGuardHome/AdGuardHome -s start; then
    restore_previous_dns
    echo 'AdGuard Home failed to start; previous DNS service/config was restored when available' >&2
    exit 1
fi
sleep 3

health_ok=false
if systemctl is-active --quiet AdGuardHome 2>/dev/null || systemctl is-active --quiet adguardhome 2>/dev/null; then
    if ss -lunt 2>/dev/null | grep -qE ':53[[:space:]]'; then
        if command -v dig >/dev/null 2>&1; then
            dig +time=3 +tries=1 @${TUN_NET}.2 google.com +short 2>/dev/null | grep -Eq '^[0-9]+\\.' && health_ok=true
        elif getent ahostsv4 google.com >/dev/null 2>&1 || getent hosts google.com >/dev/null 2>&1; then
            health_ok=true
        fi
    fi
fi

if [[ \"\$health_ok\" != \"true\" ]]; then
    restore_previous_dns
    journalctl -u AdGuardHome -n 30 --no-pager 2>/dev/null || journalctl -u adguardhome -n 30 --no-pager 2>/dev/null || true
    echo 'AdGuard Home healthcheck failed; previous DNS service/config was restored when available' >&2
    exit 1
fi

systemctl disable youtube-proxy 2>/dev/null || true
rm -f /etc/systemd/system/youtube-proxy.service
rm -rf /opt/youtube-proxy
rm -f \"\$ADGUARD_CONFIG_BACKUP\"
systemctl daemon-reload 2>/dev/null || true

/opt/AdGuardHome/AdGuardHome -s status
echo AGH_OK
"
ok "AdGuard Home проверен на VPS2"

# ── Шаг 8: Клиентский конфиг ──────────────────────────────────────────────
step "Шаг 8/8: Проверка клиентского конфига"

CLIENT_CONF="${OUTPUT_DIR}/client.conf"
if [[ -f "$CLIENT_CONF" ]]; then
    warn "Клиентский конфиг уже существует и сохранён без изменений: ${CLIENT_CONF}"
elif [[ -n "$CLIENT_PRIV" && -n "$VPS1_CLIENT_PUB" ]]; then
cat > "$CLIENT_CONF" << EOF
[Interface]
Address    = ${CLIENT_VPN_IP}/24
PrivateKey = ${CLIENT_PRIV}
DNS        = ${TUN_NET}.2
MTU        = 1360

# AmneziaWG Junk обфускация (защита от DPI)
Jc   = ${Jc}
Jmin = ${Jmin}
Jmax = ${Jmax}
S1   = ${S1}
S2   = ${S2}
H1   = ${H1}
H2   = ${H2}
H3   = ${H3}
H4   = ${H4}

[Peer]
# VPS1 — точка входа (vpnrus.net)
PublicKey           = ${VPS1_CLIENT_PUB}
Endpoint            = vpnrus.net:${VPS1_PORT_CLIENTS}
AllowedIPs          = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    chmod 600 "$CLIENT_CONF" 2>/dev/null || true
    ok "Клиентский конфиг создан: ${BOLD}${CLIENT_CONF}${NC}"
else
    warn "Клиентский конфиг не создан: приватный ключ базового клиента недоступен, существующие серверные peer-блоки сохранены"
fi

# Сохраняем ключи для справки
if [[ -f "${OUTPUT_DIR}/keys.txt" ]]; then
    warn "Файл ключей уже существует и сохранён без изменений: ${OUTPUT_DIR}/keys.txt"
elif [[ -n "$VPS1_TUNNEL_PRIV" && -n "$VPS2_TUNNEL_PRIV" && -n "$VPS1_CLIENT_PRIV" && -n "$CLIENT_PRIV" ]]; then
cat > "${OUTPUT_DIR}/keys.txt" << EOF
=== AmneziaWG ключи (хранить в тайне!) ===

VPS1 tunnel private:  ${VPS1_TUNNEL_PRIV}
VPS1 tunnel public:   ${VPS1_TUNNEL_PUB}
VPS2 tunnel private:  ${VPS2_TUNNEL_PRIV}
VPS2 tunnel public:   ${VPS2_TUNNEL_PUB}
VPS1 client private:  ${VPS1_CLIENT_PRIV}
VPS1 client public:   ${VPS1_CLIENT_PUB}
Client private:       ${CLIENT_PRIV}
Client public:        ${CLIENT_PUB}

Junk параметры: Jc=${Jc} Jmin=${Jmin} Jmax=${Jmax} S1=${S1} S2=${S2}
H1=${H1} H2=${H2} H3=${H3} H4=${H4}
EOF
chmod 600 "${OUTPUT_DIR}/keys.txt"
    ok "Файл ключей создан: ${OUTPUT_DIR}/keys.txt"
else
    warn "Файл keys.txt не создан: часть приватных ключей недоступна локально; существующие серверные конфиги не изменялись"
fi

# ── Фиксация времени успешного деплоя на серверах ─────────────────────────
DEPLOY_TS="$(date +%s)"
if run1 "echo '${DEPLOY_TS}' | sudo tee /etc/vpn-last-deploy.ts >/dev/null && sudo chmod 644 /etc/vpn-last-deploy.ts"; then
    ok "VPS1: last deploy timestamp updated"
else
    warn "VPS1: failed to update /etc/vpn-last-deploy.ts"
fi
if run2 "echo '${DEPLOY_TS}' | sudo tee /etc/vpn-last-deploy.ts >/dev/null && sudo chmod 644 /etc/vpn-last-deploy.ts"; then
    ok "VPS2: last deploy timestamp updated"
else
    warn "VPS2: failed to update /etc/vpn-last-deploy.ts"
fi

# ── Итог ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                    ДЕПЛОЙ ЗАВЕРШЁН ✓                        ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}Схема:${NC}"
echo -e "  [Клиент ${CLIENT_VPN_IP}] → AmneziaWG+Junk → [VPS1 ${VPS1_IP}] → туннель → [VPS2 ${VPS2_IP}] → Интернет"
echo ""
if [[ -f "$CLIENT_CONF" ]]; then
    echo -e "  ${GREEN}Клиентский конфиг:${NC} ${BOLD}${CLIENT_CONF}${NC}"
else
    echo -e "  ${YELLOW}Клиентский конфиг:${NC} не создан локально; серверные peer-блоки сохранены"
fi
echo -e "  ${GREEN}Импортируй в:${NC} AmneziaVPN (https://amnezia.org/ru/downloads)"
echo ""
echo -e "  ${GREEN}AdGuard Home:${NC}"
echo -e "  URL:    http://${VPS2_IP}:3000"
echo -e "  Логин:  admin"
echo -e "  Пароль: ${ADGUARD_PASS}"
echo ""
echo -e "  ${GREEN}SSH доступ:${NC}"
echo -e "  VPS1: ssh ${VPS1_USER}@${VPS1_IP}"
echo -e "  VPS2: ssh ${VPS2_USER}@${VPS2_IP}"
echo ""
echo -e "  ${GREEN}Проверка туннеля (на VPS1):${NC}"
echo -e "  sudo awg show all"
echo -e "  ping -c3 -I awg0 ${TUN_NET}.2"
echo ""
