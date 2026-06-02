#!/usr/bin/env bash
# =============================================================================
# split-tunnel-apply.sh — атомарное включение split tunneling на VPS1
#
# Выполняется НА VPS1. Кладётся в /usr/local/sbin/split-tunnel-apply.sh.
#
# Идемпотентен: повторный запуск ничего не ломает, лишь переустанавливает
# отсутствующие правила.
#
# Zero-downtime для DNS: новые DNAT-правила вставляются в начало цепочки
# ДО удаления старых. Если dnsmasq не отвечает — старые правила не удаляются.
#
# Существующие TCP-соединения не разрываются благодаря CONNMARK: маршрут
# фиксируется в момент NEW, для ESTABLISHED берётся из conntrack.
#
# Параметры через окружение (или флаги CLI):
#   CLIENT_NET     — сеть клиентов awg1 (по умолчанию 10.9.0)
#   TUN_NET        — сеть тоннеля awg0  (по умолчанию 10.8.0)
#   DNSMASQ_IP     — IP VPS1 в awg1     (по умолчанию ${CLIENT_NET}.1)
#   ADGUARD_IP     — IP DNS upstream на VPS2 (по умолчанию ${TUN_NET}.2)
#   MARK_HEX       — fwmark             (по умолчанию 0x100)
#   ROUTE_TABLE    — номер таблицы      (по умолчанию 100)
#   IPSET_NAME     — имя ipset          (по умолчанию ru_subnets)
# =============================================================================

set -euo pipefail

CLIENT_NET="${CLIENT_NET:-10.9.0}"
TUN_NET="${TUN_NET:-10.8.0}"
DNSMASQ_IP="${DNSMASQ_IP:-${CLIENT_NET}.1}"
ADGUARD_IP="${ADGUARD_IP:-${TUN_NET}.2}"
MARK_HEX="${MARK_HEX:-0x100}"
ROUTE_TABLE="${ROUTE_TABLE:-100}"
FWMARK_RULE_PRIORITY="${FWMARK_RULE_PRIORITY:-80}"
DNS_REPLY_RULE_PRIORITY="${DNS_REPLY_RULE_PRIORITY:-88}"
IPSET_NAME="${IPSET_NAME:-ru_subnets}"
CLIENT_CIDR="${CLIENT_NET}.0/24"

log()  { echo "[$(date +%H:%M:%S)] $*"; logger -t split-tunnel-apply -- "$*" 2>/dev/null || true; }
fail() { echo "[FATAL] $*" >&2; logger -t split-tunnel-apply -p user.err -- "FATAL: $*" 2>/dev/null || true; exit 1; }

require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || fail "не найдена утилита: $c (apt install -y $c)"
    done
}

# Идемпотентное добавление iptables-правила (в конец цепочки).
# Использование: ipt_ensure <table> <chain> <args...>
ipt_ensure() {
    local table="$1" chain="$2"; shift 2
    iptables -t "$table" -C "$chain" "$@" 2>/dev/null \
      || iptables -t "$table" -A "$chain" "$@"
}

# Идемпотентное добавление iptables-правила в НАЧАЛО цепочки.
# Используется для zero-downtime DNAT.
ipt_ensure_top() {
    local table="$1" chain="$2"; shift 2
    iptables -t "$table" -C "$chain" "$@" 2>/dev/null \
      || iptables -t "$table" -I "$chain" 1 "$@"
}

require_cmd ip iptables ipset dig

[[ $EUID -eq 0 ]] || fail "запускайте от root: sudo bash $0"

MAIN_IF="$(ip route show default | awk '/^default/ {print $5; exit}')"
MAIN_GW="$(ip route show default | awk '/^default/ {print $3; exit}')"
[[ -n "$MAIN_IF" && -n "$MAIN_GW" ]] || fail "не удалось определить default route и gateway"

log "MAIN_IF=$MAIN_IF MAIN_GW=$MAIN_GW DNSMASQ_IP=$DNSMASQ_IP ADGUARD_IP=$ADGUARD_IP"

ip link show awg1 >/dev/null 2>&1 || fail "интерфейс awg1 не поднят — split tunneling требует активного awg1"

# ── 0. Pre-flight: проверка занятости table $ROUTE_TABLE и fwmark $MARK_HEX ─
# Если table уже используется НЕ нашим правилом, или fwmark занят другим
# приложением — отказываем, чтобы не сломать чужую policy routing.
EXISTING_RULES=$(ip rule show | grep -E "lookup ${ROUTE_TABLE}( |$)" || true)
if [[ -n "$EXISTING_RULES" ]]; then
    if ! echo "$EXISTING_RULES" | grep -q "fwmark $MARK_HEX"; then
        fail "table $ROUTE_TABLE уже используется другим правилом: $(echo "$EXISTING_RULES" | head -1). Освободите её или измените ROUTE_TABLE через переменную окружения."
    fi
fi
EXISTING_FWMARK=$(ip rule show | grep -E "fwmark $MARK_HEX( |$)" | grep -v "lookup ${ROUTE_TABLE}" || true)
if [[ -n "$EXISTING_FWMARK" ]]; then
    fail "fwmark $MARK_HEX уже используется другим правилом: $(echo "$EXISTING_FWMARK" | head -1). Освободите его или измените MARK_HEX через переменную окружения."
fi

# ── 1. ipset (должен быть СОЗДАН до правил mangle) ──────────────────────────
if ! ipset list "$IPSET_NAME" >/dev/null 2>&1; then
    ipset create "$IPSET_NAME" hash:ip family inet hashsize 4096 maxelem 131072 timeout 604800
    log "ipset $IPSET_NAME создан"
else
    log "ipset $IPSET_NAME уже существует"
fi

# ── 2. rp_filter в loose mode (для multiple routing tables) ─────────────────
# || true потому что интерфейс может быть hot-removed между ip link show и sysctl
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1 || true
sysctl -w "net.ipv4.conf.${MAIN_IF}.rp_filter=2" >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.awg1.rp_filter=2 >/dev/null 2>&1 || true
log "rp_filter переведён в loose mode (=2)"

# ── 3. Mangle: CONNMARK + MARK (только для NEW соединений) ──────────────────
# ESTABLISHED обрабатывается ПЕРВЫМ — иначе MARK для NEW переопределит уже
# сохранённый conntrack-mark существующей сессии, и она "перепрыгнет" маршрут.
ipt_ensure mangle PREROUTING -i awg1 -m conntrack --ctstate ESTABLISHED,RELATED -j CONNMARK --restore-mark
ipt_ensure mangle PREROUTING -i awg1 -m conntrack --ctstate NEW -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$MARK_HEX"
ipt_ensure mangle PREROUTING -i awg1 -m conntrack --ctstate NEW -j CONNMARK --save-mark
log "mangle PREROUTING: CONNMARK + MARK установлены"

# ── 4. Policy routing: новая таблица для split-трафика ──────────────────────
FWMARK_RULE_PREFS="$(ip rule show | awk -v mark="$MARK_HEX" -v tbl="$ROUTE_TABLE" '
    $0 ~ "fwmark " mark && $0 ~ "lookup " tbl {
        pref=$1
        sub(/:.*/, "", pref)
        print pref
    }
')"
if [[ "$FWMARK_RULE_PREFS" != "$FWMARK_RULE_PRIORITY" ]]; then
    while read -r pref; do
        [[ -n "$pref" ]] || continue
        ip rule del pref "$pref" 2>/dev/null || true
    done <<< "$FWMARK_RULE_PREFS"
    ip rule add fwmark "$MARK_HEX" table "$ROUTE_TABLE" priority "$FWMARK_RULE_PRIORITY"
    log "ip rule добавлено: fwmark $MARK_HEX → table $ROUTE_TABLE"
fi
ip route replace default via "$MAIN_GW" dev "$MAIN_IF" table "$ROUTE_TABLE"
log "ip route table $ROUTE_TABLE: default via $MAIN_GW dev $MAIN_IF"

# ── 5. FORWARD + MASQUERADE на основном интерфейсе ─────────────────────────
# security-harden.sh ставит policy FORWARD=DROP. Базовый VPN разрешает только
# awg1→awg0, поэтому split-трафику нужен отдельный allow на основной интерфейс.
ipt_ensure filter FORWARD -i awg1 -o "$MAIN_IF" -m mark --mark "$MARK_HEX" -j ACCEPT
ipt_ensure filter FORWARD -i "$MAIN_IF" -o awg1 -m state --state RELATED,ESTABLISHED -j ACCEPT
log "FORWARD для маркированного split-трафика через $MAIN_IF установлен"

ipt_ensure nat POSTROUTING -s "$CLIENT_CIDR" -o "$MAIN_IF" -j MASQUERADE
log "MASQUERADE для $CLIENT_CIDR через $MAIN_IF установлен"

# DNS после DNAT обслуживается локальным процессом dnsmasq, поэтому пакет идёт
# через INPUT, а не FORWARD. При default INPUT=DROP нужен явный allow.
ipt_ensure filter INPUT -i awg1 -d "$DNSMASQ_IP" -p udp --dport 53 -j ACCEPT
ipt_ensure filter INPUT -i awg1 -d "$DNSMASQ_IP" -p tcp --dport 53 -j ACCEPT
log "INPUT для клиентского DNS к dnsmasq ${DNSMASQ_IP}:53 установлен"

# На VPS1 уже есть правило "from 10.9.0.0/24 lookup 200" для клиентского
# full-tunnel трафика. Оно также цепляет локальные ответы dnsmasq с source
# 10.9.0.1 и уводит их в awg0. Более приоритетное правило возвращает ответы
# VPS1 клиентам напрямую через connected route awg1.
DNS_REPLY_RULE_PREFS="$(ip rule show | awk -v src="$DNSMASQ_IP" -v dst="$CLIENT_CIDR" '
    $0 ~ "from " src && $0 ~ "to " dst && $0 ~ "lookup main" {
        pref=$1
        sub(/:.*/, "", pref)
        print pref
    }
')"
if [[ "$DNS_REPLY_RULE_PREFS" != "$DNS_REPLY_RULE_PRIORITY" ]]; then
    while read -r pref; do
        [[ -n "$pref" ]] || continue
        ip rule del pref "$pref" 2>/dev/null || true
    done <<< "$DNS_REPLY_RULE_PREFS"
    ip rule add from "${DNSMASQ_IP}/32" to "$CLIENT_CIDR" table main priority "$DNS_REPLY_RULE_PRIORITY"
fi
ip route flush cache 2>/dev/null || true
log "ip rule DNS replies: from ${DNSMASQ_IP} to ${CLIENT_CIDR} → main"

# ── 6. ZERO-DOWNTIME переключение DNS DNAT ──────────────────────────────────
# Insert в начало срабатывает первым, старые правила (если есть) остаются как
# fallback до шага 8, где удаляются только после healthcheck dnsmasq.
ipt_ensure_top nat PREROUTING -i awg1 -p udp --dport 53 -j DNAT --to-destination "${DNSMASQ_IP}:53"
ipt_ensure_top nat PREROUTING -i awg1 -p tcp --dport 53 -j DNAT --to-destination "${DNSMASQ_IP}:53"
log "DNS DNAT → ${DNSMASQ_IP}:53 вставлен (в начало цепочки)"

# Клиентские конфиги по-прежнему указывают DNS=${ADGUARD_IP}. После DNAT запрос
# обслуживает локальный dnsmasq (${DNSMASQ_IP}), поэтому ответы должны выглядеть
# для клиента как пришедшие от старого DNS ${ADGUARD_IP}; иначе клиенты/dig могут
# отбросить пакет как ответ от неожиданного сервера.
ipt_ensure nat POSTROUTING -o awg1 -s "${DNSMASQ_IP}/32" -d "$CLIENT_CIDR" -p udp --sport 53 -j SNAT --to-source "$ADGUARD_IP"
ipt_ensure nat POSTROUTING -o awg1 -s "${DNSMASQ_IP}/32" -d "$CLIENT_CIDR" -p tcp --sport 53 -j SNAT --to-source "$ADGUARD_IP"
log "DNS reply SNAT: ${DNSMASQ_IP}:53 → source ${ADGUARD_IP}"

# ── 7. Healthcheck dnsmasq ──────────────────────────────────────────────────
# Двухуровневая проверка: (1) systemctl is-active защищает от crashloop,
# (2) dig подтверждает реальный резолв на нужном IP
DNS_OK=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if systemctl is-active --quiet dnsmasq 2>/dev/null \
       && dig +time=2 +tries=1 "@${DNSMASQ_IP}" example.com +short >/dev/null 2>&1; then
        DNS_OK=1; break
    fi
    sleep 1
done

if [[ "$DNS_OK" != "1" ]]; then
    fail "dnsmasq на ${DNSMASQ_IP}:53 не отвечает за 15 секунд (или service не active). Старые DNAT-правила НЕ удалены — DNS продолжает работать через ${ADGUARD_IP}:53. Проверьте: systemctl status dnsmasq; journalctl -u dnsmasq -n 50. Откат: sudo split-tunnel-rollback.sh"
fi
log "dnsmasq active + отвечает на ${DNSMASQ_IP}:53 — OK"

# ── 8. Удаление старых DNAT-правил (только после healthcheck) ───────────────
# Удаляем ВСЕ варианты старых правил (разные --to-destination format) — на случай
# что между запусками формат менялся
while iptables -t nat -C PREROUTING -i awg1 -p udp --dport 53 -j DNAT --to-destination "${ADGUARD_IP}:53" 2>/dev/null; do
    iptables -t nat -D PREROUTING -i awg1 -p udp --dport 53 -j DNAT --to-destination "${ADGUARD_IP}:53"
done
while iptables -t nat -C PREROUTING -i awg1 -p tcp --dport 53 -j DNAT --to-destination "${ADGUARD_IP}:53" 2>/dev/null; do
    iptables -t nat -D PREROUTING -i awg1 -p tcp --dport 53 -j DNAT --to-destination "${ADGUARD_IP}:53"
done
log "Старые DNAT на ${ADGUARD_IP}:53 удалены"

log "Split tunneling включён успешно."
log ""
log "  ipset:       $(ipset list "$IPSET_NAME" 2>/dev/null | awk '/^Number of entries:/ {print $4}') записей"
log "  fwmark:      $MARK_HEX → table $ROUTE_TABLE"
log "  output:      $MAIN_IF (gateway $MAIN_GW)"
log "  dns proxy:   ${DNSMASQ_IP}:53 → upstream ${ADGUARD_IP}:53"
log ""
log "  Откат:       sudo split-tunnel-rollback.sh"
