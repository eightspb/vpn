#!/usr/bin/env bash
# =============================================================================
# restore-vpn-routing.sh — восстановление policy routing после рестарта networkd
#
# Кладётся в /usr/local/sbin/restore-vpn-routing.sh.
# Вызывается из systemd-networkd drop-in (ExecStartPost).
#
# Восстанавливает:
#   1. ip rule from CLIENT_CIDR table 200  → awg0 (основной маршрут клиентов)
#   2. Если установлен split tunneling — ip rule fwmark MARK_HEX table ROUTE_TABLE
#      и MASQUERADE для split-трафика
#
# Идемпотентен. Best-effort (set +e), networkd не должен ломаться из-за него.
#
# Параметры через окружение (defaults совпадают с split-tunnel-apply.sh):
#   CLIENT_NET, TUN_NET, MARK_HEX, ROUTE_TABLE, MAIN_TABLE
# =============================================================================

set +e

CLIENT_NET="${CLIENT_NET:-10.9.0}"
TUN_NET="${TUN_NET:-10.8.0}"
MARK_HEX="${MARK_HEX:-0x100}"
ROUTE_TABLE="${ROUTE_TABLE:-100}"
MAIN_TABLE="${MAIN_TABLE:-200}"
CLIENT_CIDR="${CLIENT_NET}.0/24"
ADGUARD_IP="${TUN_NET}.2"

sleep 2

ip link show awg1 >/dev/null 2>&1 || exit 0
ip link show awg0 >/dev/null 2>&1 || exit 0

# ── 1. Основное правило: трафик от клиентов awg1 → table MAIN_TABLE → awg0 ──
if ! ip rule show | grep -q "from ${CLIENT_CIDR} lookup ${MAIN_TABLE}"; then
    ip rule add from "$CLIENT_CIDR" table "$MAIN_TABLE"
fi
if ! ip route show table "$MAIN_TABLE" 2>/dev/null | grep -q "default via ${ADGUARD_IP} dev awg0"; then
    ip route add default via "$ADGUARD_IP" dev awg0 table "$MAIN_TABLE" 2>/dev/null
fi

# ── 2. Split tunneling правила (только если установлен) ─────────────────────
if [ -x /usr/local/sbin/split-tunnel-apply.sh ] && ipset list ru_subnets >/dev/null 2>&1; then
    if ! ip rule show | grep -q "fwmark ${MARK_HEX} lookup ${ROUTE_TABLE}"; then
        ip rule add fwmark "$MARK_HEX" table "$ROUTE_TABLE" priority 100
    fi

    MAIN_IF=$(ip route show default | awk '/^default/ {print $5; exit}')
    MAIN_GW=$(ip route show default | awk '/^default/ {print $3; exit}')

    if [ -n "$MAIN_IF" ] && [ -n "$MAIN_GW" ]; then
        ip route replace default via "$MAIN_GW" dev "$MAIN_IF" table "$ROUTE_TABLE" 2>/dev/null

        if ! iptables -t nat -C POSTROUTING -s "$CLIENT_CIDR" -o "$MAIN_IF" -j MASQUERADE 2>/dev/null; then
            iptables -t nat -A POSTROUTING -s "$CLIENT_CIDR" -o "$MAIN_IF" -j MASQUERADE
        fi
    fi
fi

logger -t vpn-routing "ip rule restored after networkd restart"
exit 0
