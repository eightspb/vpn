#!/bin/bash
# =============================================================================
# Деплой только VPS1 (точка входа: AmneziaWG + Junk обфускация)
#
# Сначала запустите этот скрипт. Он сгенерирует ключи и сохранит их в keys.env.
# Затем запустите deploy-vps2.sh с указанием --keys-file.
#
# Использование:
#   bash deploy-vps1.sh --vps1-ip IP --vps1-key KEY --vps2-ip IP [опции]
#
# Опции:
#   --vps1-ip       IP адрес VPS1
#   --vps1-user     Пользователь на VPS1 (default: root)
#   --vps1-key      Путь к SSH ключу для VPS1
#   --vps1-pass     Пароль для VPS1 (если нет ключа)
#   --vps2-ip       IP адрес VPS2 (нужен для туннеля)
#   --client-ip     IP клиента в VPN (default: 10.9.0.2)
#   --output-dir    Куда сохранить keys.env и client.conf (default: ./vpn-output)
#   --help          Справка
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
err()  { echo -e "${RED}✗ ОШИБКА:${NC} $*" >&2; exit 1; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
step() { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

VPS1_IP=""; VPS1_USER="root"; VPS1_KEY=""; VPS1_PASS=""
VPS2_IP=""
CLIENT_VPN_IP="10.9.0.2"
OUTPUT_DIR="./vpn-output"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECURITY_UPDATE_SCRIPT="${SCRIPT_DIR}/security-update.sh"

TUN_NET="10.8.0"
CLIENT_NET="10.9.0"
VPS1_PORT_CLIENTS=51820
VPS1_PORT_TUNNEL=51821
VPS2_PORT=51820

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps1-ip)     VPS1_IP="$2";      shift 2 ;;
        --vps1-user)   VPS1_USER="$2";    shift 2 ;;
        --vps1-key)    VPS1_KEY="$2";     shift 2 ;;
        --vps1-pass)   VPS1_PASS="$2";    shift 2 ;;
        --vps2-ip)     VPS2_IP="$2";      shift 2 ;;
        --client-ip)   CLIENT_VPN_IP="$2"; shift 2 ;;
        --output-dir)  OUTPUT_DIR="$2";   shift 2 ;;
        --help|-h)
            sed -n '/^# Использование/,/^# ====/p' "$0" | grep -v "^# ====" | sed 's/^# \?//'
            exit 0 ;;
        *) err "Неизвестный параметр: $1" ;;
    esac
done

[[ -z "$VPS1_IP" ]] && err "Укажите --vps1-ip"
[[ -z "$VPS2_IP" ]] && err "Укажите --vps2-ip (для туннеля)"
[[ -z "$VPS1_KEY" && -z "$VPS1_PASS" ]] && err "Укажите --vps1-key или --vps1-pass"

ssh_cmd() {
    local ip=$1; local user=$2; local key=$3; local pass=$4
    local opts="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=no"
    if [[ -n "$key" ]]; then
        echo "ssh -T -i $key $opts ${user}@${ip}"
    else
        echo "sshpass -p '$pass' ssh -T $opts ${user}@${ip}"
    fi
}

run1() { eval "$(ssh_cmd $VPS1_IP $VPS1_USER "$VPS1_KEY" "$VPS1_PASS")" "$@" 2>&1; }

upload1() {
    local f=$1; local dst=${2:-/tmp/$(basename $f)}
    if [[ -n "$VPS1_KEY" ]]; then
        scp -i "$VPS1_KEY" -o StrictHostKeyChecking=no "$f" "${VPS1_USER}@${VPS1_IP}:${dst}" 2>&1
    else
        sshpass -p "$VPS1_PASS" scp -o StrictHostKeyChecking=no "$f" "${VPS1_USER}@${VPS1_IP}:${dst}" 2>&1
    fi
}

run_script1() {
    local script=$1; local tmp=$(mktemp /tmp/deploy_XXXX.sh)
    echo "$script" > "$tmp"; upload1 "$tmp" /tmp/_deploy_step.sh; rm "$tmp"
    run1 "sudo bash /tmp/_deploy_step.sh"
}

check_deps() {
    local missing=()
    command -v ssh  &>/dev/null || missing+=("ssh")
    command -v scp  &>/dev/null || missing+=("scp")
    command -v awk  &>/dev/null || missing+=("awk")
    [[ -n "$VPS1_PASS" ]] && { command -v sshpass &>/dev/null || missing+=("sshpass"); }
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Не хватает: ${missing[*]}"
    fi
    return 0
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Деплой VPS1 (точка входа, AmneziaWG + Junk)                ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
log "VPS1: ${BOLD}${VPS1_USER}@${VPS1_IP}${NC}"
log "VPS2 (туннель): ${BOLD}${VPS2_IP}${NC}"
log "Клиентский IP: ${BOLD}${CLIENT_VPN_IP}${NC}"
echo ""

mkdir -p "$OUTPUT_DIR"
check_deps
[[ -f "$SECURITY_UPDATE_SCRIPT" ]] || err "Не найден скрипт обновлений: $SECURITY_UPDATE_SCRIPT"

step "Шаг 1/5: Проверка SSH к VPS1"
VPS1_OS=$(run1 "cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"'") \
    || err "Не удалось подключиться к VPS1 (${VPS1_IP})"
ok "VPS1: $VPS1_OS"

step "Шаг 2/5: Обновления безопасности на VPS1"
upload1 "$SECURITY_UPDATE_SCRIPT" /tmp/security-update.sh >/dev/null
run1 "sudo bash /tmp/security-update.sh" | tail -6
ok "Обновления безопасности применены на VPS1"

step "Шаг 3/5: Генерация WireGuard ключей на VPS1"
KEYS=$(run_script1 '
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1
apt-get -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install amneziawg-tools 2>/dev/null || true
if ! command -v awg >/dev/null 2>&1; then
    apt-get -qq update
    apt-get -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install software-properties-common openresolv
    add-apt-repository -y ppa:amnezia/ppa 2>/dev/null
    apt-get -qq update
    apt-get -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install amneziawg amneziawg-tools
fi
mkdir -p /etc/amnezia/keys && cd /etc/amnezia/keys
for name in vps1_tunnel vps2_tunnel vps1_client client_spb; do
    awg genkey | tee ${name}_priv | awg pubkey > ${name}_pub
done
chmod 600 /etc/amnezia/keys/*
for name in vps1_tunnel vps2_tunnel vps1_client client_spb; do
    echo "${name}_PRIV=$(cat ${name}_priv)"
    echo "${name}_PUB=$(cat ${name}_pub)"
done
') || err "Не удалось сгенерировать ключи"

get_key() { echo "$KEYS" | grep "^${1}=" | cut -d= -f2-; }
VPS1_TUNNEL_PRIV=$(get_key "vps1_tunnel_PRIV")
VPS1_TUNNEL_PUB=$(get_key "vps1_tunnel_PUB")
VPS2_TUNNEL_PRIV=$(get_key "vps2_tunnel_PRIV")
VPS2_TUNNEL_PUB=$(get_key "vps2_tunnel_PUB")
VPS1_CLIENT_PRIV=$(get_key "vps1_client_PRIV")
VPS1_CLIENT_PUB=$(get_key "vps1_client_PUB")
CLIENT_PRIV=$(get_key "client_spb_PRIV")
CLIENT_PUB=$(get_key "client_spb_PUB")

[[ -z "$VPS1_TUNNEL_PUB" ]] && err "Не удалось получить ключи. Установите AmneziaWG."
ok "Ключи сгенерированы"

H1=$((RANDOM * RANDOM + RANDOM)); H2=$((RANDOM * RANDOM + RANDOM + 1))
H3=$((RANDOM * RANDOM + RANDOM + 2)); H4=$((RANDOM * RANDOM + RANDOM + 3))

step "Шаг 4/5: Установка и настройка AmneziaWG на VPS1"
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
run_script1 "$INSTALL_AWG" | tail -3
ok "AmneziaWG установлен"

run_script1 "
MAIN_IF=\$(ip route | grep default | awk '{print \$5}' | head -1)
mkdir -p /etc/amnezia/amneziawg

cat > /etc/amnezia/amneziawg/awg0.conf << 'WGEOF'
[Interface]
Address = ${TUN_NET}.1/24
PrivateKey = ${VPS1_TUNNEL_PRIV}
ListenPort = ${VPS1_PORT_TUNNEL}
Table = off

PostUp   = iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o awg0 -j MASQUERADE

[Peer]
PublicKey           = ${VPS2_TUNNEL_PUB}
Endpoint            = ${VPS2_IP}:${VPS2_PORT}
AllowedIPs          = 0.0.0.0/0
PersistentKeepalive = 25
WGEOF

cat > /etc/amnezia/amneziawg/awg1.conf << 'WGEOF'
[Interface]
Address = ${CLIENT_NET}.1/24
PrivateKey = ${VPS1_CLIENT_PRIV}
ListenPort = ${VPS1_PORT_CLIENTS}
DNS = ${TUN_NET}.2

Jc   = 5
Jmin = 50
Jmax = 1000
S1   = 30
S2   = 40
H1   = ${H1}
H2   = ${H2}
H3   = ${H3}
H4   = ${H4}

PostUp   = iptables -t nat -A POSTROUTING -s ${CLIENT_NET}.0/24 -o awg0 -j MASQUERADE
PostUp   = iptables -A FORWARD -i awg1 -o awg0 -j ACCEPT
PostUp   = iptables -A FORWARD -i awg0 -o awg1 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostUp = ip rule add from ${CLIENT_NET}.0/24 table 200
PostUp = ip route add default via ${TUN_NET}.2 dev awg0 table 200
PostDown = iptables -t nat -D POSTROUTING -s ${CLIENT_NET}.0/24 -o awg0 -j MASQUERADE
PostDown = iptables -D FORWARD -i awg1 -o awg0 -j ACCEPT
PostDown = iptables -D FORWARD -i awg0 -o awg1 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = ip rule del from ${CLIENT_NET}.0/24 table 200 || true
PostDown = ip route del default via ${TUN_NET}.2 dev awg0 table 200 || true

[Peer]
PublicKey  = ${CLIENT_PUB}
AllowedIPs = ${CLIENT_VPN_IP}/32
WGEOF

chmod 600 /etc/amnezia/amneziawg/*.conf

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
printf 'net.ipv4.ip_forward=1\nnet.ipv6.conf.all.disable_ipv6=1\nnet.ipv6.conf.default.disable_ipv6=1\n' > /etc/sysctl.d/99-vpn.conf
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

step "Шаг 5/5: Сохранение ключей и генерация client.conf"

KEYS_ENV="${OUTPUT_DIR}/keys.env"
cat > "$KEYS_ENV" << EOF
# Ключи для deploy-vps2.sh (не удаляйте до деплоя VPS2)
VPS1_TUNNEL_PUB=${VPS1_TUNNEL_PUB}
VPS2_TUNNEL_PRIV=${VPS2_TUNNEL_PRIV}
TUN_NET=${TUN_NET}
CLIENT_NET=${CLIENT_NET}
VPS2_PORT=${VPS2_PORT}
VPS1_IP=${VPS1_IP}
VPS1_PORT_CLIENTS=${VPS1_PORT_CLIENTS}
CLIENT_VPN_IP=${CLIENT_VPN_IP}
VPS1_CLIENT_PUB=${VPS1_CLIENT_PUB}
CLIENT_PRIV=${CLIENT_PRIV}
H1=${H1}
H2=${H2}
H3=${H3}
H4=${H4}
EOF
chmod 600 "$KEYS_ENV"
ok "Ключи сохранены: ${KEYS_ENV}"

CLIENT_CONF="${OUTPUT_DIR}/client.conf"
cat > "$CLIENT_CONF" << EOF
[Interface]
Address    = ${CLIENT_VPN_IP}/24
PrivateKey = ${CLIENT_PRIV}
DNS        = ${TUN_NET}.2

Jc   = 5
Jmin = 50
Jmax = 1000
S1   = 30
S2   = 40
H1   = ${H1}
H2   = ${H2}
H3   = ${H3}
H4   = ${H4}

[Peer]
PublicKey           = ${VPS1_CLIENT_PUB}
Endpoint            = ${VPS1_IP}:${VPS1_PORT_CLIENTS}
AllowedIPs          = 0.0.0.0/0
PersistentKeepalive = 25
EOF
ok "Клиентский конфиг: ${BOLD}${CLIENT_CONF}${NC}"

echo ""
echo -e "${BOLD}Деплой VPS1 завершён.${NC}"
echo -e "Дальше запустите: ${BOLD}bash deploy-vps2.sh --vps2-ip ${VPS2_IP} --vps2-key ... --keys-file ${KEYS_ENV}${NC}"
echo ""
