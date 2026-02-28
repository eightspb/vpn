#!/usr/bin/env bash
# =============================================================================
# generate-all-configs.sh — Генерация всех 4 клиентских конфигов
#
# Создаёт:
#   vpn-output/client.conf        — компьютер (full tunnel)
#   vpn-output/phone.conf         — телефон (full tunnel)
#   vpn-output/client-split.conf  — компьютер (split: RU напрямую)
#   vpn-output/phone-split.conf   — телефон (split: RU напрямую)
#
# Также пересоздаёт пир телефона на VPS1, если приватный ключ утерян.
#
# Использование:
#   bash generate-all-configs.sh [--fix-phone-peer]
#
# Параметры берутся из .env и vpn-output/keys.txt
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
cd "$SCRIPT_DIR"

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
info() { echo -e "  ${CYAN}→${NC} $*"; }

OUTPUT_DIR="./vpn-output"
FIX_PHONE=false
[[ "${1:-}" == "--fix-phone-peer" ]] && FIX_PHONE=true

# ---------------------------------------------------------------------------
# Load config from .env and keys.env
# ---------------------------------------------------------------------------
VPS1_IP=""; VPS1_USER=""; VPS1_KEY=""; VPS1_PASS=""

load_defaults_from_files

VPS1_USER="${VPS1_USER:-root}"

VPS1_KEY="$(expand_tilde "$VPS1_KEY")"
VPS1_KEY="$(auto_pick_key_if_missing "$VPS1_KEY")"

require_vars "generate-all-configs.sh" VPS1_IP
[[ -z "$VPS1_KEY" || ! -f "$VPS1_KEY" ]] && { fail "SSH ключ не найден: $VPS1_KEY"; exit 1; }

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o LogLevel=ERROR"
ssh1() { ssh $SSH_OPTS -i "$VPS1_KEY" "${VPS1_USER}@${VPS1_IP}" "$@" 2>&1; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Генерация всех клиентских VPN-конфигов                    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
info "VPS1: ${VPS1_USER}@${VPS1_IP}"
info "Output: ${OUTPUT_DIR}/"
echo ""

mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
step "1/5: Получение параметров сервера"
# ---------------------------------------------------------------------------

SERVER_DATA=$(ssh1 '
echo "=PUB="
sudo awg show awg1 public-key
echo "=PORT="
sudo awg show awg1 listen-port
echo "=JUNK="
sudo awk "/^\[Interface\]/{f=1;next} f && /^\[/{exit} f && /^(Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4)[[:space:]]*=/{print}" /etc/amnezia/amneziawg/awg1.conf
echo "=PEERS="
sudo awg show awg1 allowed-ips
echo "=END="
')

SERVER_PUB=$(echo "$SERVER_DATA" | awk '/^=PUB=/{getline; print}')
SERVER_PORT=$(echo "$SERVER_DATA" | awk '/^=PORT=/{getline; print}')
JUNK_BLOCK=$(echo "$SERVER_DATA" | awk '/^=JUNK=/{found=1; next} found && /^=/{exit} found{print}')
PEERS_BLOCK=$(echo "$SERVER_DATA" | awk '/^=PEERS=/{found=1; next} found && /^=/{exit} found{print}')

ok "Server PublicKey: $SERVER_PUB"
ok "Server Port: $SERVER_PORT"
ok "Junk params получены"
info "Текущие пиры:"
echo "$PEERS_BLOCK" | while IFS= read -r line; do echo "    $line"; done

# ---------------------------------------------------------------------------
step "2/5: Определение клиентских ключей"
# ---------------------------------------------------------------------------

CLIENT_PRIV="IGVSWn5ahyClCI5p62ef8l0QALdfrjwCnRFo1cEAGH8="
CLIENT_PUB=$(ssh1 "printf '%s' '${CLIENT_PRIV}' | sudo awg pubkey")
CLIENT_IP="10.9.0.2"

ok "Компьютер: priv из keys.txt, pub=$CLIENT_PUB, ip=$CLIENT_IP"

# Check if client peer exists on server
if echo "$PEERS_BLOCK" | grep -q "$CLIENT_PUB"; then
    ok "Пир компьютера найден на сервере"
else
    fail "Пир компьютера НЕ найден на сервере!"
    info "Добавляю пир компьютера..."
    ssh1 "printf '\n# computer\n[Peer]\nPublicKey  = ${CLIENT_PUB}\nAllowedIPs = ${CLIENT_IP}/32\n' | sudo tee -a /etc/amnezia/amneziawg/awg1.conf >/dev/null && sudo awg set awg1 peer '${CLIENT_PUB}' allowed-ips '${CLIENT_IP}/32'"
    ok "Пир компьютера добавлен"
fi

# Phone peer — use existing key from keys.env or regenerate
PHONE_IP="10.9.0.3"
PHONE_PRIV=""
PHONE_PUB=""

# Try to load phone key from keys.env
if [[ -f "${OUTPUT_DIR}/keys.env" ]]; then
    SAVED_PHONE_PRIV=$(read_kv "${OUTPUT_DIR}/keys.env" PHONE_PRIV)
    if [[ -n "$SAVED_PHONE_PRIV" ]]; then
        SAVED_PHONE_PUB=$(ssh1 "printf '%s' '${SAVED_PHONE_PRIV}' | sudo awg pubkey")
        if echo "$PEERS_BLOCK" | grep -q "$SAVED_PHONE_PUB"; then
            PHONE_PRIV="$SAVED_PHONE_PRIV"
            PHONE_PUB="$SAVED_PHONE_PUB"
            ok "Телефон: ключ из keys.env, pub=$PHONE_PUB, ip=$PHONE_IP"
        fi
    fi
fi

if [[ -z "$PHONE_PRIV" ]]; then
    info "Пересоздаю пир телефона (приватный ключ не найден)..."
    OLD_PHONE_PUB=$(echo "$PEERS_BLOCK" | grep "${PHONE_IP}" | awk '{print $1}')

    if [[ -n "$OLD_PHONE_PUB" ]]; then
        info "Удаляю старый пир телефона (pub=$OLD_PHONE_PUB)..."
        ssh1 "sudo awg set awg1 peer '${OLD_PHONE_PUB}' remove"
        ssh1 "sudo python3 -c \"
lines = open('/etc/amnezia/amneziawg/awg1.conf').read().split('\\n')
new_lines, skip = [], False
for line in lines:
    if '${OLD_PHONE_PUB}' in line:
        while new_lines and (new_lines[-1].startswith('#') or new_lines[-1].strip() == '' or new_lines[-1].strip() == '[Peer]'):
            removed = new_lines.pop()
            if removed.strip() == '[Peer]': break
        skip = True; continue
    if skip:
        if line.startswith('AllowedIPs'): continue
        if line.strip() == '': skip = False; continue
        skip = False
    new_lines.append(line)
open('/etc/amnezia/amneziawg/awg1.conf','w').write('\\n'.join(new_lines))
\" 2>/dev/null || true"
        ok "Старый пир телефона удалён"
    fi

    PHONE_DATA=$(ssh1 "
PHONE_PRIV=\$(sudo awg genkey)
PHONE_PUB=\$(printf '%s' \"\$PHONE_PRIV\" | sudo awg pubkey)
printf '\n# phone\n[Peer]\nPublicKey  = %s\nAllowedIPs = ${PHONE_IP}/32\n' \"\$PHONE_PUB\" | sudo tee -a /etc/amnezia/amneziawg/awg1.conf >/dev/null
sudo awg set awg1 peer \"\$PHONE_PUB\" allowed-ips '${PHONE_IP}/32'
printf 'PHONE_PRIV=%s\nPHONE_PUB=%s\n' \"\$PHONE_PRIV\" \"\$PHONE_PUB\"
")

    PHONE_PRIV=$(echo "$PHONE_DATA" | awk -F= '/^PHONE_PRIV=/{print substr($0,12)}')
    PHONE_PUB=$(echo "$PHONE_DATA" | awk -F= '/^PHONE_PUB=/{print substr($0,11)}')

    [[ -z "$PHONE_PRIV" ]] && { fail "Не удалось сгенерировать ключ телефона"; exit 1; }
    ok "Телефон: новый ключ сгенерирован, pub=$PHONE_PUB, ip=$PHONE_IP"
fi

# ---------------------------------------------------------------------------
step "3/5: Генерация full-tunnel конфигов"
# ---------------------------------------------------------------------------

DNS="10.8.0.2"
ENDPOINT="${VPS1_IP}:${SERVER_PORT}"
MTU_PC=1360
MTU_PHONE=1280

write_conf() {
    local file="$1" priv="$2" addr="$3" mtu="$4" allowed="$5"
    {
        echo "[Interface]"
        echo "Address    = ${addr}"
        echo "PrivateKey = ${priv}"
        echo "DNS        = ${DNS}"
        echo "MTU        = ${mtu}"
        echo ""
        echo "$JUNK_BLOCK"
        echo ""
        echo "[Peer]"
        echo "PublicKey           = ${SERVER_PUB}"
        echo "Endpoint            = ${ENDPOINT}"
        echo "AllowedIPs          = ${allowed}"
        echo "PersistentKeepalive = 25"
    } > "$file"
}

write_conf "${OUTPUT_DIR}/client.conf" "$CLIENT_PRIV" "${CLIENT_IP}/24" "$MTU_PC" "0.0.0.0/0"
ok "client.conf (компьютер, full tunnel)"

write_conf "${OUTPUT_DIR}/phone.conf" "$PHONE_PRIV" "${PHONE_IP}/24" "$MTU_PHONE" "0.0.0.0/0"
ok "phone.conf (телефон, full tunnel)"

# ---------------------------------------------------------------------------
step "4/5: Генерация split-tunnel конфигов"
# ---------------------------------------------------------------------------

info "Скачиваю российские IP-диапазоны и вычисляю AllowedIPs..."
info "(это может занять 30-60 секунд)"

SPLIT_ALLOWED=$(python3 generate-split-config.py --print-only 2>/dev/null)

if [[ -z "$SPLIT_ALLOWED" ]]; then
    fail "Не удалось сгенерировать split AllowedIPs"
    info "Попробуйте: python3 generate-split-config.py --print-only"
    exit 1
fi

SPLIT_COUNT=$(echo "$SPLIT_ALLOWED" | tr ',' '\n' | wc -l)
ok "Split AllowedIPs: ${SPLIT_COUNT} CIDR-блоков"

write_conf "${OUTPUT_DIR}/client-split.conf" "$CLIENT_PRIV" "${CLIENT_IP}/24" "$MTU_PC" "$SPLIT_ALLOWED"
ok "client-split.conf (компьютер, split tunnel)"

write_conf "${OUTPUT_DIR}/phone-split.conf" "$PHONE_PRIV" "${PHONE_IP}/24" "$MTU_PHONE" "$SPLIT_ALLOWED"
ok "phone-split.conf (телефон, split tunnel)"

# ---------------------------------------------------------------------------
step "5/5: Обновление keys.env и keys.txt"
# ---------------------------------------------------------------------------

# Update keys.env with correct data
cat > "${OUTPUT_DIR}/keys.env" << EOF
# Ключи VPN (сгенерировано $(date +%Y-%m-%d))
VPS1_TUNNEL_PUB=$(ssh1 "sudo cat /etc/amnezia/keys/vps1_tunnel_pub 2>/dev/null || echo unknown")
VPS2_TUNNEL_PRIV=$(ssh1 "sudo cat /etc/amnezia/keys/vps2_tunnel_priv 2>/dev/null || echo unknown")
TUN_NET=10.8.0
CLIENT_NET=10.9.0
VPS2_PORT=51820
VPS1_IP=${VPS1_IP}
VPS1_PORT_CLIENTS=${SERVER_PORT}
CLIENT_VPN_IP=${CLIENT_IP}
VPS1_CLIENT_PUB=${SERVER_PUB}
CLIENT_PRIV=${CLIENT_PRIV}
PHONE_PRIV=${PHONE_PRIV}
PHONE_PUB=${PHONE_PUB}
$(echo "$JUNK_BLOCK" | awk -F'[= ]+' '{for(i=1;i<=NF;i++){if($i~/^[A-Z]/){k=$i; for(j=i+1;j<=NF;j++){if($j!=""){print k"="$j; break}}}}}')
EOF
chmod 600 "${OUTPUT_DIR}/keys.env"
ok "keys.env обновлён"

# Update keys.txt
cat > "${OUTPUT_DIR}/keys.txt" << EOF
=== AmneziaWG ключи (хранить в тайне!) ===

VPS1 server public:   ${SERVER_PUB}
Client private:       ${CLIENT_PRIV}
Client public:        ${CLIENT_PUB}
Client IP:            ${CLIENT_IP}
Phone private:        ${PHONE_PRIV}
Phone public:         ${PHONE_PUB}
Phone IP:             ${PHONE_IP}

Junk параметры:
$(echo "$JUNK_BLOCK")

Endpoint: ${ENDPOINT}
DNS:      ${DNS}
EOF
ok "keys.txt обновлён"

# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                        ГОТОВО!                              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Сгенерированные конфиги:"
echo -e "    ${GREEN}1.${NC} ${BOLD}client.conf${NC}       — компьютер (весь трафик через VPN)"
echo -e "    ${GREEN}2.${NC} ${BOLD}phone.conf${NC}        — телефон (весь трафик через VPN)"
echo -e "    ${GREEN}3.${NC} ${BOLD}client-split.conf${NC} — компьютер (RU напрямую, остальное через VPN)"
echo -e "    ${GREEN}4.${NC} ${BOLD}phone-split.conf${NC}  — телефон (RU напрямую, остальное через VPN)"
echo ""
echo -e "  Импортируйте нужный конфиг в AmneziaVPN на устройстве."
echo ""
