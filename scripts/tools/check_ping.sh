#!/bin/bash
# Проверка пинга по всей цепочке VPN
# Запускать на VPS1: sudo bash /opt/check_ping.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

VPS1_PUB="130.193.41.13"
VPS2_PUB="38.135.122.81"
VPS2_TUN="10.8.0.2"
DNS_SERVER="10.8.0.2"

# ── Функции ────────────────────────────────────────────────────────────────

do_ping() {
    local host=$1
    local iface=${2:-""}
    local iface_flag=""
    [ -n "$iface" ] && iface_flag="-I $iface"
    local out
    out=$(ping -c 3 -W 3 $iface_flag "$host" 2>/dev/null)
    local loss=$(echo "$out" | grep -oP '\d+(?=% packet loss)')
    local avg=$(echo "$out" | grep rtt | awk -F'/' '{printf "%.0f", $5}')
    if [ -n "$avg" ]; then
        echo "OK $avg $loss"
    else
        echo "FAIL"
    fi
}

print_ok()   { printf "  ${GREEN}✓${NC} %-38s ${GREEN}%s${NC}\n" "$1" "$2"; }
print_fail() { printf "  ${RED}✗${NC} %-38s ${RED}%s${NC}\n" "$1" "$2"; }
print_warn() { printf "  ${YELLOW}⚠${NC} %-38s ${YELLOW}%s${NC}\n" "$1" "$2"; }

# ── Заголовок ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         VPN Chain Ping Check                             ║${NC}"
echo -e "${BOLD}║  СПб → VPS1 (Москва) → VPS2 (США, Бруклин)             ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── 1. Интерфейсы ──────────────────────────────────────────────────────────
echo -e "${CYAN}● AmneziaWG интерфейсы${NC}"

AWG_OUT=$(awg show all 2>/dev/null)

if echo "$AWG_OUT" | grep -q "interface: awg0"; then
    HANDSHAKE=$(echo "$AWG_OUT" | grep -A20 "interface: awg0" | grep "latest handshake" | sed 's/.*latest handshake: //')
    TRANSFER=$(echo "$AWG_OUT" | grep -A20 "interface: awg0" | grep "transfer" | sed 's/.*transfer: //')
    [ -z "$HANDSHAKE" ] && HANDSHAKE="нет рукопожатия"
    print_ok "awg0 (туннель → VPS2)" "handshake: $HANDSHAKE"
    printf "    ${NC}transfer: %s\n" "$TRANSFER"
else
    print_fail "awg0 (туннель → VPS2)" "интерфейс не активен"
fi

if echo "$AWG_OUT" | grep -q "interface: awg1"; then
    JC=$(echo "$AWG_OUT" | grep -A10 "interface: awg1" | grep "jc:" | awk '{print $2}')
    print_ok "awg1 (клиенты, Junk Jc=$JC)" "активен"
else
    print_fail "awg1 (клиентский)" "интерфейс не активен"
fi
echo ""

# ── 2. Пинги ───────────────────────────────────────────────────────────────
echo -e "${CYAN}● Пинги${NC}"

# VPS1 → VPS2 публичный IP
R=$(do_ping "$VPS2_PUB")
if [[ "$R" == OK* ]]; then
    AVG=$(echo $R | awk '{print $2}')
    LOSS=$(echo $R | awk '{print $3}')
    print_ok "VPS1 → VPS2 публичный ($VPS2_PUB)" "${AVG}ms  потери: ${LOSS}%"
else
    print_fail "VPS1 → VPS2 публичный ($VPS2_PUB)" "нет ответа"
fi

# VPS1 → VPS2 через туннель awg0
R=$(do_ping "$VPS2_TUN" "awg0")
if [[ "$R" == OK* ]]; then
    AVG=$(echo $R | awk '{print $2}')
    LOSS=$(echo $R | awk '{print $3}')
    print_ok "VPS1 → VPS2 туннель ($VPS2_TUN)" "${AVG}ms  потери: ${LOSS}%"
else
    # Туннель может блокировать ICMP но всё равно работать — проверим через awg show
    if echo "$AWG_OUT" | grep -q "latest handshake"; then
        print_warn "VPS1 → VPS2 туннель ($VPS2_TUN)" "ICMP заблокирован, но handshake активен"
    else
        print_fail "VPS1 → VPS2 туннель ($VPS2_TUN)" "нет ответа"
    fi
fi

# VPS1 → интернет через туннель
R=$(do_ping "8.8.8.8" "awg0")
if [[ "$R" == OK* ]]; then
    AVG=$(echo $R | awk '{print $2}')
    print_ok "VPS1 → 8.8.8.8 через туннель" "${AVG}ms"
else
    print_warn "VPS1 → 8.8.8.8 через туннель" "ICMP заблокирован провайдером"
fi

# VPS1 → 1.1.1.1 через туннель
R=$(do_ping "1.1.1.1" "awg0")
if [[ "$R" == OK* ]]; then
    AVG=$(echo $R | awk '{print $2}')
    print_ok "VPS1 → 1.1.1.1 через туннель" "${AVG}ms"
else
    print_warn "VPS1 → 1.1.1.1 через туннель" "нет ответа"
fi
echo ""

# ── 3. DNS через AdGuard Home ──────────────────────────────────────────────
echo -e "${CYAN}● DNS через AdGuard Home ($DNS_SERVER:53)${NC}"

for domain in google.com youtube.com chatgpt.com claude.ai; do
    DNS_R=$(dig @"$DNS_SERVER" "$domain" +short +time=3 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    DNS_T=$(dig @"$DNS_SERVER" "$domain" +stats +time=3 2>/dev/null | grep "Query time" | awk '{print $4}')
    if [ -n "$DNS_R" ]; then
        print_ok "$domain" "→ $DNS_R  (${DNS_T}ms)"
    else
        print_fail "$domain" "нет ответа от AdGuard Home"
    fi
done
echo ""

# ── 4. Traceroute первые 3 хопа через туннель ─────────────────────────────
echo -e "${CYAN}● Маршрут через туннель (первые 4 хопа к 8.8.8.8)${NC}"
traceroute -i awg0 -m 4 -w 2 -n 8.8.8.8 2>/dev/null | tail -n +2 | while read line; do
    echo "  $line"
done
echo ""

# ── Итог ──────────────────────────────────────────────────────────────────
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  Ожидаемые задержки цепочки:                             ║${NC}"
echo -e "${BOLD}║  СПб → VPS1 (Москва)         ~10-30ms                   ║${NC}"
echo -e "${BOLD}║  VPS1 → VPS2 (США, Бруклин)  ~140-160ms                 ║${NC}"
echo -e "${BOLD}║  Итого СПб → выход в интернет ~150-190ms                 ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
