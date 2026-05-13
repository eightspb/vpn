#!/usr/bin/env bash
# =============================================================================
# split-tunnel-rollback.sh — полный откат split tunneling на VPS1
#
# Выполняется НА VPS1. Кладётся в /usr/local/sbin/split-tunnel-rollback.sh.
#
# Возвращает VPS1 в состояние ДО split tunneling:
#   - восстанавливает DNS DNAT на AdGuard (VPS2)
#   - удаляет новые DNAT на dnsmasq (VPS1)
#   - останавливает dnsmasq (не disable — оставляем для возможного re-apply)
#   - удаляет mangle CONNMARK/MARK правила
#   - удаляет ip rule fwmark и таблицу маршрутизации
#   - удаляет MASQUERADE на основном интерфейсе
#   - очищает ipset
#
# Существующие пользовательские TCP-соединения не разрываются.
# Идемпотентен: повторный запуск безопасен.
#
# Параметры через окружение — те же, что у split-tunnel-apply.sh.
# =============================================================================

set -uo pipefail

CLIENT_NET="${CLIENT_NET:-10.9.0}"
TUN_NET="${TUN_NET:-10.8.0}"
DNSMASQ_IP="${DNSMASQ_IP:-${CLIENT_NET}.1}"
ADGUARD_IP="${ADGUARD_IP:-${TUN_NET}.2}"
MARK_HEX="${MARK_HEX:-0x100}"
ROUTE_TABLE="${ROUTE_TABLE:-100}"
IPSET_NAME="${IPSET_NAME:-ru_subnets}"
CLIENT_CIDR="${CLIENT_NET}.0/24"

log() { echo "[$(date +%H:%M:%S)] $*"; logger -t split-tunnel-rollback -- "$*" 2>/dev/null || true; }

# Удаляет ВСЕ копии iptables-правила (включая дубликаты от прерванного apply).
# Использование: ipt_drop_all <table> <chain> <args...>
ipt_drop_all() {
    local table="$1" chain="$2"; shift 2
    while iptables -t "$table" -C "$chain" "$@" 2>/dev/null; do
        iptables -t "$table" -D "$chain" "$@"
    done
}

[[ $EUID -eq 0 ]] || { echo "запускайте от root: sudo bash $0" >&2; exit 1; }

MAIN_IF="$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')"

# ── 1. Вернуть старые DNAT (на AdGuard VPS2) — вставляем в начало ───────────
iptables -t nat -C PREROUTING -i awg1 -p udp --dport 53 -j DNAT --to-destination "${ADGUARD_IP}:53" 2>/dev/null \
  || iptables -t nat -I PREROUTING 1 -i awg1 -p udp --dport 53 -j DNAT --to-destination "${ADGUARD_IP}:53"
iptables -t nat -C PREROUTING -i awg1 -p tcp --dport 53 -j DNAT --to-destination "${ADGUARD_IP}:53" 2>/dev/null \
  || iptables -t nat -I PREROUTING 1 -i awg1 -p tcp --dport 53 -j DNAT --to-destination "${ADGUARD_IP}:53"
log "Восстановлены старые DNS DNAT → ${ADGUARD_IP}:53"

# ── 2. Удалить новые DNAT (на dnsmasq VPS1) ─────────────────────────────────
ipt_drop_all nat PREROUTING -i awg1 -p udp --dport 53 -j DNAT --to-destination "${DNSMASQ_IP}:53"
ipt_drop_all nat PREROUTING -i awg1 -p tcp --dport 53 -j DNAT --to-destination "${DNSMASQ_IP}:53"
log "Удалены новые DNS DNAT → ${DNSMASQ_IP}:53"

# ── 3. Останавливаем dnsmasq (без disable — на случай повторного включения) ─
systemctl stop dnsmasq 2>/dev/null || true
log "dnsmasq остановлен"

# ── 4. Mangle CONNMARK/MARK — удаляем все дубликаты, если они есть ──────────
ipt_drop_all mangle PREROUTING -i awg1 -m conntrack --ctstate ESTABLISHED,RELATED -j CONNMARK --restore-mark
ipt_drop_all mangle PREROUTING -i awg1 -m conntrack --ctstate NEW -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$MARK_HEX"
ipt_drop_all mangle PREROUTING -i awg1 -m conntrack --ctstate NEW -j CONNMARK --save-mark
log "Удалены mangle CONNMARK/MARK правила (включая дубликаты, если были)"

# ── 5. Policy routing ───────────────────────────────────────────────────────
while ip rule show | grep -q "fwmark $MARK_HEX lookup $ROUTE_TABLE"; do
    ip rule del fwmark "$MARK_HEX" table "$ROUTE_TABLE" priority 100 2>/dev/null || break
done
ip route flush table "$ROUTE_TABLE" 2>/dev/null || true
log "Удалены ip rule fwmark и таблица $ROUTE_TABLE"

# ── 6. MASQUERADE на основном интерфейсе — удаляем все дубликаты ────────────
if [[ -n "$MAIN_IF" ]]; then
    ipt_drop_all nat POSTROUTING -s "$CLIENT_CIDR" -o "$MAIN_IF" -j MASQUERADE
    log "Удалён MASQUERADE для $CLIENT_CIDR через $MAIN_IF"
fi

# ── 7. ipset destroy ────────────────────────────────────────────────────────
ipset destroy "$IPSET_NAME" 2>/dev/null || true
log "Удалён ipset $IPSET_NAME"

log "Rollback завершён. Состояние идентично пред-split-tunneling."
