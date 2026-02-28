#!/usr/bin/env bash
# =============================================================================
# load-test.sh — нагрузочное тестирование VPN-серверов
#
# Проверяет: максимальное число соединений, пропускную способность,
# нагрузку CPU/RAM/диска, деградацию latency под нагрузкой.
#
# Использование:
#   bash load-test.sh [опции]
#
# Опции:
#   --vps1-only          тестировать только VPS1
#   --vps2-only          тестировать только VPS2
#   --max-connections N  макс. число параллельных соединений (default: 500)
#   --step N             шаг наращивания соединений (default: 50)
#   --duration N         длительность каждого шага в секундах (default: 10)
#   --bandwidth-only     только тест пропускной способности
#   --connections-only   только тест соединений
#   --quick              быстрый режим (100 соединений, шаг 25, 5 сек)
#   --output FILE        сохранить отчёт в файл (default: stdout)
#   --help               показать справку
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ── Параметры по умолчанию ────────────────────────────────────────────────────
VPS1_IP=""; VPS1_USER="root"; VPS1_KEY=""; VPS1_PASS=""
VPS2_IP=""; VPS2_USER="root"; VPS2_KEY=""; VPS2_PASS=""

VPS1_ONLY=false
VPS2_ONLY=false
MAX_CONNECTIONS=500
STEP=50
DURATION=10
BANDWIDTH_ONLY=false
CONNECTIONS_ONLY=false
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps1-only)         VPS1_ONLY=true ;;
        --vps2-only)         VPS2_ONLY=true ;;
        --max-connections)   shift; MAX_CONNECTIONS="$1" ;;
        --step)              shift; STEP="$1" ;;
        --duration)          shift; DURATION="$1" ;;
        --bandwidth-only)    BANDWIDTH_ONLY=true ;;
        --connections-only)  CONNECTIONS_ONLY=true ;;
        --quick)             MAX_CONNECTIONS=100; STEP=25; DURATION=5 ;;
        --output)            shift; OUTPUT_FILE="$1" ;;
        --help|-h)
            sed -n '2,21p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) warn "Неизвестный аргумент: $1" ;;
    esac
    shift
done

load_defaults_from_files

[[ -z "${VPS1_IP}" ]] && err "VPS1_IP не задан. Проверьте .env"

VPS1_KEY="$(expand_tilde "${VPS1_KEY}")"
VPS2_KEY="$(expand_tilde "${VPS2_KEY:-}")"
VPS1_KEY="$(prepare_key_for_ssh "${VPS1_KEY}")"
VPS2_KEY="$(prepare_key_for_ssh "${VPS2_KEY:-}")"
trap cleanup_temp_keys EXIT

check_deps

DO_VPS1=true
DO_VPS2=true
[[ "${VPS1_ONLY}" == "true" ]] && DO_VPS2=false
[[ "${VPS2_ONLY}" == "true" ]] && DO_VPS1=false
[[ -z "${VPS2_IP:-}" ]] && { warn "VPS2_IP не задан — пропускаем VPS2"; DO_VPS2=false; }

REPORT=""
report() { REPORT+="$*"$'\n'; }

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

# ── Установка зависимостей на сервере ─────────────────────────────────────────
install_load_tools() {
    local ip="$1" user="$2" key="$3" pass="$4" label="$5"
    log "Проверка/установка инструментов нагрузочного тестирования на ${label}..."

    ssh_run_script "$ip" "$user" "$key" "$pass" '#!/bin/bash
set -e
missing=""
for cmd in iperf3 ab nproc free; do
    command -v "$cmd" &>/dev/null || missing="$missing $cmd"
done
if [[ -n "$missing" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq iperf3 apache2-utils sysstat >/dev/null 2>&1 || true
fi
echo "tools_ready"
'
}

# ── Сбор системных метрик ─────────────────────────────────────────────────────
collect_system_metrics() {
    local ip="$1" user="$2" key="$3" pass="$4"

    ssh_exec "$ip" "$user" "$key" "$pass" '
cpu_count=$(nproc 2>/dev/null || echo 1)
cpu_load=$(cat /proc/loadavg 2>/dev/null | awk "{print \$1\"/\"\$2\"/\"\$3}" || echo "N/A")
cpu_usage=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk "{print \$2+\$4}" || echo "N/A")

mem_total=$(free -m 2>/dev/null | awk "/^Mem:/{print \$2}" || echo "N/A")
mem_used=$(free -m 2>/dev/null | awk "/^Mem:/{print \$3}" || echo "N/A")
mem_available=$(free -m 2>/dev/null | awk "/^Mem:/{print \$7}" || echo "N/A")
swap_used=$(free -m 2>/dev/null | awk "/^Swap:/{print \$3}" || echo "0")

disk_usage=$(df -h / 2>/dev/null | awk "NR==2{print \$5}" || echo "N/A")
disk_io_read=$(cat /proc/diskstats 2>/dev/null | awk "\$3~/^(s|v)da$/{print \$6}" | head -1 || echo "0")
disk_io_write=$(cat /proc/diskstats 2>/dev/null | awk "\$3~/^(s|v)da$/{print \$10}" | head -1 || echo "0")

net_conns=$(ss -s 2>/dev/null | awk "/^TCP:/{print \$2}" || echo "N/A")
net_established=$(ss -tn state established 2>/dev/null | wc -l || echo "0")
conntrack_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "N/A")
conntrack_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "N/A")

awg_peers=$(awg show all latest-handshakes 2>/dev/null | wc -l || echo "0")
awg_transfer=$(awg show all transfer 2>/dev/null || echo "none")

uptime_sec=$(awk "{print \$1}" /proc/uptime 2>/dev/null || echo "N/A")

printf "CPU_COUNT=%s\nCPU_LOAD=%s\nCPU_USAGE=%s\n" "$cpu_count" "$cpu_load" "$cpu_usage"
printf "MEM_TOTAL=%s\nMEM_USED=%s\nMEM_AVAILABLE=%s\nSWAP_USED=%s\n" "$mem_total" "$mem_used" "$mem_available" "$swap_used"
printf "DISK_USAGE=%s\nDISK_IO_READ=%s\nDISK_IO_WRITE=%s\n" "$disk_usage" "$disk_io_read" "$disk_io_write"
printf "NET_CONNS=%s\nNET_ESTABLISHED=%s\nCONNTRACK_COUNT=%s\nCONNTRACK_MAX=%s\n" "$net_conns" "$net_established" "$conntrack_count" "$conntrack_max"
printf "AWG_PEERS=%s\nUPTIME=%s\n" "$awg_peers" "$uptime_sec"
' 30 2>/dev/null || echo "COLLECT_ERROR=true"
}

# ── Тест пропускной способности (bandwidth) ──────────────────────────────────
test_bandwidth() {
    local label="$1" ip="$2" user="$3" key="$4" pass="$5"
    step "Тест пропускной способности: ${label}"

    log "Запуск iperf3-сервера на ${label}..."
    ssh_exec "$ip" "$user" "$key" "$pass" \
        "pkill -f 'iperf3 -s' 2>/dev/null; iperf3 -s -D -p 5201 --one-off 2>/dev/null || true" 10 2>/dev/null || true
    sleep 2

    log "Тест скорости загрузки (Cloudflare 100MB)..."
    local dl_speed
    dl_speed="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "curl -o /dev/null -w '%{speed_download}' --max-time 30 'https://speed.cloudflare.com/__down?bytes=104857600' 2>/dev/null || echo 0" 40 2>/dev/null || echo '0')"
    local dl_mb
    dl_mb="$(awk "BEGIN{printf \"%.2f\", ${dl_speed:-0}/1048576}")"

    log "Тест скорости загрузки (Cloudflare 100MB, 4 потока)..."
    local dl_parallel
    dl_parallel="$(ssh_exec "$ip" "$user" "$key" "$pass" '
total=0
for i in 1 2 3 4; do
    speed=$(curl -o /dev/null -w "%{speed_download}" --max-time 20 "https://speed.cloudflare.com/__down?bytes=26214400" 2>/dev/null || echo 0)
    total=$(awk "BEGIN{printf \"%.0f\", '"$total"'+'"$speed"'}")
done &
wait
echo "$total"
' 60 2>/dev/null || echo '0')"
    local dl_parallel_mb
    dl_parallel_mb="$(awk "BEGIN{printf \"%.2f\", ${dl_parallel:-0}/1048576}")"

    log "Тест скорости отдачи (Cloudflare)..."
    local ul_speed
    ul_speed="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "dd if=/dev/zero bs=1M count=50 2>/dev/null | curl -X POST -d @- -w '%{speed_upload}' --max-time 30 'https://speed.cloudflare.com/__up' -o /dev/null 2>/dev/null || echo 0" 40 2>/dev/null || echo '0')"
    local ul_mb
    ul_mb="$(awk "BEGIN{printf \"%.2f\", ${ul_speed:-0}/1048576}")"

    ssh_exec "$ip" "$user" "$key" "$pass" "pkill -f 'iperf3 -s' 2>/dev/null || true" 5 2>/dev/null || true

    report ""
    report "┌─────────────────────────────────────────────────────────────────┐"
    report "│  Пропускная способность: $(printf '%-38s' "${label}")│"
    report "├─────────────────────────────────────────────────────────────────┤"
    report "│  $(printf '%-40s' "Скорость загрузки (1 поток)")$(printf '%-22s' "${dl_mb} МБ/с")│"
    report "│  $(printf '%-40s' "Скорость загрузки (4 потока)")$(printf '%-22s' "${dl_parallel_mb} МБ/с")│"
    report "│  $(printf '%-40s' "Скорость отдачи (1 поток)")$(printf '%-22s' "${ul_mb} МБ/с")│"
    report "└─────────────────────────────────────────────────────────────────┘"
}

# ── Тест соединений (connection scaling) ─────────────────────────────────────
test_connections() {
    local label="$1" ip="$2" user="$3" key="$4" pass="$5"
    step "Тест масштабирования соединений: ${label}"

    log "Подготовка HTTP-сервера для теста соединений на ${label}..."
    ssh_run_script "$ip" "$user" "$key" "$pass" '#!/bin/bash
pkill -f "python3 -m http.server 18080" 2>/dev/null || true
mkdir -p /tmp/loadtest
echo "ok" > /tmp/loadtest/health
cd /tmp/loadtest
nohup python3 -m http.server 18080 --bind 127.0.0.1 > /dev/null 2>&1 &
sleep 1
echo "http_server_started"
'
    sleep 2

    report ""
    report "┌─────────────────────────────────────────────────────────────────┐"
    report "│  Масштабирование соединений: $(printf '%-34s' "${label}")│"
    report "├──────────┬──────────┬──────────┬──────────┬──────────┬─────────┤"
    report "│ Соедин.  │ Req/s    │ Latency  │ CPU %    │ RAM MB   │ Conntr. │"
    report "├──────────┼──────────┼──────────┼──────────┼──────────┼─────────┤"

    local prev_latency=""
    local degradation_at=0
    local current="${STEP}"

    while [[ "${current}" -le "${MAX_CONNECTIONS}" ]]; do
        log "  Тест: ${current} параллельных соединений..."

        local result
        result="$(ssh_exec "$ip" "$user" "$key" "$pass" "
total_requests=\$(( ${current} * 10 ))
[[ \$total_requests -lt ${current} ]] && total_requests=${current}

ab_out=\$(ab -n \$total_requests -c ${current} -t ${DURATION} -r -s 5 http://127.0.0.1:18080/health 2>&1 || echo 'ab_error')
rps=\$(echo \"\$ab_out\" | grep 'Requests per second' | awk '{print \$4}' || echo 'N/A')
latency=\$(echo \"\$ab_out\" | grep 'Time per request.*mean\b' | head -1 | awk '{print \$4}' || echo 'N/A')
failed=\$(echo \"\$ab_out\" | grep 'Failed requests' | awk '{print \$3}' || echo '0')

cpu=\$(top -bn1 2>/dev/null | grep 'Cpu(s)' | awk '{printf \"%.1f\", \$2+\$4}' || echo 'N/A')
mem=\$(free -m 2>/dev/null | awk '/^Mem:/{print \$3}' || echo 'N/A')
ct=\$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 'N/A')

printf 'RPS=%s LATENCY=%s FAILED=%s CPU=%s MEM=%s CONNTRACK=%s\n' \"\$rps\" \"\$latency\" \"\$failed\" \"\$cpu\" \"\$mem\" \"\$ct\"
" 60 2>/dev/null || echo 'RPS=N/A LATENCY=N/A FAILED=N/A CPU=N/A MEM=N/A CONNTRACK=N/A')"

        local rps latency failed cpu mem ct
        rps="$(echo "$result" | grep -oP 'RPS=\K[^ ]+' || echo 'N/A')"
        latency="$(echo "$result" | grep -oP 'LATENCY=\K[^ ]+' || echo 'N/A')"
        failed="$(echo "$result" | grep -oP 'FAILED=\K[^ ]+' || echo '0')"
        cpu="$(echo "$result" | grep -oP 'CPU=\K[^ ]+' || echo 'N/A')"
        mem="$(echo "$result" | grep -oP 'MEM=\K[^ ]+' || echo 'N/A')"
        ct="$(echo "$result" | grep -oP 'CONNTRACK=\K[^ ]+' || echo 'N/A')"

        local latency_marker=""
        if [[ -n "${prev_latency}" && "${prev_latency}" != "N/A" && "${latency}" != "N/A" ]]; then
            local ratio
            ratio="$(awk "BEGIN{r=${latency}/${prev_latency}; printf \"%.2f\", r}" 2>/dev/null || echo "1.00")"
            if awk "BEGIN{exit (${ratio} > 2.0) ? 0 : 1}" 2>/dev/null; then
                latency_marker=" ⚠"
                [[ "${degradation_at}" -eq 0 ]] && degradation_at="${current}"
            fi
        fi
        [[ "${latency}" != "N/A" ]] && prev_latency="${latency}"

        report "│ $(printf '%-8s' "${current}") │ $(printf '%-8s' "${rps}") │ $(printf '%-8s' "${latency}${latency_marker}") │ $(printf '%-8s' "${cpu}") │ $(printf '%-8s' "${mem}") │ $(printf '%-7s' "${ct}") │"

        current=$(( current + STEP ))
    done

    report "└──────────┴──────────┴──────────┴──────────┴──────────┴─────────┘"

    if [[ "${degradation_at}" -gt 0 ]]; then
        report "  ⚠ Деградация latency (>2x) обнаружена при ${degradation_at} соединениях"
    else
        report "  ✓ Деградация latency не обнаружена до ${MAX_CONNECTIONS} соединений"
    fi

    ssh_exec "$ip" "$user" "$key" "$pass" \
        "pkill -f 'python3 -m http.server 18080' 2>/dev/null || true" 5 2>/dev/null || true
}

# ── Тест conntrack (нагрузка на таблицу соединений) ──────────────────────────
test_conntrack() {
    local label="$1" ip="$2" user="$3" key="$4" pass="$5"
    step "Тест conntrack: ${label}"

    local result
    result="$(ssh_exec "$ip" "$user" "$key" "$pass" '
ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "N/A")
ct_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "N/A")
ct_buckets=$(cat /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || echo "N/A")
ct_timeout=$(sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established 2>/dev/null || echo "N/A")

udp_conns=$(conntrack -C 2>/dev/null || cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "N/A")
tcp_est=$(ss -tn state established 2>/dev/null | wc -l || echo "0")
tcp_wait=$(ss -tn state time-wait 2>/dev/null | wc -l || echo "0")

printf "CT_MAX=%s\nCT_COUNT=%s\nCT_BUCKETS=%s\nCT_TIMEOUT=%s\nTCP_EST=%s\nTCP_WAIT=%s\n" \
    "$ct_max" "$ct_count" "$ct_buckets" "$ct_timeout" "$tcp_est" "$tcp_wait"
' 15 2>/dev/null || echo 'CT_MAX=N/A')"

    local ct_max ct_count ct_buckets ct_timeout tcp_est tcp_wait
    ct_max="$(echo "$result" | grep -oP 'CT_MAX=\K.*' || echo 'N/A')"
    ct_count="$(echo "$result" | grep -oP 'CT_COUNT=\K.*' || echo 'N/A')"
    ct_buckets="$(echo "$result" | grep -oP 'CT_BUCKETS=\K.*' || echo 'N/A')"
    ct_timeout="$(echo "$result" | grep -oP 'CT_TIMEOUT=\K.*' || echo 'N/A')"
    tcp_est="$(echo "$result" | grep -oP 'TCP_EST=\K.*' || echo 'N/A')"
    tcp_wait="$(echo "$result" | grep -oP 'TCP_WAIT=\K.*' || echo 'N/A')"

    local ct_pct="N/A"
    if [[ "${ct_count}" != "N/A" && "${ct_max}" != "N/A" && "${ct_max}" != "0" ]]; then
        ct_pct="$(awk "BEGIN{printf \"%.1f\", (${ct_count}/${ct_max})*100}")"
    fi

    report ""
    report "┌─────────────────────────────────────────────────────────────────┐"
    report "│  Conntrack / Соединения: $(printf '%-38s' "${label}")│"
    report "├─────────────────────────────────────────────────────────────────┤"
    report "│  $(printf '%-40s' "conntrack_max")$(printf '%-22s' "${ct_max}")│"
    report "│  $(printf '%-40s' "conntrack_count (текущий)")$(printf '%-22s' "${ct_count} (${ct_pct}%)")│"
    report "│  $(printf '%-40s' "conntrack hashsize (buckets)")$(printf '%-22s' "${ct_buckets}")│"
    report "│  $(printf '%-40s' "tcp_timeout_established (сек)")$(printf '%-22s' "${ct_timeout}")│"
    report "│  $(printf '%-40s' "TCP established")$(printf '%-22s' "${tcp_est}")│"
    report "│  $(printf '%-40s' "TCP time-wait")$(printf '%-22s' "${tcp_wait}")│"
    report "└─────────────────────────────────────────────────────────────────┘"
}

# ── Тест задержки туннеля под нагрузкой ──────────────────────────────────────
test_tunnel_latency() {
    local vps1_ip="$1" vps1_user="$2" vps1_key="$3" vps1_pass="$4"
    step "Тест задержки туннеля VPS1 → VPS2 под нагрузкой"

    log "Базовая задержка (без нагрузки)..."
    local baseline
    baseline="$(ssh_exec "$vps1_ip" "$vps1_user" "$vps1_key" "$vps1_pass" \
        "ping -c 20 -q 10.8.0.2 2>&1 | tail -1" 35 2>/dev/null || echo 'N/A')"
    local baseline_summary
    baseline_summary="$(echo "$baseline" | grep -oE '[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+' | head -1 || echo 'N/A')"

    log "Задержка под нагрузкой (параллельная загрузка)..."
    ssh_exec "$vps1_ip" "$vps1_user" "$vps1_key" "$vps1_pass" \
        "for i in 1 2 3 4; do curl -o /dev/null --max-time 20 'https://speed.cloudflare.com/__down?bytes=52428800' 2>/dev/null & done" 5 2>/dev/null || true
    sleep 2

    local loaded
    loaded="$(ssh_exec "$vps1_ip" "$vps1_user" "$vps1_key" "$vps1_pass" \
        "ping -c 20 -q 10.8.0.2 2>&1 | tail -1" 35 2>/dev/null || echo 'N/A')"
    local loaded_summary
    loaded_summary="$(echo "$loaded" | grep -oE '[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+' | head -1 || echo 'N/A')"

    ssh_exec "$vps1_ip" "$vps1_user" "$vps1_key" "$vps1_pass" \
        "pkill -f 'curl.*cloudflare' 2>/dev/null || true" 5 2>/dev/null || true

    local baseline_avg loaded_avg jitter_increase
    baseline_avg="$(echo "$baseline_summary" | awk -F/ '{print $2}' || echo 'N/A')"
    loaded_avg="$(echo "$loaded_summary" | awk -F/ '{print $2}' || echo 'N/A')"
    if [[ "${baseline_avg}" != "N/A" && "${loaded_avg}" != "N/A" ]]; then
        jitter_increase="$(awk "BEGIN{printf \"%.1f\", ${loaded_avg}-${baseline_avg}}")"
    else
        jitter_increase="N/A"
    fi

    report ""
    report "┌─────────────────────────────────────────────────────────────────┐"
    report "│  Задержка туннеля VPS1 → VPS2 (10.8.0.2)                       │"
    report "├─────────────────────────────────────────────────────────────────┤"
    report "│  $(printf '%-40s' "Без нагрузки (min/avg/max/jitter ms)")$(printf '%-22s' "${baseline_summary}")│"
    report "│  $(printf '%-40s' "Под нагрузкой (min/avg/max/jitter ms)")$(printf '%-22s' "${loaded_summary}")│"
    report "│  $(printf '%-40s' "Увеличение avg latency (ms)")$(printf '%-22s' "${jitter_increase}")│"
    report "└─────────────────────────────────────────────────────────────────┘"
}

# ── Тест WireGuard throughput ─────────────────────────────────────────────────
test_wireguard_throughput() {
    local label="$1" ip="$2" user="$3" key="$4" pass="$5"
    step "Тест WireGuard throughput: ${label}"

    local result
    result="$(ssh_exec "$ip" "$user" "$key" "$pass" '
awg_data=$(awg show all transfer 2>/dev/null || echo "none")
if [[ "$awg_data" != "none" ]]; then
    echo "$awg_data" | while read -r iface peer rx tx; do
        rx_mb=$(awk "BEGIN{printf \"%.2f\", ${rx:-0}/1048576}")
        tx_mb=$(awk "BEGIN{printf \"%.2f\", ${tx:-0}/1048576}")
        printf "PEER=%s RX_MB=%s TX_MB=%s\n" "$peer" "$rx_mb" "$tx_mb"
    done
else
    echo "NO_DATA"
fi
' 15 2>/dev/null || echo 'NO_DATA')"

    report ""
    report "┌─────────────────────────────────────────────────────────────────┐"
    report "│  WireGuard трафик: $(printf '%-43s' "${label}")│"
    report "├─────────────────────────────────────────────────────────────────┤"

    if [[ "${result}" == "NO_DATA" ]]; then
        report "│  $(printf '%-62s' "Нет данных о трафике")│"
    else
        while IFS= read -r line; do
            local peer rx tx
            peer="$(echo "$line" | grep -oP 'PEER=\K[^ ]+' || echo '?')"
            rx="$(echo "$line" | grep -oP 'RX_MB=\K[^ ]+' || echo '0')"
            tx="$(echo "$line" | grep -oP 'TX_MB=\K[^ ]+' || echo '0')"
            [[ -z "${peer}" || "${peer}" == "?" ]] && continue
            local short_peer="${peer:0:12}..."
            report "│  $(printf '%-20s' "${short_peer}") RX: $(printf '%-12s' "${rx} MB") TX: $(printf '%-12s' "${tx} MB")│"
        done <<< "${result}"
    fi

    report "└─────────────────────────────────────────────────────────────────┘"
}

# ── Полный отчёт по серверу ───────────────────────────────────────────────────
full_server_report() {
    local label="$1" ip="$2" user="$3" key="$4" pass="$5"

    step "Системные метрики: ${label}"
    log "Сбор системных метрик ${label}..."

    local metrics
    metrics="$(collect_system_metrics "$ip" "$user" "$key" "$pass")"

    local cpu_count cpu_load cpu_usage mem_total mem_used mem_available swap_used
    local disk_usage conntrack_count conntrack_max awg_peers uptime_sec

    cpu_count="$(echo "$metrics" | grep -oP 'CPU_COUNT=\K.*' || echo 'N/A')"
    cpu_load="$(echo "$metrics" | grep -oP 'CPU_LOAD=\K.*' || echo 'N/A')"
    cpu_usage="$(echo "$metrics" | grep -oP 'CPU_USAGE=\K.*' || echo 'N/A')"
    mem_total="$(echo "$metrics" | grep -oP 'MEM_TOTAL=\K.*' || echo 'N/A')"
    mem_used="$(echo "$metrics" | grep -oP 'MEM_USED=\K.*' || echo 'N/A')"
    mem_available="$(echo "$metrics" | grep -oP 'MEM_AVAILABLE=\K.*' || echo 'N/A')"
    swap_used="$(echo "$metrics" | grep -oP 'SWAP_USED=\K.*' || echo '0')"
    disk_usage="$(echo "$metrics" | grep -oP 'DISK_USAGE=\K.*' || echo 'N/A')"
    conntrack_count="$(echo "$metrics" | grep -oP 'CONNTRACK_COUNT=\K.*' || echo 'N/A')"
    conntrack_max="$(echo "$metrics" | grep -oP 'CONNTRACK_MAX=\K.*' || echo 'N/A')"
    awg_peers="$(echo "$metrics" | grep -oP 'AWG_PEERS=\K.*' || echo 'N/A')"
    uptime_sec="$(echo "$metrics" | grep -oP 'UPTIME=\K.*' || echo 'N/A')"

    local mem_pct="N/A"
    if [[ "${mem_used}" != "N/A" && "${mem_total}" != "N/A" && "${mem_total}" != "0" ]]; then
        mem_pct="$(awk "BEGIN{printf \"%.1f\", (${mem_used}/${mem_total})*100}")"
    fi

    local uptime_human="N/A"
    if [[ "${uptime_sec}" != "N/A" ]]; then
        local days hours mins
        days="$(awk "BEGIN{printf \"%d\", ${uptime_sec}/86400}")"
        hours="$(awk "BEGIN{printf \"%d\", (${uptime_sec}%86400)/3600}")"
        mins="$(awk "BEGIN{printf \"%d\", (${uptime_sec}%3600)/60}")"
        uptime_human="${days}д ${hours}ч ${mins}м"
    fi

    report ""
    report "╔═════════════════════════════════════════════════════════════════╗"
    report "║  $(printf '%-62s' "${label} (${ip})")║"
    report "╠═════════════════════════════════════════════════════════════════╣"
    report "║  $(printf '%-40s' "Uptime")$(printf '%-22s' "${uptime_human}")║"
    report "║  $(printf '%-40s' "CPU ядер")$(printf '%-22s' "${cpu_count}")║"
    report "║  $(printf '%-40s' "CPU load (1/5/15 мин)")$(printf '%-22s' "${cpu_load}")║"
    report "║  $(printf '%-40s' "CPU usage %")$(printf '%-22s' "${cpu_usage}")║"
    report "╠═════════════════════════════════════════════════════════════════╣"
    report "║  $(printf '%-40s' "RAM всего (MB)")$(printf '%-22s' "${mem_total}")║"
    report "║  $(printf '%-40s' "RAM использовано (MB)")$(printf '%-22s' "${mem_used} (${mem_pct}%)")║"
    report "║  $(printf '%-40s' "RAM доступно (MB)")$(printf '%-22s' "${mem_available}")║"
    report "║  $(printf '%-40s' "Swap использовано (MB)")$(printf '%-22s' "${swap_used}")║"
    report "╠═════════════════════════════════════════════════════════════════╣"
    report "║  $(printf '%-40s' "Диск использовано")$(printf '%-22s' "${disk_usage}")║"
    report "║  $(printf '%-40s' "Conntrack (текущий/макс)")$(printf '%-22s' "${conntrack_count}/${conntrack_max}")║"
    report "║  $(printf '%-40s' "WireGuard пиров")$(printf '%-22s' "${awg_peers}")║"
    report "╚═════════════════════════════════════════════════════════════════╝"
}

# ── Основной поток ────────────────────────────────────────────────────────────
report "╔══════════════════════════════════════════════════════════════════════╗"
report "║           НАГРУЗОЧНОЕ ТЕСТИРОВАНИЕ VPN-СЕРВЕРОВ                     ║"
report "║  $(printf '%-68s' "${TIMESTAMP}")║"
report "║  $(printf '%-68s' "Макс. соединений: ${MAX_CONNECTIONS}, шаг: ${STEP}, длительность: ${DURATION}с")║"
report "╚══════════════════════════════════════════════════════════════════════╝"

if [[ "${DO_VPS1}" == "true" ]]; then
    install_load_tools "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS" "VPS1"
fi
if [[ "${DO_VPS2}" == "true" ]]; then
    install_load_tools "$VPS2_IP" "$VPS2_USER" "$VPS2_KEY" "${VPS2_PASS:-}" "VPS2"
fi

if [[ "${DO_VPS1}" == "true" ]]; then
    full_server_report "VPS1" "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS"
fi
if [[ "${DO_VPS2}" == "true" ]]; then
    full_server_report "VPS2" "$VPS2_IP" "$VPS2_USER" "$VPS2_KEY" "${VPS2_PASS:-}"
fi

if [[ "${CONNECTIONS_ONLY}" != "true" ]]; then
    if [[ "${DO_VPS1}" == "true" ]]; then
        test_bandwidth "VPS1" "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS"
    fi
    if [[ "${DO_VPS2}" == "true" ]]; then
        test_bandwidth "VPS2" "$VPS2_IP" "$VPS2_USER" "$VPS2_KEY" "${VPS2_PASS:-}"
    fi
fi

if [[ "${BANDWIDTH_ONLY}" != "true" ]]; then
    if [[ "${DO_VPS1}" == "true" ]]; then
        test_connections "VPS1" "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS"
        test_conntrack   "VPS1" "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS"
    fi
    if [[ "${DO_VPS2}" == "true" ]]; then
        test_connections "VPS2" "$VPS2_IP" "$VPS2_USER" "$VPS2_KEY" "${VPS2_PASS:-}"
        test_conntrack   "VPS2" "$VPS2_IP" "$VPS2_USER" "$VPS2_KEY" "${VPS2_PASS:-}"
    fi
fi

if [[ "${DO_VPS1}" == "true" && "${DO_VPS2}" == "true" ]]; then
    test_tunnel_latency "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS"
fi

if [[ "${DO_VPS1}" == "true" ]]; then
    test_wireguard_throughput "VPS1" "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS"
fi
if [[ "${DO_VPS2}" == "true" ]]; then
    test_wireguard_throughput "VPS2" "$VPS2_IP" "$VPS2_USER" "$VPS2_KEY" "${VPS2_PASS:-}"
fi

step "Сбор метрик ПОСЛЕ нагрузки"
if [[ "${DO_VPS1}" == "true" ]]; then
    full_server_report "VPS1 (после нагрузки)" "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS"
fi
if [[ "${DO_VPS2}" == "true" ]]; then
    full_server_report "VPS2 (после нагрузки)" "$VPS2_IP" "$VPS2_USER" "$VPS2_KEY" "${VPS2_PASS:-}"
fi

report ""
report "═══════════════════════════════════════════════════════════════════════"
report "  Нагрузочное тестирование завершено: $(date '+%Y-%m-%d %H:%M:%S')"
report "═══════════════════════════════════════════════════════════════════════"

echo ""
echo "${REPORT}"

if [[ -n "${OUTPUT_FILE}" ]]; then
    echo "${REPORT}" > "${OUTPUT_FILE}"
    ok "Отчёт сохранён в ${OUTPUT_FILE}"
fi

ok "Нагрузочное тестирование завершено"
