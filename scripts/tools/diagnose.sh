#!/usr/bin/env bash
# =============================================================================
# diagnose.sh — Диагностика и ремонт VPN-серверов
#
# Использование:
#   bash diagnose.sh [--fix]
#
#   Без --fix: только показывает состояние (безопасно)
#   С --fix:   исправляет найденные проблемы
#
# Параметры берутся из .env (VPS1_IP, VPS2_IP, VPS1_KEY, VPS2_KEY)
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
cd "$SCRIPT_DIR"

BLUE='\033[0;34m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; ISSUES=$((ISSUES+1)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
info() { echo -e "  ${CYAN}→${NC} $*"; }
hdr()  { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

ISSUES=0
FIX=false
[[ "${1:-}" == "--fix" ]] && FIX=true

# ---------------------------------------------------------------------------
# Загрузка конфига из .env и keys.env
# ---------------------------------------------------------------------------
VPS1_IP=""; VPS1_USER=""; VPS1_KEY=""; VPS1_PASS=""
VPS2_IP=""; VPS2_USER=""; VPS2_KEY=""; VPS2_PASS=""

load_defaults_from_files

VPS1_USER="${VPS1_USER:-root}"
VPS2_USER="${VPS2_USER:-root}"

VPS1_KEY="$(expand_tilde "$VPS1_KEY")"
VPS2_KEY="$(expand_tilde "$VPS2_KEY")"
[[ -z "$VPS1_PASS" ]] && VPS1_KEY="$(auto_pick_key_if_missing "$VPS1_KEY")"
[[ -z "$VPS2_PASS" ]] && VPS2_KEY="$(auto_pick_key_if_missing "$VPS2_KEY")"

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=no -o LogLevel=ERROR"

ssh1() {
    if [[ -n "$VPS1_KEY" && -f "$VPS1_KEY" ]]; then
        ssh $SSH_OPTS -i "$VPS1_KEY" "${VPS1_USER}@${VPS1_IP}" "$@" 2>&1
    elif [[ -n "$VPS1_PASS" ]]; then
        sshpass -p "$VPS1_PASS" ssh $SSH_OPTS "${VPS1_USER}@${VPS1_IP}" "$@" 2>&1
    else
        ssh $SSH_OPTS "${VPS1_USER}@${VPS1_IP}" "$@" 2>&1
    fi
}

ssh2() {
    if [[ -n "$VPS2_KEY" && -f "$VPS2_KEY" ]]; then
        ssh $SSH_OPTS -i "$VPS2_KEY" "${VPS2_USER}@${VPS2_IP}" "$@" 2>&1
    elif [[ -n "$VPS2_PASS" ]]; then
        sshpass -p "$VPS2_PASS" ssh $SSH_OPTS "${VPS2_USER}@${VPS2_IP}" "$@" 2>&1
    else
        ssh $SSH_OPTS "${VPS2_USER}@${VPS2_IP}" "$@" 2>&1
    fi
}

# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
if $FIX; then
echo -e "${BOLD}║         VPN Диагностика + Ремонт серверов                   ║${NC}"
else
echo -e "${BOLD}║         VPN Диагностика серверов (только чтение)            ║${NC}"
fi
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  VPS1: ${BOLD}${VPS1_USER}@${VPS1_IP:-НЕ ЗАДАН}${NC}"
echo -e "  VPS2: ${BOLD}${VPS2_USER}@${VPS2_IP:-НЕ ЗАДАН}${NC}"
$FIX && echo -e "  ${YELLOW}Режим: РЕМОНТ (--fix)${NC}" || echo -e "  ${CYAN}Режим: только диагностика (добавьте --fix для исправления)${NC}"
echo ""

# ---------------------------------------------------------------------------
[[ -z "$VPS1_IP" ]] && { echo -e "${RED}Ошибка: VPS1_IP не задан. Проверьте .env${NC}"; exit 1; }
[[ -z "$VPS2_IP" ]] && { echo -e "${RED}Ошибка: VPS2_IP не задан. Проверьте .env${NC}"; exit 1; }

# ---------------------------------------------------------------------------
hdr "1. Доступность серверов"

VPS1_OK=false; VPS2_OK=false

if ssh1 "echo ok" 2>/dev/null | grep -q ok; then
    ok "VPS1 ($VPS1_IP): SSH доступен"
    VPS1_OK=true
else
    fail "VPS1 ($VPS1_IP): SSH недоступен"
fi

if ssh2 "echo ok" 2>/dev/null | grep -q ok; then
    ok "VPS2 ($VPS2_IP): SSH доступен"
    VPS2_OK=true
else
    fail "VPS2 ($VPS2_IP): SSH недоступен"
fi

# ---------------------------------------------------------------------------
if $VPS1_OK; then
hdr "2. VPS1 — AmneziaWG туннели"

VPS1_STATUS=$(ssh1 "
echo '=awg0=' && systemctl is-active awg-quick@awg0 2>/dev/null || echo inactive
echo '=awg1=' && systemctl is-active awg-quick@awg1 2>/dev/null || echo inactive
echo '=awg_show=' && sudo awg show all 2>/dev/null | head -30 || echo 'no awg'
echo '=route_tbl200=' && ip route show table 200 2>/dev/null || echo 'no table 200'
echo '=forward_rules=' && sudo iptables -t nat -L PREROUTING -n 2>/dev/null | grep -E '53|DNAT' | head -5 || echo none
echo '=conntrack=' && cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0
echo '=ip_forward=' && cat /proc/sys/net/ipv4/ip_forward
")

AWG0_STATE=$(echo "$VPS1_STATUS" | awk '/^=awg0=/{getline; print}')
AWG1_STATE=$(echo "$VPS1_STATUS" | awk '/^=awg1=/{getline; print}')
IP_FWD=$(echo "$VPS1_STATUS" | awk '/^=ip_forward=/{getline; print}')
ROUTE_TBL=$(echo "$VPS1_STATUS" | awk '/^=route_tbl200=/{found=1; next} found && /^=/{exit} found{print}')
PREROUTING=$(echo "$VPS1_STATUS" | awk '/^=forward_rules=/{found=1; next} found && /^=/{exit} found{print}')

[[ "$AWG0_STATE" == "active" ]] && ok "awg0 (туннель к VPS2): active" || { fail "awg0 (туннель к VPS2): $AWG0_STATE"; }
[[ "$AWG1_STATE" == "active" ]] && ok "awg1 (клиентский): active" || { fail "awg1 (клиентский): $AWG1_STATE"; }
[[ "$IP_FWD" == "1" ]] && ok "ip_forward=1" || { fail "ip_forward=$IP_FWD"; }

if echo "$ROUTE_TBL" | grep -q 'default'; then
    ok "Маршрут table 200 (клиентский трафик через awg0): OK"
    info "$(echo "$ROUTE_TBL" | head -2)"
else
    fail "Маршрут table 200 отсутствует — клиентский трафик не пойдёт через VPS2"
fi

if echo "$PREROUTING" | grep -q 'DNAT'; then
    ok "DNS DNAT правило (порт 53 → 10.8.0.2): OK"
else
    fail "DNS DNAT правило отсутствует — DNS клиентов не перенаправляется на VPS2"
fi

# Проверка handshake с VPS2
HS=$(echo "$VPS1_STATUS" | awk '/^=awg_show=/{found=1; next} found && /^=/{exit} found && /latest handshake/{print}' | head -1)
if [[ -n "$HS" ]]; then
    ok "Туннель VPS1↔VPS2 активен: $HS"
else
    warn "Нет данных о handshake с VPS2 (туннель может быть не установлен)"
fi

if $FIX; then
    if [[ "$AWG0_STATE" != "active" ]]; then
        info "Перезапускаю awg0..."
        ssh1 "sudo systemctl restart awg-quick@awg0" && ok "awg0 перезапущен" || warn "Не удалось перезапустить awg0"
    fi
    if [[ "$AWG1_STATE" != "active" ]]; then
        info "Перезапускаю awg1..."
        ssh1 "sudo systemctl restart awg-quick@awg1" && ok "awg1 перезапущен" || warn "Не удалось перезапустить awg1"
    fi
    if [[ "$IP_FWD" != "1" ]]; then
        info "Включаю ip_forward..."
        ssh1 "sudo sysctl -w net.ipv4.ip_forward=1" && ok "ip_forward=1"
    fi

    # Восстанавливаем DNS DNAT если правило отсутствует
    if ! echo "$PREROUTING" | grep -q 'DNAT'; then
        info "Добавляю DNS DNAT правила (порт 53 → VPS2)..."
        TUN_NET2=$(ssh1 "ip route show table 200 2>/dev/null | awk '/default/{print \$3}' | sed 's/\\.2\$//'")
        if [[ -z "$TUN_NET2" ]]; then
            TUN_NET2="10.8.0"
        fi
        # Используем iptables-legacy если nf_tables не поддерживает --dport напрямую
        IPT=$(ssh1 "command -v iptables-legacy 2>/dev/null || command -v iptables" | tr -d '[:space:]')
        [[ -z "$IPT" ]] && IPT="iptables"
        ssh1 "sudo ${IPT} -t nat -C PREROUTING -i awg1 -p udp -m udp --dport 53 -j DNAT --to-destination ${TUN_NET2}.2:53 2>/dev/null || \
              sudo ${IPT} -t nat -A PREROUTING -i awg1 -p udp -m udp --dport 53 -j DNAT --to-destination ${TUN_NET2}.2:53"
        ssh1 "sudo ${IPT} -t nat -C PREROUTING -i awg1 -p tcp -m tcp --dport 53 -j DNAT --to-destination ${TUN_NET2}.2:53 2>/dev/null || \
              sudo ${IPT} -t nat -A PREROUTING -i awg1 -p tcp -m tcp --dport 53 -j DNAT --to-destination ${TUN_NET2}.2:53"
        ok "DNS DNAT правила добавлены (→ ${TUN_NET2}.2:53)"

        # Персистентность: добавляем PostUp/PostDown в awg1.conf если файл существует
        AWG1_CONF=$(ssh1 "cat /etc/amnezia/amneziawg/awg1.conf 2>/dev/null || echo ''")
        if [[ -n "$AWG1_CONF" ]] && ! echo "$AWG1_CONF" | grep -q 'DNAT'; then
            info "Добавляю DNAT в awg1.conf для персистентности..."
            ssh1 "sed -i '/^PostDown.*MASQUERADE/a PostUp   = iptables -t nat -A PREROUTING -i awg1 -p udp --dport 53 -j DNAT --to-destination ${TUN_NET2}.2:53\nPostUp   = iptables -t nat -A PREROUTING -i awg1 -p tcp --dport 53 -j DNAT --to-destination ${TUN_NET2}.2:53\nPostDown = iptables -t nat -D PREROUTING -i awg1 -p udp --dport 53 -j DNAT --to-destination ${TUN_NET2}.2:53 || true\nPostDown = iptables -t nat -D PREROUTING -i awg1 -p tcp --dport 53 -j DNAT --to-destination ${TUN_NET2}.2:53 || true' /etc/amnezia/amneziawg/awg1.conf"
            ok "DNAT добавлен в awg1.conf"
        elif [[ -z "$AWG1_CONF" ]]; then
            warn "awg1.conf не найден — DNAT правила добавлены только в текущую сессию iptables"
            warn "При перезагрузке сервера правила пропадут. Запустите полный деплой: bash deploy.sh"
        fi
    fi
fi
fi # VPS1_OK

# ---------------------------------------------------------------------------
if $VPS2_OK; then
hdr "3. VPS2 — AmneziaWG + youtube-proxy"

VPS2_STATUS=$(ssh2 "
echo '=awg0=' && systemctl is-active awg-quick@awg0 2>/dev/null || echo inactive
echo '=yt_proxy=' && systemctl is-active youtube-proxy 2>/dev/null || echo inactive
echo '=yt_proxy_log=' && journalctl -u youtube-proxy -n 20 --no-pager 2>/dev/null || echo 'no journal'
echo '=adguard=' && (systemctl is-active AdGuardHome 2>/dev/null || systemctl is-active adguardhome 2>/dev/null || echo inactive)
echo '=port53=' && ss -lunt 2>/dev/null | grep ':53' | head -5 || echo 'none'
echo '=port443=' && ss -lnt 2>/dev/null | grep ':443' | head -5 || echo 'none'
echo '=port8080=' && ss -lnt 2>/dev/null | grep ':8080' | head -3 || echo 'none'
echo '=resolv=' && cat /etc/resolv.conf 2>/dev/null | head -3
echo '=ip_forward=' && cat /proc/sys/net/ipv4/ip_forward
echo '=masquerade=' && iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -E 'MASQUERADE|10\.' | head -5 || echo none
echo '=wan_ping=' && ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && echo ok || echo fail
echo '=dns_test=' && nslookup google.com 127.0.0.1 2>/dev/null | grep -E 'Address|Server' | head -4 || echo 'dns fail'
echo '=proxy_certs=' && ls /opt/youtube-proxy/certs/ 2>/dev/null || echo 'no certs dir'
")

AWG0_V2=$(echo "$VPS2_STATUS" | awk '/^=awg0=/{getline; print}')
YT_STATE=$(echo "$VPS2_STATUS" | awk '/^=yt_proxy=/{getline; print}')
AGH_STATE=$(echo "$VPS2_STATUS" | awk '/^=adguard=/{getline; print}')
PORT53=$(echo "$VPS2_STATUS" | awk '/^=port53=/{found=1; next} found && /^=/{exit} found{print}')
PORT443=$(echo "$VPS2_STATUS" | awk '/^=port443=/{found=1; next} found && /^=/{exit} found{print}')
PORT8080=$(echo "$VPS2_STATUS" | awk '/^=port8080=/{found=1; next} found && /^=/{exit} found{print}')
IP_FWD2=$(echo "$VPS2_STATUS" | awk '/^=ip_forward=/{getline; print}')
WAN_PING=$(echo "$VPS2_STATUS" | awk '/^=wan_ping=/{getline; print}')
DNS_TEST=$(echo "$VPS2_STATUS" | awk '/^=dns_test=/{found=1; next} found && /^=/{exit} found{print}')
MASQ=$(echo "$VPS2_STATUS" | awk '/^=masquerade=/{found=1; next} found && /^=/{exit} found{print}')
CERTS=$(echo "$VPS2_STATUS" | awk '/^=proxy_certs=/{found=1; next} found && /^=/{exit} found{print}')
YT_LOG=$(echo "$VPS2_STATUS" | awk '/^=yt_proxy_log=/{found=1; next} found && /^=/{exit} found{print}' | tail -5)

[[ "$AWG0_V2" == "active" ]] && ok "awg0 (туннель к VPS1): active" || fail "awg0 (туннель к VPS1): $AWG0_V2"
[[ "$IP_FWD2" == "1" ]] && ok "ip_forward=1" || fail "ip_forward=$IP_FWD2"
[[ "$WAN_PING" == "ok" ]] && ok "WAN доступ (ping 8.8.8.8): OK" || fail "WAN доступ: FAIL — VPS2 не может выйти в интернет!"

echo ""
echo -e "  ${BOLD}youtube-proxy:${NC}"
if [[ "$YT_STATE" == "active" ]]; then
    ok "youtube-proxy: active"
    if echo "$PORT53" | grep -qv 'none'; then
        ok "Порт 53 (DNS): слушает"
        info "$(echo "$PORT53" | head -2)"
    else
        fail "Порт 53 (DNS): НЕ слушает — DNS клиентов не работает!"
    fi
    if echo "$PORT443" | grep -qv 'none'; then
        ok "Порт 443 (HTTPS прокси): слушает"
    else
        fail "Порт 443 (HTTPS прокси): НЕ слушает — YouTube прокси не работает!"
    fi
    if echo "$PORT8080" | grep -qv 'none'; then
        ok "Порт 8080 (CA сервер): слушает"
    else
        warn "Порт 8080 (CA сервер): не слушает"
    fi
    if echo "$CERTS" | grep -q 'ca.crt'; then
        ok "CA сертификат: сгенерирован (certs/ca.crt)"
    else
        fail "CA сертификат: НЕ найден в /opt/youtube-proxy/certs/"
    fi
    if echo "$DNS_TEST" | grep -q 'Address'; then
        ok "DNS работает (nslookup google.com → 127.0.0.1)"
    else
        fail "DNS не отвечает: $DNS_TEST"
    fi
    if [[ -n "$YT_LOG" ]]; then
        info "Последние логи youtube-proxy:"
        echo "$YT_LOG" | while IFS= read -r line; do echo "    $line"; done
    fi
else
    fail "youtube-proxy: $YT_STATE — DNS и HTTPS прокси не работают!"
    if [[ -n "$YT_LOG" ]]; then
        warn "Последние логи (ошибки):"
        echo "$YT_LOG" | while IFS= read -r line; do echo "    $line"; done
    fi
fi

echo ""
echo -e "  ${BOLD}AdGuard Home:${NC}"
if [[ "$AGH_STATE" == "active" ]]; then
    fail "AdGuard Home АКТИВЕН — конфликт с youtube-proxy на порту 53!"
    warn "AdGuard Home и youtube-proxy не могут работать одновременно на порту 53"
else
    ok "AdGuard Home: остановлен/отключён (не конфликтует)"
fi

if echo "$MASQ" | grep -q 'MASQUERADE'; then
    ok "NAT MASQUERADE: настроен"
else
    fail "NAT MASQUERADE: отсутствует — клиентский трафик не выйдет в интернет!"
fi

# Проверяем что TCP 443 разрешён с VPN-интерфейса
TCP443_RULE=$(ssh2 "sudo iptables -L INPUT -n 2>/dev/null | grep -E 'tcp.*443|443.*tcp' | head -3" 2>/dev/null || echo "")
if echo "$TCP443_RULE" | grep -q 'ACCEPT'; then
    ok "Firewall: TCP 443 с awg0 разрешён"
elif echo "$TCP443_RULE" | grep -q 'REJECT\|DROP'; then
    fail "Firewall: TCP 443 ЗАБЛОКИРОВАН — YouTube прокси недоступен!"
    info "Правила: $TCP443_RULE"
else
    warn "Firewall: нет явного правила для TCP 443 (может работать если нет DROP-all)"
fi

if $FIX; then
    echo ""
    info "=== Применяю исправления на VPS2 ==="

    if [[ "$AGH_STATE" == "active" ]]; then
        info "Останавливаю AdGuard Home..."
        ssh2 "sudo systemctl stop AdGuardHome 2>/dev/null || sudo systemctl stop adguardhome 2>/dev/null || true"
        ssh2 "sudo systemctl disable AdGuardHome 2>/dev/null || sudo systemctl disable adguardhome 2>/dev/null || true"
        ok "AdGuard Home остановлен"
    fi

    if [[ "$AWG0_V2" != "active" ]]; then
        info "Перезапускаю awg0..."
        ssh2 "sudo systemctl restart awg-quick@awg0" && ok "awg0 перезапущен" || warn "Не удалось"
    fi

    if [[ "$IP_FWD2" != "1" ]]; then
        info "Включаю ip_forward..."
        ssh2 "sudo sysctl -w net.ipv4.ip_forward=1" && ok "ip_forward=1"
    fi

    # Проверяем наличие IP SAN в серверном сертификате.
    # Если сертификат не содержит IP SAN — удаляем его, чтобы при рестарте
    # youtube-proxy пересоздал его с актуальными IP из config.yaml.
    CERT_HAS_IP_SAN=$(ssh2 "openssl x509 -in /opt/youtube-proxy/certs/server.crt -noout -text 2>/dev/null | grep -c 'IP Address' || echo 0" 2>/dev/null | tr -d '[:space:]')
    if [[ "${CERT_HAS_IP_SAN:-0}" == "0" ]]; then
        info "Серверный сертификат без IP SAN — пересоздаю..."
        ssh2 "sudo rm -f /opt/youtube-proxy/certs/server.crt /opt/youtube-proxy/certs/server.key"
        ok "Старый сертификат удалён (будет пересоздан с IP SAN при старте)"
    fi

    if [[ "$YT_STATE" != "active" ]]; then
        info "Запускаю youtube-proxy..."
        ssh2 "sudo systemctl start youtube-proxy" && ok "youtube-proxy запущен" || {
            warn "Не удалось запустить youtube-proxy"
            info "Логи:"
            ssh2 "sudo journalctl -u youtube-proxy -n 30 --no-pager 2>/dev/null" | tail -15
        }
    else
        info "Перезапускаю youtube-proxy (для применения изменений)..."
        ssh2 "sudo systemctl restart youtube-proxy" && ok "youtube-proxy перезапущен" || warn "Не удалось"
    fi

    # Убеждаемся что resolv.conf указывает на 127.0.0.1
    RESOLV=$(ssh2 "cat /etc/resolv.conf 2>/dev/null")
    if ! echo "$RESOLV" | grep -q '127.0.0.1'; then
        info "Исправляю /etc/resolv.conf..."
        ssh2 "sudo rm -f /etc/resolv.conf && printf 'nameserver 127.0.0.1\n' | sudo tee /etc/resolv.conf"
        ok "/etc/resolv.conf → nameserver 127.0.0.1"
    fi

    # Проверяем MASQUERADE
    if ! echo "$MASQ" | grep -q 'MASQUERADE'; then
        info "Добавляю MASQUERADE правила..."
        MAIN_IF=$(ssh2 "ip route | awk '/default/{print \$5; exit}'")
        ssh2 "sudo iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ${MAIN_IF} -j MASQUERADE 2>/dev/null || true"
        ssh2 "sudo iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o ${MAIN_IF} -j MASQUERADE 2>/dev/null || true"
        ok "MASQUERADE добавлен"
    fi

    # Разрешаем TCP 443 с VPN-интерфейса (нужно для YouTube прокси)
    info "Проверяю firewall для TCP 443 (YouTube HTTPS прокси)..."
    ssh2 "sudo iptables -C INPUT -p tcp --dport 443 -i awg0 -j ACCEPT 2>/dev/null || \
          sudo iptables -I INPUT 1 -p tcp --dport 443 -i awg0 -j ACCEPT"
    ok "TCP 443 с awg0 разрешён"

    # Разрешаем FORWARD для трафика через туннель
    info "Проверяю FORWARD правила..."
    ssh2 "sudo iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || \
          sudo iptables -I FORWARD 1 -i awg0 -j ACCEPT"
    ssh2 "sudo iptables -C FORWARD -o awg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
          sudo iptables -I FORWARD 2 -o awg0 -m state --state RELATED,ESTABLISHED -j ACCEPT"
    ok "FORWARD правила для awg0 добавлены"

    sleep 2
    echo ""
    info "Проверка после исправлений:"
    NEW_YT=$(ssh2 "systemctl is-active youtube-proxy 2>/dev/null || echo inactive")
    NEW_DNS=$(ssh2 "ss -lunt 2>/dev/null | grep ':53' | head -2")
    [[ "$NEW_YT" == "active" ]] && ok "youtube-proxy: active" || fail "youtube-proxy: $NEW_YT"
    [[ -n "$NEW_DNS" ]] && ok "Порт 53 слушает" || fail "Порт 53 не слушает"
fi
fi # VPS2_OK

# ---------------------------------------------------------------------------
hdr "4. Проблема: дашборд при включённом VPN"

echo -e "  ${CYAN}Анализ:${NC}"
info "HTTP-сервер дашборда слушает на 127.0.0.1:8080 (localhost)"
info "При включённом VPN браузер обращается к 127.0.0.1:8080 — это должно работать"
info "Возможные причины отказа дашборда при VPN:"
echo ""
echo -e "  ${YELLOW}1.${NC} SSH к VPS1 (10.9.0.1) зависает — monitor-web.sh ждёт ответа"
echo -e "     Решение: уже исправлено (timeout на SSH)"
echo ""
echo -e "  ${YELLOW}2.${NC} DNS в WSL при включённом VPN идёт через VPN-DNS (10.8.0.2)"
echo -e "     Если youtube-proxy не работает — DNS зависает → SSH зависает"
echo -e "     Решение: убедиться что youtube-proxy работает на VPS2"
echo ""
echo -e "  ${YELLOW}3.${NC} Порт 8080 на 127.0.0.1 занят другим процессом"
if command -v ss >/dev/null 2>&1; then
    PORT8080_LOCAL=$(ss -tlnp 2>/dev/null | grep ':8080' | head -3)
    if [[ -n "$PORT8080_LOCAL" ]]; then
        warn "Порт 8080 локально занят: $PORT8080_LOCAL"
    else
        ok "Порт 8080 локально свободен (monitor-web.sh может запуститься)"
    fi
fi

# ---------------------------------------------------------------------------
hdr "5. Итог"

if [[ $ISSUES -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}Проблем не обнаружено!${NC}"
else
    echo -e "  ${RED}${BOLD}Обнаружено проблем: $ISSUES${NC}"
    echo ""
    if ! $FIX; then
        echo -e "  Запустите с флагом ${BOLD}--fix${NC} для автоматического исправления:"
        echo -e "  ${BOLD}bash diagnose.sh --fix${NC}"
    fi
fi

echo ""
echo -e "  ${CYAN}Что делать если YouTube не работает:${NC}"
echo -e "  1. Убедитесь что youtube-proxy active на VPS2 (см. выше)"
echo -e "  2. CA-сертификат установлен на компьютере (уже сделано)"
echo -e "  3. Перезапустите браузер после установки CA"
echo ""
echo -e "  ${CYAN}Что делать если телефон без интернета:${NC}"
echo -e "  1. youtube-proxy должен быть active (DNS на порту 53)"
echo -e "  2. awg0 на VPS2 должен быть active"
echo -e "  3. MASQUERADE должен быть настроен"
echo ""
