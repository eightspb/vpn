#!/bin/bash
# =============================================================================
# repair-vps1.sh — Восстановление awg1.conf на VPS1 без пересоздания ключей
#
# Использование:
#   bash repair-vps1.sh
#
# Скрипт:
#   1. Читает текущие ключи из памяти ядра (awg showconf)
#   2. Восстанавливает /etc/amnezia/amneziawg/awg1.conf с DNAT правилами
#   3. Перезапускает awg-quick@awg1 для применения конфига
#   4. Проверяет результат
#
# Требования: .env с VPS1_IP, VPS1_USER, VPS1_KEY
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*" >&2; exit 1; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
info() { echo -e "  ${CYAN}→${NC} $*"; }
hdr()  { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

# ---------------------------------------------------------------------------
# Загрузка конфига из .env
# ---------------------------------------------------------------------------
read_kv() {
    local file="$1" key="$2"
    awk -F= -v k="$key" '$1==k{sub(/^[^=]*=/,"",$0); gsub(/\r/,""); gsub(/^[ \t'"'"']+|[ \t'"'"']+$/,""); print; exit}' "$file" 2>/dev/null
}

expand_path() {
    local p="${1//\\/\/}"
    if [[ "$p" =~ ^([A-Za-z]):/(.*)$ ]]; then
        p="/mnt/${BASH_REMATCH[1],,}/${BASH_REMATCH[2]}"
    fi
    [[ "$p" == "~/"* ]] && p="${HOME}/${p#'~/'}"
    echo "$p"
}

[[ -f ".env" ]] || fail ".env не найден. Создайте его по образцу .env.example"

VPS1_IP=$(read_kv .env VPS1_IP)
VPS1_USER=$(read_kv .env VPS1_USER); VPS1_USER="${VPS1_USER:-root}"
VPS1_KEY=$(expand_path "$(read_kv .env VPS1_KEY)")
VPS2_IP=$(read_kv .env VPS2_IP)

[[ -z "$VPS1_IP" ]] && fail "VPS1_IP не задан в .env"
[[ -z "$VPS2_IP" ]] && fail "VPS2_IP не задан в .env"

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o LogLevel=ERROR"
ssh1() { ssh $SSH_OPTS -i "$VPS1_KEY" "${VPS1_USER}@${VPS1_IP}" "$@" 2>&1; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         Восстановление awg1.conf на VPS1                    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
info "VPS1: ${VPS1_USER}@${VPS1_IP}"
info "VPS2: ${VPS2_IP}"
echo ""

# ---------------------------------------------------------------------------
hdr "1. Проверка SSH"
ssh1 "echo OK" | grep -q OK && ok "SSH доступен" || fail "SSH недоступен"

# ---------------------------------------------------------------------------
hdr "2. Чтение ключей из памяти ядра"

AWG1_CONF=$(ssh1 "sudo awg showconf awg1 2>/dev/null || awg showconf awg1 2>/dev/null || echo ''")
[[ -z "$AWG1_CONF" ]] && fail "Не удалось получить конфиг awg1. Интерфейс не поднят?"

VPS1_CLIENT_PRIV=$(echo "$AWG1_CONF" | awk '/^PrivateKey/{print $3; exit}')
CLIENT_PUB=$(echo "$AWG1_CONF" | awk '/^\[Peer\]/{found=1} found && /^PublicKey/{print $3; exit}')
CLIENT_VPN_IP_FULL=$(echo "$AWG1_CONF" | awk '/^\[Peer\]/{found=1} found && /^AllowedIPs/{print $3; exit}')
CLIENT_VPN_IP="${CLIENT_VPN_IP_FULL%%/*}"

H1=$(echo "$AWG1_CONF" | awk '/^H1/{print $3}')
H2=$(echo "$AWG1_CONF" | awk '/^H2/{print $3}')
H3=$(echo "$AWG1_CONF" | awk '/^H3/{print $3}')
H4=$(echo "$AWG1_CONF" | awk '/^H4/{print $3}')

[[ -z "$VPS1_CLIENT_PRIV" ]] && fail "Не удалось прочитать PrivateKey awg1"
[[ -z "$CLIENT_PUB" ]]       && fail "Не удалось прочитать PublicKey клиента"

ok "PrivateKey awg1: ${VPS1_CLIENT_PRIV:0:8}..."
ok "Client PubKey:   ${CLIENT_PUB:0:8}..."
ok "Client VPN IP:   ${CLIENT_VPN_IP}"
ok "H1=${H1} H2=${H2} H3=${H3} H4=${H4}"

# Параметры сети
TUN_NET="10.8.0"
CLIENT_NET="10.9.0"
VPS1_PORT_CLIENTS=51820

# ---------------------------------------------------------------------------
hdr "3. Восстановление awg1.conf"

info "Генерирую конфиг локально..."

TMPCONF=$(mktemp /tmp/awg1_repair_XXXXXX.conf)
cat > "$TMPCONF" << EOF
[Interface]
Address = ${CLIENT_NET}.1/24
MTU = 1280
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
PostUp   = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
PostUp   = ip rule add from ${CLIENT_NET}.0/24 table 200
PostUp   = ip route add default via ${TUN_NET}.2 dev awg0 table 200
PostDown = iptables -t nat -D POSTROUTING -s ${CLIENT_NET}.0/24 -o awg0 -j MASQUERADE
PostDown = iptables -D FORWARD -i awg1 -o awg0 -j ACCEPT
PostDown = iptables -D FORWARD -i awg0 -o awg1 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
PostDown = ip rule del from ${CLIENT_NET}.0/24 table 200 || true
PostDown = ip route del default via ${TUN_NET}.2 dev awg0 table 200 || true

# Force all DNS traffic from clients to the Proxy DNS on VPS2
PostUp   = iptables -t nat -A PREROUTING -i awg1 -p udp -m udp --dport 53 -j DNAT --to-destination ${TUN_NET}.2:53
PostUp   = iptables -t nat -A PREROUTING -i awg1 -p tcp -m tcp --dport 53 -j DNAT --to-destination ${TUN_NET}.2:53
PostDown = iptables -t nat -D PREROUTING -i awg1 -p udp -m udp --dport 53 -j DNAT --to-destination ${TUN_NET}.2:53 || true
PostDown = iptables -t nat -D PREROUTING -i awg1 -p tcp -m tcp --dport 53 -j DNAT --to-destination ${TUN_NET}.2:53 || true

# Block DoH/DoT to force DNS through our proxy
PostUp   = iptables -A FORWARD -i awg1 -d 8.8.8.8,8.8.4.4,1.1.1.1,1.0.0.1 -p tcp -m multiport --dports 443,853 -j REJECT
PostDown = iptables -D FORWARD -i awg1 -d 8.8.8.8,8.8.4.4,1.1.1.1,1.0.0.1 -p tcp -m multiport --dports 443,853 -j REJECT || true

[Peer]
PublicKey  = ${CLIENT_PUB}
AllowedIPs = ${CLIENT_VPN_IP}/32
EOF

ok "Конфиг сгенерирован: $TMPCONF"

info "Загружаю на VPS1..."
scp $SSH_OPTS -i "$VPS1_KEY" "$TMPCONF" "${VPS1_USER}@${VPS1_IP}:/tmp/awg1_repair.conf" 2>&1
ssh1 "sudo mkdir -p /etc/amnezia/amneziawg && sudo mv /tmp/awg1_repair.conf /etc/amnezia/amneziawg/awg1.conf && sudo chmod 600 /etc/amnezia/amneziawg/awg1.conf && echo OK"
rm -f "$TMPCONF"

ok "awg1.conf создан на VPS1"

# ---------------------------------------------------------------------------
hdr "4. Перезапуск awg-quick@awg1"

info "Останавливаю awg1 (снимаем старые iptables правила)..."
ssh1 "sudo systemctl stop awg-quick@awg1 2>/dev/null || true; sleep 1"

info "Запускаю awg-quick@awg1 с новым конфигом..."
ssh1 "sudo systemctl start awg-quick@awg1"
sleep 2

STATE=$(ssh1 "systemctl is-active awg-quick@awg1 2>/dev/null")
[[ "$STATE" == "active" ]] && ok "awg-quick@awg1: active" || fail "awg-quick@awg1: $STATE"

# ---------------------------------------------------------------------------
hdr "5. Проверка DNAT правил"

DNAT=$(ssh1 "iptables -t nat -L PREROUTING -n 2>/dev/null | grep -E '53|DNAT' || echo none")
if echo "$DNAT" | grep -q 'DNAT'; then
    ok "DNS DNAT правила активны:"
    echo "$DNAT" | while IFS= read -r line; do info "$line"; done
else
    warn "DNAT правила не найдены: $DNAT"
fi

# ---------------------------------------------------------------------------
hdr "6. Итог"

ok "awg1.conf восстановлен с DNAT правилами"
ok "При перезагрузке VPS1 правила будут применяться автоматически"
echo ""
info "Клиентский конфиг не изменился — переподключение не требуется"
echo ""
