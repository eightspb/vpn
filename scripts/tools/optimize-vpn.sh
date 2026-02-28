#!/usr/bin/env bash
# =============================================================================
# optimize-vpn.sh — применяет оптимизации производительности на VPS1 и VPS2
#
# Использование:
#   bash optimize-vpn.sh [опции]
#
# Опции:
#   --benchmark-only   только замер метрик, без применения изменений
#   --vps1-only        применить только на VPS1
#   --vps2-only        применить только на VPS2
#   --help             показать эту справку
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

# ── Параметры по умолчанию ────────────────────────────────────────────────────
VPS1_IP=""; VPS1_USER=""; VPS1_KEY=""; VPS1_PASS=""
VPS2_IP=""; VPS2_USER=""; VPS2_KEY=""; VPS2_PASS=""

BENCHMARK_ONLY=false
VPS1_ONLY=false
VPS2_ONLY=false

# ── Разбор аргументов ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --benchmark-only) BENCHMARK_ONLY=true ;;
        --vps1-only)      VPS1_ONLY=true ;;
        --vps2-only)      VPS2_ONLY=true ;;
        --help|-h)
            sed -n '2,12p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) warn "Неизвестный аргумент: $1" ;;
    esac
    shift
done

# ── Загрузка конфигурации ─────────────────────────────────────────────────────
load_defaults_from_files

VPS1_USER="${VPS1_USER:-root}"
VPS2_USER="${VPS2_USER:-root}"

[[ -z "${VPS1_IP}" ]] && err "VPS1_IP не задан. Проверьте .env"
[[ -z "${VPS2_IP:-}" ]] && { VPS2_IP=""; }

VPS1_KEY="$(expand_tilde "${VPS1_KEY}")"
VPS2_KEY="$(expand_tilde "${VPS2_KEY:-}")"
VPS1_KEY="$(prepare_key_for_ssh "${VPS1_KEY}")"
VPS2_KEY="$(prepare_key_for_ssh "${VPS2_KEY:-}")"
trap cleanup_temp_keys EXIT

check_deps

# ── Функция сбора метрик ──────────────────────────────────────────────────────
collect_metrics() {
    local label="$1" ip="$2" user="$3" key="$4" pass="$5"
    log "Сбор метрик на ${label} (${ip})..."

    local ping_out speed mtu_awg0 mtu_awg1 handshakes
    local rmem wmem congestion backlog

    ping_out="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "ping -c 10 -q 8.8.8.8 2>/dev/null | tail -2" 30 2>/dev/null || echo 'N/A')"

    speed="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "curl -o /dev/null -w '%{speed_download}' --max-time 15 'https://speed.cloudflare.com/__down?bytes=50000000' 2>/dev/null || echo 0" 25 2>/dev/null || echo '0')"

    mtu_awg0="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "ip link show awg0 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print \$2}' || echo 'N/A'" 10 2>/dev/null || echo 'N/A')"

    mtu_awg1="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "ip link show awg1 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print \$2}' || echo 'N/A'" 10 2>/dev/null || echo 'N/A')"

    handshakes="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "awg show all latest-handshakes 2>/dev/null | head -5 || echo 'N/A'" 10 2>/dev/null || echo 'N/A')"

    rmem="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "sysctl -n net.core.rmem_max 2>/dev/null || echo 'N/A'" 10 2>/dev/null || echo 'N/A')"

    wmem="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "sysctl -n net.core.wmem_max 2>/dev/null || echo 'N/A'" 10 2>/dev/null || echo 'N/A')"

    congestion="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'N/A'" 10 2>/dev/null || echo 'N/A')"

    backlog="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo 'N/A'" 10 2>/dev/null || echo 'N/A')"

    printf "PING_OUT=%s\nSPEED=%s\nMTU_AWG0=%s\nMTU_AWG1=%s\nHANDSHAKES=%s\nRMEM=%s\nWMEM=%s\nCONGESTION=%s\nBACKLOG=%s\n" \
        "$ping_out" "$speed" "$mtu_awg0" "$mtu_awg1" "$handshakes" \
        "$rmem" "$wmem" "$congestion" "$backlog"
}

# ── Функция применения sysctl ─────────────────────────────────────────────────
apply_sysctl() {
    local label="$1" ip="$2" user="$3" key="$4" pass="$5"
    step "Применение sysctl на ${label}"

    ssh_run_script "$ip" "$user" "$key" "$pass" '#!/bin/bash
set -e
cat > /etc/sysctl.d/99-vpn.conf << '"'"'EOF'"'"'
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.core.netdev_max_backlog=16384
net.core.somaxconn=4096
net.ipv4.tcp_rmem=4096 131072 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_no_metrics_save=1
net.netfilter.nf_conntrack_max=524288
net.netfilter.nf_conntrack_tcp_timeout_established=7200
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
sysctl --system > /dev/null 2>&1
echo "sysctl применён"
'
    ok "${label}: sysctl применён"
}

# ── Функция оптимизации MTU на VPS1 ──────────────────────────────────────────
apply_mtu_vps1() {
    local ip="$1" user="$2" key="$3" pass="$4"
    step "Применение MTU на VPS1"

    ssh_run_script "$ip" "$user" "$key" "$pass" '#!/bin/bash
ip link set awg0 mtu 1420 2>/dev/null || true
ip link set awg1 mtu 1360 2>/dev/null || true
sed -i "s/^MTU = 1320/MTU = 1420/" /etc/amnezia/amneziawg/awg0.conf 2>/dev/null || true
sed -i "s/^MTU = 1280/MTU = 1360/" /etc/amnezia/amneziawg/awg1.conf 2>/dev/null || true
echo "MTU обновлён"
'
    ok "VPS1: MTU обновлён (awg0=1420, awg1=1360)"
}

# ── Функция обновления MSS clamp на VPS1 ─────────────────────────────────────
apply_mss_vps1() {
    local ip="$1" user="$2" key="$3" pass="$4"
    step "Применение MSS clamp на VPS1"

    ssh_run_script "$ip" "$user" "$key" "$pass" '#!/bin/bash
iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null || true
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1320 2>/dev/null || \
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1320
sed -i "s/--set-mss 1200/--set-mss 1320/g" /etc/amnezia/amneziawg/awg1.conf 2>/dev/null || true
echo "MSS clamp обновлён"
'
    ok "VPS1: MSS clamp обновлён (1320)"
}

# ── Функция обновления Junk параметров на VPS1 ────────────────────────────────
apply_junk_vps1() {
    local ip="$1" user="$2" key="$3" pass="$4"
    step "Применение Junk параметров на VPS1"

    ssh_run_script "$ip" "$user" "$key" "$pass" '#!/bin/bash
sed -i "s/^Jc   = 5$/Jc   = 2/" /etc/amnezia/amneziawg/awg1.conf
sed -i "s/^Jmin = 50$/Jmin = 20/" /etc/amnezia/amneziawg/awg1.conf
sed -i "s/^Jmax = 1000$/Jmax = 200/" /etc/amnezia/amneziawg/awg1.conf
sed -i "s/^S1   = 30$/S1   = 15/" /etc/amnezia/amneziawg/awg1.conf
sed -i "s/^S2   = 40$/S2   = 20/" /etc/amnezia/amneziawg/awg1.conf
echo "Junk параметры обновлены"
'
    ok "VPS1: Junk параметры обновлены"
}

# ── Функция обновления PersistentKeepalive ────────────────────────────────────
apply_keepalive_vps1() {
    local ip="$1" user="$2" key="$3" pass="$4"
    step "Применение PersistentKeepalive на VPS1"

    ssh_run_script "$ip" "$user" "$key" "$pass" '#!/bin/bash
sed -i "s/^PersistentKeepalive = 25$/PersistentKeepalive = 60/" /etc/amnezia/amneziawg/awg0.conf
echo "PersistentKeepalive обновлён"
'
    ok "VPS1: PersistentKeepalive обновлён (60)"
}

apply_keepalive_vps2() {
    local ip="$1" user="$2" key="$3" pass="$4"
    step "Применение PersistentKeepalive на VPS2"

    ssh_run_script "$ip" "$user" "$key" "$pass" '#!/bin/bash
sed -i "s/^PersistentKeepalive = 25$/PersistentKeepalive = 60/" /etc/amnezia/amneziawg/awg0.conf
echo "PersistentKeepalive обновлён"
'
    ok "VPS2: PersistentKeepalive обновлён (60)"
}

# ── Функция перезапуска WireGuard ─────────────────────────────────────────────
restart_wg_vps1() {
    local ip="$1" user="$2" key="$3" pass="$4"
    step "Перезапуск WireGuard на VPS1"

    ssh_run_script "$ip" "$user" "$key" "$pass" '#!/bin/bash
systemctl restart awg-quick@awg0 2>/dev/null || awg-quick down awg0 2>/dev/null && awg-quick up awg0 2>/dev/null || true
systemctl restart awg-quick@awg1 2>/dev/null || awg-quick down awg1 2>/dev/null && awg-quick up awg1 2>/dev/null || true
echo "WireGuard перезапущен"
'
    ok "VPS1: WireGuard перезапущен"
}

restart_wg_vps2() {
    local ip="$1" user="$2" key="$3" pass="$4"
    step "Перезапуск WireGuard на VPS2"

    ssh_run_script "$ip" "$user" "$key" "$pass" '#!/bin/bash
systemctl restart awg-quick@awg0 2>/dev/null || awg-quick down awg0 2>/dev/null && awg-quick up awg0 2>/dev/null || true
echo "WireGuard перезапущен"
'
    ok "VPS2: WireGuard перезапущен"
}

# ── Функция форматирования отчёта ─────────────────────────────────────────────
print_report() {
    local label="$1"
    local before_ping="$2" after_ping="$3"
    local before_speed="$4" after_speed="$5"
    local before_mtu0="$6" after_mtu0="$7"
    local before_mtu1="$8" after_mtu1="$9"
    local before_rmem="${10}" after_rmem="${11}"
    local before_congestion="${12}" after_congestion="${13}"

    local before_speed_mb after_speed_mb
    before_speed_mb="$(awk "BEGIN{printf \"%.1f\", ${before_speed:-0}/1048576}")"
    after_speed_mb="$(awk "BEGIN{printf \"%.1f\", ${after_speed:-0}/1048576}")"

    echo ""
    echo "  ${label}:"
    printf "  %-28s %-20s %-20s\n" "Метрика" "До" "После"
    printf "  %-28s %-20s %-20s\n" "----------------------------" "--------------------" "--------------------"
    printf "  %-28s %-20s %-20s\n" "Ping (avg/jitter)" "${before_ping:-N/A}" "${after_ping:-N/A}"
    printf "  %-28s %-20s %-20s\n" "Скорость загрузки (МБ/с)" "${before_speed_mb}" "${after_speed_mb}"
    printf "  %-28s %-20s %-20s\n" "MTU awg0" "${before_mtu0:-N/A}" "${after_mtu0:-N/A}"
    printf "  %-28s %-20s %-20s\n" "MTU awg1" "${before_mtu1:-N/A}" "${after_mtu1:-N/A}"
    printf "  %-28s %-20s %-20s\n" "rmem_max" "${before_rmem:-N/A}" "${after_rmem:-N/A}"
    printf "  %-28s %-20s %-20s\n" "tcp_congestion_control" "${before_congestion:-N/A}" "${after_congestion:-N/A}"
}

# ── Вспомогательная функция извлечения ping avg ───────────────────────────────
extract_ping_summary() {
    local raw="$1"
    echo "$raw" | grep -oE '[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+' | head -1 || echo "N/A"
}

# ── Основной поток ────────────────────────────────────────────────────────────
step "Оптимизация VPN — старт"

DO_VPS1=true
DO_VPS2=true
[[ "${VPS1_ONLY}" == "true" ]] && DO_VPS2=false
[[ "${VPS2_ONLY}" == "true" ]] && DO_VPS1=false

# Проверяем наличие VPS2
if [[ -z "${VPS2_IP:-}" ]]; then
    warn "VPS2_IP не задан — пропускаем VPS2"
    DO_VPS2=false
fi

# ── Замер ДО ──────────────────────────────────────────────────────────────────
step "Замер метрик ДО оптимизации"

VPS1_BEFORE=""
VPS2_BEFORE=""

if [[ "${DO_VPS1}" == "true" ]]; then
    VPS1_BEFORE="$(collect_metrics "VPS1" "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS")"
fi

if [[ "${DO_VPS2}" == "true" ]]; then
    VPS2_BEFORE="$(collect_metrics "VPS2" "$VPS2_IP" "$VPS2_USER" "$VPS2_KEY" "${VPS2_PASS:-}")"
fi

if [[ "${BENCHMARK_ONLY}" == "true" ]]; then
    step "Режим --benchmark-only: изменения не применяются"
    echo ""
    echo "=== Текущие метрики VPS1 ==="
    echo "${VPS1_BEFORE}"
    if [[ "${DO_VPS2}" == "true" ]]; then
        echo ""
        echo "=== Текущие метрики VPS2 ==="
        echo "${VPS2_BEFORE}"
    fi
    exit 0
fi

# ── Применение оптимизаций ────────────────────────────────────────────────────
if [[ "${DO_VPS1}" == "true" ]]; then
    step "Оптимизация VPS1 (${VPS1_IP})"
    apply_sysctl    "VPS1" "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS"
    apply_mtu_vps1         "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS"
    apply_mss_vps1         "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS"
    apply_junk_vps1        "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS"
    apply_keepalive_vps1   "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS"
    restart_wg_vps1        "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS"
fi

if [[ "${DO_VPS2}" == "true" ]]; then
    step "Оптимизация VPS2 (${VPS2_IP})"
    apply_sysctl    "VPS2" "$VPS2_IP" "$VPS2_USER" "$VPS2_KEY" "${VPS2_PASS:-}"
    apply_keepalive_vps2   "$VPS2_IP" "$VPS2_USER" "$VPS2_KEY" "${VPS2_PASS:-}"
    restart_wg_vps2        "$VPS2_IP" "$VPS2_USER" "$VPS2_KEY" "${VPS2_PASS:-}"
fi

# ── Замер ПОСЛЕ ───────────────────────────────────────────────────────────────
step "Замер метрик ПОСЛЕ оптимизации"

VPS1_AFTER=""
VPS2_AFTER=""

if [[ "${DO_VPS1}" == "true" ]]; then
    VPS1_AFTER="$(collect_metrics "VPS1" "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS")"
fi

if [[ "${DO_VPS2}" == "true" ]]; then
    VPS2_AFTER="$(collect_metrics "VPS2" "$VPS2_IP" "$VPS2_USER" "$VPS2_KEY" "${VPS2_PASS:-}")"
fi

# ── Отчёт ─────────────────────────────────────────────────────────────────────
step "Сравнительный отчёт"
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║              Результаты оптимизации VPN                             ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"

if [[ "${DO_VPS1}" == "true" ]]; then
    b_ping="$(extract_ping_summary "$(parse_kv "$VPS1_BEFORE" PING_OUT)")"
    a_ping="$(extract_ping_summary "$(parse_kv "$VPS1_AFTER"  PING_OUT)")"
    b_speed="$(parse_kv "$VPS1_BEFORE" SPEED)"
    a_speed="$(parse_kv "$VPS1_AFTER"  SPEED)"
    b_mtu0="$(parse_kv "$VPS1_BEFORE" MTU_AWG0)"
    a_mtu0="$(parse_kv "$VPS1_AFTER"  MTU_AWG0)"
    b_mtu1="$(parse_kv "$VPS1_BEFORE" MTU_AWG1)"
    a_mtu1="$(parse_kv "$VPS1_AFTER"  MTU_AWG1)"
    b_rmem="$(parse_kv "$VPS1_BEFORE" RMEM)"
    a_rmem="$(parse_kv "$VPS1_AFTER"  RMEM)"
    b_cong="$(parse_kv "$VPS1_BEFORE" CONGESTION)"
    a_cong="$(parse_kv "$VPS1_AFTER"  CONGESTION)"
    print_report "VPS1 (${VPS1_IP})" \
        "$b_ping" "$a_ping" "$b_speed" "$a_speed" \
        "$b_mtu0" "$a_mtu0" "$b_mtu1" "$a_mtu1" \
        "$b_rmem" "$a_rmem" "$b_cong" "$a_cong"
fi

if [[ "${DO_VPS2}" == "true" ]]; then
    b_ping="$(extract_ping_summary "$(parse_kv "$VPS2_BEFORE" PING_OUT)")"
    a_ping="$(extract_ping_summary "$(parse_kv "$VPS2_AFTER"  PING_OUT)")"
    b_speed="$(parse_kv "$VPS2_BEFORE" SPEED)"
    a_speed="$(parse_kv "$VPS2_AFTER"  SPEED)"
    b_mtu0="$(parse_kv "$VPS2_BEFORE" MTU_AWG0)"
    a_mtu0="$(parse_kv "$VPS2_AFTER"  MTU_AWG0)"
    b_mtu1="$(parse_kv "$VPS2_BEFORE" MTU_AWG1)"
    a_mtu1="$(parse_kv "$VPS2_AFTER"  MTU_AWG1)"
    b_rmem="$(parse_kv "$VPS2_BEFORE" RMEM)"
    a_rmem="$(parse_kv "$VPS2_AFTER"  RMEM)"
    b_cong="$(parse_kv "$VPS2_BEFORE" CONGESTION)"
    a_cong="$(parse_kv "$VPS2_AFTER"  CONGESTION)"
    print_report "VPS2 (${VPS2_IP})" \
        "$b_ping" "$a_ping" "$b_speed" "$a_speed" \
        "$b_mtu0" "$a_mtu0" "$b_mtu1" "$a_mtu1" \
        "$b_rmem" "$a_rmem" "$b_cong" "$a_cong"
fi

echo ""
ok "Оптимизация завершена"
