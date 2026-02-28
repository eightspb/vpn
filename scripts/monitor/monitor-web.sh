#!/bin/bash
# =============================================================================
# VPN Web Dashboard monitor
# Пишет vpn-output/data.json, запускает HTTP-сервер на порту 8080
#
# Использование:
#   bash monitor-web.sh
#   Открыть: http://localhost:8080/dashboard.html
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
cd "$SCRIPT_DIR"

VPS1_IP=""
VPS1_USER=""
VPS1_KEY=""
VPS1_PASS=""

VPS2_IP=""
VPS2_USER=""
VPS2_KEY=""
VPS2_PASS=""

VPS1_INTERNAL="10.9.0.1"
VPS2_INTERNAL=""

VPS2_TUN_IP="10.8.0.2"
INTERVAL=2
HTTP_PORT=8080
SSH_TIMEOUT=8
JSON_FILE="./vpn-output/data.json"
LOG_FILE="./vpn-output/monitor.log"
LOG_LEVEL="INFO"
PYTHON_CMD=()

TEMP_KEY_FILES=()
LAST_ERR_VPS1=""
LAST_ERR_VPS2=""
HTTP_PID=""

VPS1_PREV_RX=0
VPS1_PREV_TX=0
VPS2_PREV_RX=0
VPS2_PREV_TX=0
PREV_TS=0

LOG_MAX_BYTES=2097152  # 2 MB

rotate_log_if_needed() {
    [[ ! -f "$LOG_FILE" ]] && return
    local sz
    sz="$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)"
    if [[ "$sz" -ge "$LOG_MAX_BYTES" ]]; then
        mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
        : > "$LOG_FILE"
    fi
}

log_line() {
    local level="$1" msg="$2" ts
    [[ "$level" == "DEBUG" && "$LOG_LEVEL" != "DEBUG" ]] && return
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "[%s] [%s] %s\n" "$ts" "$level" "$msg" >> "$LOG_FILE"
    rotate_log_if_needed
}

set_last_error() {
    if [[ "$1" == "VPS1" ]]; then LAST_ERR_VPS1="$2"; else LAST_ERR_VPS2="$2"; fi
}

cleanup_all() {
    [[ -n "$HTTP_PID" ]] && kill "$HTTP_PID" 2>/dev/null || true
    cleanup_temp_keys
}

trap cleanup_all EXIT

ssh_exec() {
    local server="$1" ip="$2" user="$3" key="$4" pass="$5" cmd="$6"
    # AddressFamily=inet: skip IPv6 lookup (avoids DNS hang when VPN is active)
    # ServerAliveInterval/CountMax: detect dead connections quickly
    local ssh_opts=(-F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    -o BatchMode=no -o ConnectTimeout="$SSH_TIMEOUT" \
                    -o AddressFamily=inet \
                    -o ServerAliveInterval=3 -o ServerAliveCountMax=2)
    local stderr_file rc out err
    # Hard timeout = SSH_TIMEOUT + 5s buffer for DNS + connection setup
    local hard_timeout=$(( SSH_TIMEOUT + 5 ))
    stderr_file="$(mktemp)"
    ip="$(clean_value "$ip")"; user="$(clean_value "$user")"
    key="$(expand_tilde "$key")"; pass="$(clean_value "$pass")"
    local ssh_bin
    if command -v ssh >/dev/null 2>&1; then
        ssh_bin="ssh"
    elif command -v ssh.exe >/dev/null 2>&1; then
        ssh_bin="ssh.exe"
    else
        set_last_error "$server" "ssh not found in PATH"
        rm -f "$stderr_file"; return 1
    fi
    if [[ -n "$key" ]]; then
        out="$(timeout "$hard_timeout" "$ssh_bin" "${ssh_opts[@]}" -i "$key" "${user}@${ip}" "$cmd" 2>"$stderr_file")"
        rc=$?
    elif [[ -n "$pass" ]]; then
        out="$(timeout "$hard_timeout" sshpass -p "$pass" "$ssh_bin" "${ssh_opts[@]}" "${user}@${ip}" "$cmd" 2>"$stderr_file")"
        rc=$?
    else
        out="$(timeout "$hard_timeout" "$ssh_bin" "${ssh_opts[@]}" "${user}@${ip}" "$cmd" 2>"$stderr_file")"
        rc=$?
    fi
    err="$(tr '\n' '|' < "$stderr_file")"; rm -f "$stderr_file"
    if [[ $rc -ne 0 ]]; then
        [[ -z "$err" ]] && err="no stderr"
        set_last_error "$server" "rc=$rc ${err}"
        log_line "ERROR" "$server ssh failed rc=$rc target=${user}@${ip} err=${err}"
        return "$rc"
    fi
    set_last_error "$server" ""
    [[ -n "$err" ]] && log_line "WARN" "$server ssh stderr: $err"
    log_line "DEBUG" "$server ssh ok bytes=$(printf "%s" "$out" | wc -c | tr -d ' ')"
    printf "%s" "$out"
}

# ---------------------------------------------------------------------------
# Remote data collection
# ---------------------------------------------------------------------------

collect_vps1() {
    local remote_cmd
    remote_cmd=$(cat <<EOF
HOST=\$(hostname 2>/dev/null || echo n/a)
LOAD=\$(awk '{print \$1","\$2","\$3}' /proc/loadavg 2>/dev/null || echo 0,0,0)
MEM=\$(free -m 2>/dev/null | awk '/Mem:/ {print \$3"/"\$2"MB"}')
DISK=\$(df -h / 2>/dev/null | awk 'NR==2 {print \$3"/"\$2",used="\$5}')
MAIN_IF=\$(ip route 2>/dev/null | awk '/default/ {print \$5; exit}')
RX=\$(awk -v i="\$MAIN_IF" '{gsub(/^[[:space:]]+/,""); split(\$0,a,":"); if(a[1]==i){split(a[2],b," "); print b[1]}}' /proc/net/dev 2>/dev/null | head -1)
TX=\$(awk -v i="\$MAIN_IF" '{gsub(/^[[:space:]]+/,""); split(\$0,a,":"); if(a[1]==i){split(a[2],b," "); print b[9]}}' /proc/net/dev 2>/dev/null | head -1)
TCP_EST=\$(ss -Htn state established 2>/dev/null | wc -l | tr -d ' ')
UDP_CONN=\$(ss -Hun 2>/dev/null | wc -l | tr -d ' ')
AWG0=\$(sudo systemctl is-active awg-quick@awg0 2>/dev/null || echo unknown)
AWG1=\$(sudo systemctl is-active awg-quick@awg1 2>/dev/null || echo unknown)
HS0=\$(sudo awg show awg0 latest-handshakes 2>/dev/null | awk 'NR==1 {if (\$2>0) print systime()-\$2; else print -1}')
[[ -z "\$HS0" ]] && HS0=-1
HS1=\$(sudo awg show awg1 latest-handshakes 2>/dev/null | awk 'NR==1 {if (\$2>0) print systime()-\$2; else print -1}')
[[ -z "\$HS1" ]] && HS1=-1
A1_ACTIVE=\$(sudo awg show awg1 latest-handshakes 2>/dev/null | awk '\$2>0 && (systime()-\$2)<=180 {c++} END {print c+0}')
[[ -z "\$A1_ACTIVE" ]] && A1_ACTIVE=0
P0=\$(sudo awg show awg0 peers 2>/dev/null | wc -w | tr -d ' ')
P1=\$(sudo awg show awg1 peers 2>/dev/null | wc -w | tr -d ' ')
if ping -c 1 -W 1 -I awg0 "${VPS2_TUN_IP}" >/dev/null 2>&1; then TUN_PING=ok; else TUN_PING=fail; fi
CPUS=\$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
UPTIME_S=\$(awk '{print int(\$1)}' /proc/uptime 2>/dev/null || echo 0)
CPU_MHZ=\$(awk '/cpu MHz/{sum+=\$4; n++} END{if(n>0) printf "%.0f", sum/n; else print 0}' /proc/cpuinfo 2>/dev/null || echo 0)
MEM_FREE=\$(free -m 2>/dev/null | awk '/Mem:/ {print \$4}')
SWAP_RAW=\$(free -m 2>/dev/null | awk '/Swap:/ {print \$3"/"\$2"MB"}')
echo "HOST=\$HOST"
echo "LOAD=\$LOAD"
echo "MEM=\$MEM"
echo "DISK=\$DISK"
echo "MAIN_IF=\${MAIN_IF:-n/a}"
echo "RX=\${RX:-0}"
echo "TX=\${TX:-0}"
echo "TCP_EST=\${TCP_EST:-0}"
echo "UDP_CONN=\${UDP_CONN:-0}"
echo "AWG0=\$AWG0"
echo "AWG1=\$AWG1"
echo "HS0=\$HS0"
echo "HS1=\$HS1"
echo "A1_ACTIVE=\$A1_ACTIVE"
echo "P0=\$P0"
echo "P1=\$P1"
echo "TUN_PING=\$TUN_PING"
echo "CPUS=\${CPUS:-1}"
echo "UPTIME_S=\${UPTIME_S:-0}"
echo "CPU_MHZ=\${CPU_MHZ:-0}"
echo "MEM_FREE=\${MEM_FREE:-0}"
echo "SWAP=\${SWAP_RAW:-0/0MB}"
echo "RX_TOTAL=\${RX:-0}"
echo "TX_TOTAL=\${TX:-0}"
MEM_TOTAL_KB=\$(awk '/MemTotal/ {print \$2}' /proc/meminfo 2>/dev/null || echo 0)
MEM_AVAIL_KB=\$(awk '/MemAvailable/ {print \$2}' /proc/meminfo 2>/dev/null || echo 0)
MEM_BUFFERS_KB=\$(awk '/Buffers/ {print \$2}' /proc/meminfo 2>/dev/null || echo 0)
MEM_CACHED_KB=\$(awk '/^Cached/ {print \$2}' /proc/meminfo 2>/dev/null || echo 0)
echo "MEM_AVAIL=\$(( MEM_AVAIL_KB / 1024 ))"
echo "MEM_BUFFERS=\$(( MEM_BUFFERS_KB / 1024 ))"
echo "MEM_CACHED=\$(( MEM_CACHED_KB / 1024 ))"
DISK_INODES=\$(df -i / 2>/dev/null | awk 'NR==2 {print \$5}')
echo "DISK_INODES=\${DISK_INODES:-0%}"
PROC_COUNT=\$(ps aux 2>/dev/null | wc -l | tr -d ' ')
echo "PROC_COUNT=\${PROC_COUNT:-0}"
OPEN_FILES=\$(cat /proc/sys/fs/file-nr 2>/dev/null | awk '{print \$1}')
echo "OPEN_FILES=\${OPEN_FILES:-0}"
EOF
)
    ssh_exec "VPS1" "$CURRENT_VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS" "$remote_cmd"
}

collect_vps2() {
    local remote_cmd
    remote_cmd=$(cat <<'EOF'
HOST=$(hostname 2>/dev/null || echo n/a)
LOAD=$(awk '{print $1","$2","$3}' /proc/loadavg 2>/dev/null || echo 0,0,0)
MEM=$(free -m 2>/dev/null | awk '/Mem:/ {print $3"/"$2"MB"}')
DISK=$(df -h / 2>/dev/null | awk 'NR==2 {print $3"/"$2",used="$5}')
MAIN_IF=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
RX=$(awk -v i="$MAIN_IF" '{gsub(/^[[:space:]]+/,""); split($0,a,":"); if(a[1]==i){split(a[2],b," "); print b[1]}}' /proc/net/dev 2>/dev/null | head -1)
TX=$(awk -v i="$MAIN_IF" '{gsub(/^[[:space:]]+/,""); split($0,a,":"); if(a[1]==i){split(a[2],b," "); print b[9]}}' /proc/net/dev 2>/dev/null | head -1)
TCP_EST=$(ss -Htn state established 2>/dev/null | wc -l | tr -d ' ')
UDP_CONN=$(ss -Hun 2>/dev/null | wc -l | tr -d ' ')
AWG0=$(sudo systemctl is-active awg-quick@awg0 2>/dev/null || echo unknown)
HS0=$(sudo awg show awg0 latest-handshakes 2>/dev/null | awk 'NR==1 {if ($2>0) print systime()-$2; else print -1}')
[[ -z "$HS0" ]] && HS0=-1
P0=$(sudo awg show awg0 peers 2>/dev/null | wc -w | tr -d ' ')
if systemctl is-active AdGuardHome >/dev/null 2>&1; then
  AGH=active
elif systemctl is-active adguardhome >/dev/null 2>&1; then
  AGH=active
else
  AGH=inactive
fi
if ss -lunt 2>/dev/null | grep -qE ':53[[:space:]]'; then DNS53=up; else DNS53=down; fi
if ss -lnt 2>/dev/null | grep -qE ':3000[[:space:]]'; then WEB3000=up; else WEB3000=down; fi
if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then WAN_PING=ok; else WAN_PING=fail; fi
CPUS=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
UPTIME_S=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
CPU_MHZ=$(awk '/cpu MHz/{sum+=$4; n++} END{if(n>0) printf "%.0f", sum/n; else print 0}' /proc/cpuinfo 2>/dev/null || echo 0)
MEM_FREE=$(free -m 2>/dev/null | awk '/Mem:/ {print $4}')
SWAP_RAW=$(free -m 2>/dev/null | awk '/Swap:/ {print $3"/"$2"MB"}')
echo "HOST=$HOST"
echo "LOAD=$LOAD"
echo "MEM=$MEM"
echo "DISK=$DISK"
echo "MAIN_IF=${MAIN_IF:-n/a}"
echo "RX=${RX:-0}"
echo "TX=${TX:-0}"
echo "TCP_EST=${TCP_EST:-0}"
echo "UDP_CONN=${UDP_CONN:-0}"
echo "AWG0=$AWG0"
echo "HS0=$HS0"
echo "P0=$P0"
echo "AGH=$AGH"
echo "DNS53=$DNS53"
echo "WEB3000=$WEB3000"
echo "WAN_PING=$WAN_PING"
echo "CPUS=${CPUS:-1}"
echo "UPTIME_S=${UPTIME_S:-0}"
echo "CPU_MHZ=${CPU_MHZ:-0}"
echo "MEM_FREE=${MEM_FREE:-0}"
echo "SWAP=${SWAP_RAW:-0/0MB}"
echo "RX_TOTAL=${RX:-0}"
echo "TX_TOTAL=${TX:-0}"
MEM_TOTAL_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
MEM_AVAIL_KB=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
MEM_BUFFERS_KB=$(awk '/Buffers/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
MEM_CACHED_KB=$(awk '/^Cached/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
echo "MEM_AVAIL=$(( MEM_AVAIL_KB / 1024 ))"
echo "MEM_BUFFERS=$(( MEM_BUFFERS_KB / 1024 ))"
echo "MEM_CACHED=$(( MEM_CACHED_KB / 1024 ))"
DISK_INODES=$(df -i / 2>/dev/null | awk 'NR==2 {print $5}')
echo "DISK_INODES=${DISK_INODES:-0%}"
PROC_COUNT=$(ps aux 2>/dev/null | wc -l | tr -d ' ')
echo "PROC_COUNT=${PROC_COUNT:-0}"
OPEN_FILES=$(cat /proc/sys/fs/file-nr 2>/dev/null | awk '{print $1}')
echo "OPEN_FILES=${OPEN_FILES:-0}"
EOF
)
    ssh_exec "VPS2" "$CURRENT_VPS2_IP" "$VPS2_USER" "$VPS2_KEY" "$VPS2_PASS" "$remote_cmd"
}

# ---------------------------------------------------------------------------
# Parse KEY=VALUE output from remote (splits on first = only)
# ---------------------------------------------------------------------------

parse_kv() {
    local data="$1" key="$2"
    printf "%s\n" "$data" | awk -v k="$key" \
        'BEGIN{n=length(k)} substr($0,1,n+1)==k"=" {print substr($0,n+2); exit}'
}

# ---------------------------------------------------------------------------
# Write data.json atomically via Python runtime
# ---------------------------------------------------------------------------

write_json() {
    local vps1_data="$1" vps2_data="$2" now
    now="$(date +%s)"
    local elapsed=$((now - PREV_TS))
    [[ $elapsed -le 0 ]] && elapsed=1

    # --- VPS1 ---
    local V1_ONLINE="false" V1_HOST="" V1_LOAD1="0" V1_LOAD5="0" V1_LOAD15="0"
    local V1_MEM_USED="0" V1_MEM_TOTAL="0" V1_MEM_FREE="0"
    local V1_DISK_USED="" V1_DISK_TOTAL="" V1_DISK_PCT="0"
    local V1_NET_IF="" V1_RX="0" V1_TX="0"
    local V1_TCP_EST="0" V1_UDP_CONN="0"
    local V1_AWG0="" V1_AWG1="" V1_HS0="-1" V1_HS1="-1" V1_A1_ACTIVE="0" V1_P0="0" V1_P1="0" V1_TUN_PING=""
    local V1_RX_SPEED="0" V1_TX_SPEED="0" V1_ERROR=""
    local V1_CPUS="1" V1_UPTIME_S="0" V1_CPU_MHZ="0" V1_SWAP=""
    local V1_RX_TOTAL="0" V1_TX_TOTAL="0"
    local V1_MEM_AVAIL="0" V1_MEM_BUFFERS="0" V1_MEM_CACHED="0"
    local V1_DISK_INODES="0%" V1_PROC_COUNT="0" V1_OPEN_FILES="0"

    if [[ -n "$vps1_data" ]]; then
        V1_ONLINE="true"
        V1_HOST="$(parse_kv "$vps1_data" HOST)"
        local load_raw; load_raw="$(parse_kv "$vps1_data" LOAD)"
        V1_LOAD1="${load_raw%%,*}"
        V1_LOAD5="${load_raw#*,}"; V1_LOAD5="${V1_LOAD5%,*}"
        V1_LOAD15="${load_raw##*,}"
        local mem_raw; mem_raw="$(parse_kv "$vps1_data" MEM)"
        V1_MEM_USED="${mem_raw%%/*}"
        V1_MEM_TOTAL="${mem_raw#*/}"; V1_MEM_TOTAL="${V1_MEM_TOTAL%%[^0-9]*}"
        local disk_raw; disk_raw="$(parse_kv "$vps1_data" DISK)"
        V1_DISK_USED="${disk_raw%%/*}"
        V1_DISK_TOTAL="${disk_raw#*/}"; V1_DISK_TOTAL="${V1_DISK_TOTAL%%,*}"
        V1_DISK_PCT="$(printf '%s' "$disk_raw" | awk -F'used=' '{gsub(/%/,"",$2); print int($2+0)}')"
        V1_NET_IF="$(parse_kv "$vps1_data" MAIN_IF)"
        V1_RX="$(parse_kv "$vps1_data" RX)"
        V1_TX="$(parse_kv "$vps1_data" TX)"
        V1_TCP_EST="$(parse_kv "$vps1_data" TCP_EST)"
        V1_UDP_CONN="$(parse_kv "$vps1_data" UDP_CONN)"
        V1_AWG0="$(parse_kv "$vps1_data" AWG0)"
        V1_AWG1="$(parse_kv "$vps1_data" AWG1)"
        V1_HS0="$(parse_kv "$vps1_data" HS0)"; V1_HS0="${V1_HS0:--1}"
        V1_HS1="$(parse_kv "$vps1_data" HS1)"; V1_HS1="${V1_HS1:--1}"
        V1_A1_ACTIVE="$(parse_kv "$vps1_data" A1_ACTIVE)"; V1_A1_ACTIVE="${V1_A1_ACTIVE:-0}"
        V1_P0="$(parse_kv "$vps1_data" P0)"
        V1_P1="$(parse_kv "$vps1_data" P1)"
        V1_TUN_PING="$(parse_kv "$vps1_data" TUN_PING)"
        V1_CPUS="$(parse_kv "$vps1_data" CPUS)"; V1_CPUS="${V1_CPUS:-1}"
        V1_UPTIME_S="$(parse_kv "$vps1_data" UPTIME_S)"; V1_UPTIME_S="${V1_UPTIME_S:-0}"
        V1_CPU_MHZ="$(parse_kv "$vps1_data" CPU_MHZ)"; V1_CPU_MHZ="${V1_CPU_MHZ:-0}"
        V1_MEM_FREE="$(parse_kv "$vps1_data" MEM_FREE)"; V1_MEM_FREE="${V1_MEM_FREE:-0}"
        V1_SWAP="$(parse_kv "$vps1_data" SWAP)"; V1_SWAP="${V1_SWAP:-0/0MB}"
        V1_RX_TOTAL="$(parse_kv "$vps1_data" RX_TOTAL)"; V1_RX_TOTAL="${V1_RX_TOTAL:-0}"
        V1_TX_TOTAL="$(parse_kv "$vps1_data" TX_TOTAL)"; V1_TX_TOTAL="${V1_TX_TOTAL:-0}"
        V1_MEM_AVAIL="$(parse_kv "$vps1_data" MEM_AVAIL)"; V1_MEM_AVAIL="${V1_MEM_AVAIL:-0}"
        V1_MEM_BUFFERS="$(parse_kv "$vps1_data" MEM_BUFFERS)"; V1_MEM_BUFFERS="${V1_MEM_BUFFERS:-0}"
        V1_MEM_CACHED="$(parse_kv "$vps1_data" MEM_CACHED)"; V1_MEM_CACHED="${V1_MEM_CACHED:-0}"
        V1_DISK_INODES="$(parse_kv "$vps1_data" DISK_INODES)"; V1_DISK_INODES="${V1_DISK_INODES:-0%}"
        V1_PROC_COUNT="$(parse_kv "$vps1_data" PROC_COUNT)"; V1_PROC_COUNT="${V1_PROC_COUNT:-0}"
        V1_OPEN_FILES="$(parse_kv "$vps1_data" OPEN_FILES)"; V1_OPEN_FILES="${V1_OPEN_FILES:-0}"
        if [[ "$VPS1_PREV_RX" -gt 0 && "${V1_RX:-0}" =~ ^[0-9]+$ ]]; then
            local d_rx1 d_tx1
            d_rx1=$(( ${V1_RX:-0} - VPS1_PREV_RX )); [[ $d_rx1 -lt 0 ]] && d_rx1=0
            d_tx1=$(( ${V1_TX:-0} - VPS1_PREV_TX )); [[ $d_tx1 -lt 0 ]] && d_tx1=0
            V1_RX_SPEED=$(( d_rx1 / elapsed ))
            V1_TX_SPEED=$(( d_tx1 / elapsed ))
        fi
        VPS1_PREV_RX="${V1_RX:-0}"; VPS1_PREV_TX="${V1_TX:-0}"
        : # connection details intentionally not collected
    else
        V1_ERROR="${LAST_ERR_VPS1:-SSH connection failed}"
        VPS1_PREV_RX=0; VPS1_PREV_TX=0
    fi

    # --- VPS2 ---
    local V2_ONLINE="false" V2_HOST="" V2_LOAD1="0" V2_LOAD5="0" V2_LOAD15="0"
    local V2_MEM_USED="0" V2_MEM_TOTAL="0" V2_MEM_FREE="0"
    local V2_DISK_USED="" V2_DISK_TOTAL="" V2_DISK_PCT="0"
    local V2_NET_IF="" V2_RX="0" V2_TX="0"
    local V2_TCP_EST="0" V2_UDP_CONN="0"
    local V2_AWG0="" V2_HS0="-1" V2_P0="0"
    local V2_AGH="" V2_DNS53="" V2_WEB3000="" V2_WAN_PING=""
    local V2_RX_SPEED="0" V2_TX_SPEED="0" V2_ERROR=""
    local V2_CPUS="1" V2_UPTIME_S="0" V2_CPU_MHZ="0" V2_SWAP=""
    local V2_RX_TOTAL="0" V2_TX_TOTAL="0"
    local V2_MEM_AVAIL="0" V2_MEM_BUFFERS="0" V2_MEM_CACHED="0"
    local V2_DISK_INODES="0%" V2_PROC_COUNT="0" V2_OPEN_FILES="0"

    if [[ -n "$vps2_data" ]]; then
        V2_ONLINE="true"
        V2_HOST="$(parse_kv "$vps2_data" HOST)"
        local load2_raw; load2_raw="$(parse_kv "$vps2_data" LOAD)"
        V2_LOAD1="${load2_raw%%,*}"
        V2_LOAD5="${load2_raw#*,}"; V2_LOAD5="${V2_LOAD5%,*}"
        V2_LOAD15="${load2_raw##*,}"
        local mem2_raw; mem2_raw="$(parse_kv "$vps2_data" MEM)"
        V2_MEM_USED="${mem2_raw%%/*}"
        V2_MEM_TOTAL="${mem2_raw#*/}"; V2_MEM_TOTAL="${V2_MEM_TOTAL%%[^0-9]*}"
        local disk2_raw; disk2_raw="$(parse_kv "$vps2_data" DISK)"
        V2_DISK_USED="${disk2_raw%%/*}"
        V2_DISK_TOTAL="${disk2_raw#*/}"; V2_DISK_TOTAL="${V2_DISK_TOTAL%%,*}"
        V2_DISK_PCT="$(printf '%s' "$disk2_raw" | awk -F'used=' '{gsub(/%/,"",$2); print int($2+0)}')"
        V2_NET_IF="$(parse_kv "$vps2_data" MAIN_IF)"
        V2_RX="$(parse_kv "$vps2_data" RX)"
        V2_TX="$(parse_kv "$vps2_data" TX)"
        V2_TCP_EST="$(parse_kv "$vps2_data" TCP_EST)"
        V2_UDP_CONN="$(parse_kv "$vps2_data" UDP_CONN)"
        V2_AWG0="$(parse_kv "$vps2_data" AWG0)"
        V2_HS0="$(parse_kv "$vps2_data" HS0)"; V2_HS0="${V2_HS0:--1}"
        V2_P0="$(parse_kv "$vps2_data" P0)"
        V2_AGH="$(parse_kv "$vps2_data" AGH)"
        V2_DNS53="$(parse_kv "$vps2_data" DNS53)"
        V2_WEB3000="$(parse_kv "$vps2_data" WEB3000)"
        V2_WAN_PING="$(parse_kv "$vps2_data" WAN_PING)"
        V2_CPUS="$(parse_kv "$vps2_data" CPUS)"; V2_CPUS="${V2_CPUS:-1}"
        V2_UPTIME_S="$(parse_kv "$vps2_data" UPTIME_S)"; V2_UPTIME_S="${V2_UPTIME_S:-0}"
        V2_CPU_MHZ="$(parse_kv "$vps2_data" CPU_MHZ)"; V2_CPU_MHZ="${V2_CPU_MHZ:-0}"
        V2_MEM_FREE="$(parse_kv "$vps2_data" MEM_FREE)"; V2_MEM_FREE="${V2_MEM_FREE:-0}"
        V2_SWAP="$(parse_kv "$vps2_data" SWAP)"; V2_SWAP="${V2_SWAP:-0/0MB}"
        V2_RX_TOTAL="$(parse_kv "$vps2_data" RX_TOTAL)"; V2_RX_TOTAL="${V2_RX_TOTAL:-0}"
        V2_TX_TOTAL="$(parse_kv "$vps2_data" TX_TOTAL)"; V2_TX_TOTAL="${V2_TX_TOTAL:-0}"
        V2_MEM_AVAIL="$(parse_kv "$vps2_data" MEM_AVAIL)"; V2_MEM_AVAIL="${V2_MEM_AVAIL:-0}"
        V2_MEM_BUFFERS="$(parse_kv "$vps2_data" MEM_BUFFERS)"; V2_MEM_BUFFERS="${V2_MEM_BUFFERS:-0}"
        V2_MEM_CACHED="$(parse_kv "$vps2_data" MEM_CACHED)"; V2_MEM_CACHED="${V2_MEM_CACHED:-0}"
        V2_DISK_INODES="$(parse_kv "$vps2_data" DISK_INODES)"; V2_DISK_INODES="${V2_DISK_INODES:-0%}"
        V2_PROC_COUNT="$(parse_kv "$vps2_data" PROC_COUNT)"; V2_PROC_COUNT="${V2_PROC_COUNT:-0}"
        V2_OPEN_FILES="$(parse_kv "$vps2_data" OPEN_FILES)"; V2_OPEN_FILES="${V2_OPEN_FILES:-0}"
        if [[ "$VPS2_PREV_RX" -gt 0 && "${V2_RX:-0}" =~ ^[0-9]+$ ]]; then
            local d_rx2 d_tx2
            d_rx2=$(( ${V2_RX:-0} - VPS2_PREV_RX )); [[ $d_rx2 -lt 0 ]] && d_rx2=0
            d_tx2=$(( ${V2_TX:-0} - VPS2_PREV_TX )); [[ $d_tx2 -lt 0 ]] && d_tx2=0
            V2_RX_SPEED=$(( d_rx2 / elapsed ))
            V2_TX_SPEED=$(( d_tx2 / elapsed ))
        fi
        VPS2_PREV_RX="${V2_RX:-0}"; VPS2_PREV_TX="${V2_TX:-0}"
        : # connection details intentionally not collected
    else
        V2_ERROR="${LAST_ERR_VPS2:-SSH connection failed}"
        VPS2_PREV_RX=0; VPS2_PREV_TX=0
    fi

    PREV_TS="$now"

    local tmp_json
    tmp_json="$(mktemp "${JSON_FILE}.XXXXXX")" || { log_line "ERROR" "mktemp failed"; return 1; }

    export \
        J_TS="$now" \
        J_V1_ONLINE="$V1_ONLINE" J_V1_IP="$VPS1_IP" J_V1_HOST="${V1_HOST:-}" \
        J_V1_LOAD1="${V1_LOAD1:-0}" J_V1_LOAD5="${V1_LOAD5:-0}" J_V1_LOAD15="${V1_LOAD15:-0}" \
        J_V1_MEM_USED="${V1_MEM_USED:-0}" J_V1_MEM_TOTAL="${V1_MEM_TOTAL:-0}" J_V1_MEM_FREE="${V1_MEM_FREE:-0}" \
        J_V1_DISK_USED="${V1_DISK_USED:-}" J_V1_DISK_TOTAL="${V1_DISK_TOTAL:-}" J_V1_DISK_PCT="${V1_DISK_PCT:-0}" \
        J_V1_NET_IF="${V1_NET_IF:-}" J_V1_RX_SPEED="$V1_RX_SPEED" J_V1_TX_SPEED="$V1_TX_SPEED" \
        J_V1_TCP_EST="${V1_TCP_EST:-0}" J_V1_UDP_CONN="${V1_UDP_CONN:-0}" \
        J_V1_AWG0="${V1_AWG0:-}" J_V1_AWG1="${V1_AWG1:-}" J_V1_HS0="${V1_HS0:--1}" J_V1_HS1="${V1_HS1:--1}" J_V1_A1_ACTIVE="${V1_A1_ACTIVE:-0}" \
        J_V1_P0="${V1_P0:-0}" J_V1_P1="${V1_P1:-0}" J_V1_TUN_PING="${V1_TUN_PING:-}" \
        J_V1_CPUS="${V1_CPUS:-1}" J_V1_UPTIME_S="${V1_UPTIME_S:-0}" \
        J_V1_CPU_MHZ="${V1_CPU_MHZ:-0}" J_V1_SWAP="${V1_SWAP:-0/0MB}" \
        J_V1_RX_TOTAL="${V1_RX_TOTAL:-0}" J_V1_TX_TOTAL="${V1_TX_TOTAL:-0}" \
        J_V1_MEM_AVAIL="${V1_MEM_AVAIL:-0}" J_V1_MEM_BUFFERS="${V1_MEM_BUFFERS:-0}" J_V1_MEM_CACHED="${V1_MEM_CACHED:-0}" \
        J_V1_DISK_INODES="${V1_DISK_INODES:-0%}" J_V1_PROC_COUNT="${V1_PROC_COUNT:-0}" J_V1_OPEN_FILES="${V1_OPEN_FILES:-0}" \
        J_V1_ERROR="${V1_ERROR:-}" \
        J_V2_ONLINE="$V2_ONLINE" J_V2_IP="$VPS2_IP" J_V2_HOST="${V2_HOST:-}" \
        J_V2_LOAD1="${V2_LOAD1:-0}" J_V2_LOAD5="${V2_LOAD5:-0}" J_V2_LOAD15="${V2_LOAD15:-0}" \
        J_V2_MEM_USED="${V2_MEM_USED:-0}" J_V2_MEM_TOTAL="${V2_MEM_TOTAL:-0}" J_V2_MEM_FREE="${V2_MEM_FREE:-0}" \
        J_V2_DISK_USED="${V2_DISK_USED:-}" J_V2_DISK_TOTAL="${V2_DISK_TOTAL:-}" J_V2_DISK_PCT="${V2_DISK_PCT:-0}" \
        J_V2_NET_IF="${V2_NET_IF:-}" J_V2_RX_SPEED="$V2_RX_SPEED" J_V2_TX_SPEED="$V2_TX_SPEED" \
        J_V2_TCP_EST="${V2_TCP_EST:-0}" J_V2_UDP_CONN="${V2_UDP_CONN:-0}" \
        J_V2_AWG0="${V2_AWG0:-}" J_V2_HS0="${V2_HS0:--1}" J_V2_P0="${V2_P0:-0}" \
        J_V2_AGH="${V2_AGH:-}" J_V2_DNS53="${V2_DNS53:-}" J_V2_WEB3000="${V2_WEB3000:-}" \
        J_V2_WAN_PING="${V2_WAN_PING:-}" J_V2_ERROR="${V2_ERROR:-}" \
        J_V2_CPUS="${V2_CPUS:-1}" J_V2_UPTIME_S="${V2_UPTIME_S:-0}" \
        J_V2_CPU_MHZ="${V2_CPU_MHZ:-0}" J_V2_SWAP="${V2_SWAP:-0/0MB}" \
        J_V2_RX_TOTAL="${V2_RX_TOTAL:-0}" J_V2_TX_TOTAL="${V2_TX_TOTAL:-0}" \
        J_V2_MEM_AVAIL="${V2_MEM_AVAIL:-0}" J_V2_MEM_BUFFERS="${V2_MEM_BUFFERS:-0}" J_V2_MEM_CACHED="${V2_MEM_CACHED:-0}" \
        J_V2_DISK_INODES="${V2_DISK_INODES:-0%}" J_V2_PROC_COUNT="${V2_PROC_COUNT:-0}" J_V2_OPEN_FILES="${V2_OPEN_FILES:-0}" \
        J_LOG_FILE="$LOG_FILE"

    "${PYTHON_CMD[@]}" <<'PYEOF' > "$tmp_json"
import json, os

def s(k, d=''):  return os.environ.get(k, d)
def ni(k, d=0):
    try:    return int(os.environ.get(k, d))
    except: return d
def nf(k, d=0.0):
    try:    return round(float(os.environ.get(k, d)), 2)
    except: return d
def b(k): return os.environ.get(k, 'false') == 'true'
def maybe_null(k):
    v = os.environ.get(k, '')
    return v if v else None

def read_log_tail(n=30):
    path = os.environ.get('J_LOG_FILE', '')
    if not path: return []
    try:
        with open(path, 'r', errors='replace') as f:
            lines = [l.rstrip('\r\n') for l in f if l.strip()]
        return lines[-n:]
    except Exception:
        return []

data = {
    'ts': ni('J_TS'),
    'log': read_log_tail(30),
    'vps1': {
        'online':       b('J_V1_ONLINE'),
        'ip':           s('J_V1_IP'),
        'host':         s('J_V1_HOST'),
        'cpus':         ni('J_V1_CPUS', 1),
        'cpu_mhz':      ni('J_V1_CPU_MHZ'),
        'uptime_s':     ni('J_V1_UPTIME_S'),
        'load1':        nf('J_V1_LOAD1'),
        'load5':        nf('J_V1_LOAD5'),
        'load15':       nf('J_V1_LOAD15'),
        'mem_used_mb':  ni('J_V1_MEM_USED'),
        'mem_free_mb':  ni('J_V1_MEM_FREE'),
        'mem_total_mb': ni('J_V1_MEM_TOTAL'),
        'swap':         s('J_V1_SWAP'),
        'disk_used':    s('J_V1_DISK_USED'),
        'disk_total':   s('J_V1_DISK_TOTAL'),
        'disk_pct':     ni('J_V1_DISK_PCT'),
        'net_if':       s('J_V1_NET_IF'),
        'rx_speed':     ni('J_V1_RX_SPEED'),
        'tx_speed':     ni('J_V1_TX_SPEED'),
        'tcp_est':      ni('J_V1_TCP_EST'),
        'udp_conn':     ni('J_V1_UDP_CONN'),
        'awg0':         s('J_V1_AWG0'),
        'awg1':         s('J_V1_AWG1'),
        'hs0_age':      ni('J_V1_HS0', -1),
        'hs1_age':      ni('J_V1_HS1', -1),
        'active_peers_awg1': ni('J_V1_A1_ACTIVE', 0),
        'peers_awg0':   ni('J_V1_P0'),
        'peers_awg1':   ni('J_V1_P1'),
        'tun_ping':     s('J_V1_TUN_PING'),
        'rx_total':     ni('J_V1_RX_TOTAL'),
        'tx_total':     ni('J_V1_TX_TOTAL'),
        'mem_avail_mb': ni('J_V1_MEM_AVAIL'),
        'mem_buffers_mb': ni('J_V1_MEM_BUFFERS'),
        'mem_cached_mb': ni('J_V1_MEM_CACHED'),
        'disk_inodes':  s('J_V1_DISK_INODES'),
        'proc_count':   ni('J_V1_PROC_COUNT'),
        'open_files':   ni('J_V1_OPEN_FILES'),
        'error':        maybe_null('J_V1_ERROR'),
    },
    'vps2': {
        'online':       b('J_V2_ONLINE'),
        'ip':           s('J_V2_IP'),
        'host':         s('J_V2_HOST'),
        'cpus':         ni('J_V2_CPUS', 1),
        'cpu_mhz':      ni('J_V2_CPU_MHZ'),
        'uptime_s':     ni('J_V2_UPTIME_S'),
        'load1':        nf('J_V2_LOAD1'),
        'load5':        nf('J_V2_LOAD5'),
        'load15':       nf('J_V2_LOAD15'),
        'mem_used_mb':  ni('J_V2_MEM_USED'),
        'mem_free_mb':  ni('J_V2_MEM_FREE'),
        'mem_total_mb': ni('J_V2_MEM_TOTAL'),
        'swap':         s('J_V2_SWAP'),
        'disk_used':    s('J_V2_DISK_USED'),
        'disk_total':   s('J_V2_DISK_TOTAL'),
        'disk_pct':     ni('J_V2_DISK_PCT'),
        'net_if':       s('J_V2_NET_IF'),
        'rx_speed':     ni('J_V2_RX_SPEED'),
        'tx_speed':     ni('J_V2_TX_SPEED'),
        'tcp_est':      ni('J_V2_TCP_EST'),
        'udp_conn':     ni('J_V2_UDP_CONN'),
        'awg0':         s('J_V2_AWG0'),
        'hs0_age':      ni('J_V2_HS0', -1),
        'peers_awg0':   ni('J_V2_P0'),
        'agh':          s('J_V2_AGH'),
        'dns53':        s('J_V2_DNS53'),
        'web3000':      s('J_V2_WEB3000'),
        'wan_ping':     s('J_V2_WAN_PING'),
        'rx_total':     ni('J_V2_RX_TOTAL'),
        'tx_total':     ni('J_V2_TX_TOTAL'),
        'mem_avail_mb': ni('J_V2_MEM_AVAIL'),
        'mem_buffers_mb': ni('J_V2_MEM_BUFFERS'),
        'mem_cached_mb': ni('J_V2_MEM_CACHED'),
        'disk_inodes':  s('J_V2_DISK_INODES'),
        'proc_count':   ni('J_V2_PROC_COUNT'),
        'open_files':   ni('J_V2_OPEN_FILES'),
        'error':        maybe_null('J_V2_ERROR'),
    },
}
print(json.dumps(data, indent=2, ensure_ascii=False))
PYEOF

    local rc=$?
    if [[ $rc -eq 0 ]]; then
        mv "$tmp_json" "$JSON_FILE"
        log_line "DEBUG" "wrote $JSON_FILE ts=$now"
    else
        rm -f "$tmp_json"
        log_line "ERROR" "python runtime failed writing json rc=$rc"
    fi
}

# ---------------------------------------------------------------------------
# Start HTTP server
# ---------------------------------------------------------------------------

wsl_to_win_path() {
    local p="$1"
    if [[ "$p" =~ ^/mnt/([a-z])/(.*) ]]; then
        printf '%s:\\%s' "${BASH_REMATCH[1]^^}" "${BASH_REMATCH[2]//\//\\}"
    else
        printf '%s' "$p"
    fi
}

detect_http_python() {
    HTTP_PYTHON_CMD=()
    HTTP_SERVE_DIR="$(pwd)"
    if grep -qi microsoft /proc/version 2>/dev/null; then
        local win_py
        for win_py in python.exe py.exe; do
            if command -v "$win_py" >/dev/null 2>&1; then
                HTTP_PYTHON_CMD=("$win_py")
                HTTP_SERVE_DIR="$(wsl_to_win_path "$(pwd)")"
                log_line "INFO" "WSL detected — HTTP server will use Windows Python ($win_py) serving $HTTP_SERVE_DIR"
                return
            fi
        done
        log_line "WARN" "WSL detected but no Windows Python found — HTTP server will bind to WSL localhost (may not be reachable from Windows browser)"
    fi
    HTTP_PYTHON_CMD=("${PYTHON_CMD[@]}")
}

start_http_server() {
    detect_http_python
    local srv_script
    srv_script="$(mktemp /tmp/monweb_srv_XXXXXX.py)" || {
        log_line "WARN" "mktemp failed, falling back to plain http.server (no /api/ping)"
        "${HTTP_PYTHON_CMD[@]}" -m http.server "$HTTP_PORT" --bind 127.0.0.1 2>/dev/null &
        HTTP_PID="$!"; sleep 0.3; return
    }
    cat > "$srv_script" << 'PYSERVER'
import sys, os, json, subprocess, threading, re, platform
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

os.chdir(sys.argv[2] if len(sys.argv) > 2 else os.getcwd())

IS_WIN = platform.system() == 'Windows'

class VPNHandler(SimpleHTTPRequestHandler):
    def log_message(self, *a): pass

    def end_headers(self):
        if hasattr(self, '_no_cache') and self._no_cache:
            self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
            self.send_header('Pragma', 'no-cache')
        super().end_headers()

    def do_GET(self):
        p = urlparse(self.path)
        self._no_cache = p.path.endswith('/data.json') or p.path == '/data.json'
        if p.path == '/api/ping':
            self._handle_ping(parse_qs(p.query))
        else:
            super().do_GET()

    def _handle_ping(self, params):
        hosts = [h.strip() for h in params.get('hosts', [''])[0].split(',') if h.strip()]
        results = {}
        lock = threading.Lock()

        def do_ping(host):
            try:
                if IS_WIN:
                    cmd = ['ping', '-n', '3', '-w', '2000', host]
                else:
                    cmd = ['ping', '-c', '3', '-W', '2', host]
                pr = subprocess.run(cmd, capture_output=True, text=True, timeout=12)
                if IS_WIN:
                    ma = re.search(r'Average\s*=\s*(\d+)ms', pr.stdout)
                    ml = re.search(r'\((\d+)%\s+loss\)', pr.stdout)
                    if ma:
                        r = {'status': 'ok',
                             'avg_ms': round(float(ma.group(1)), 1),
                             'loss': int(ml.group(1)) if ml else 0}
                    else:
                        r = {'status': 'fail', 'avg_ms': None, 'loss': 100}
                else:
                    ma = re.search(r'rtt[^=]+=\s*[\d.]+/([\d.]+)/', pr.stdout)
                    ml = re.search(r'(\d+)%\s+packet loss', pr.stdout)
                    if ma:
                        r = {'status': 'ok',
                             'avg_ms': round(float(ma.group(1)), 1),
                             'loss': int(ml.group(1)) if ml else 0}
                    else:
                        r = {'status': 'fail', 'avg_ms': None, 'loss': 100}
            except subprocess.TimeoutExpired:
                r = {'status': 'timeout'}
            except Exception as e:
                r = {'status': 'error', 'msg': str(e)}
            with lock:
                results[host] = r

        threads = [threading.Thread(target=do_ping, args=(h,)) for h in hosts]
        for t in threads: t.start()
        for t in threads: t.join(timeout=15)

        body = json.dumps(results).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
ThreadingHTTPServer(('127.0.0.1', port), VPNHandler).serve_forever()
PYSERVER
    TEMP_KEY_FILES+=("$srv_script")
    if grep -qi microsoft /proc/version 2>/dev/null; then
        local win_srv_dir win_srv_copy
        win_srv_dir="$(cmd.exe /C "echo %TEMP%" 2>/dev/null | tr -d '\r')"
        win_srv_copy="${win_srv_dir}\\monweb_srv_$$.py"
        cp "$srv_script" "$(wslpath -u "$win_srv_dir")/monweb_srv_$$.py" 2>/dev/null
        TEMP_KEY_FILES+=("$(wslpath -u "$win_srv_dir")/monweb_srv_$$.py")
        "${HTTP_PYTHON_CMD[@]}" "$win_srv_copy" "$HTTP_PORT" "$HTTP_SERVE_DIR" &
    else
        "${HTTP_PYTHON_CMD[@]}" "$srv_script" "$HTTP_PORT" "$HTTP_SERVE_DIR" 2>/dev/null &
    fi
    HTTP_PID="$!"
    sleep 1
    if kill -0 "$HTTP_PID" 2>/dev/null; then
        log_line "INFO" "HTTP server started on port $HTTP_PORT with /api/ping (pid=$HTTP_PID)"
    else
        log_line "WARN" "HTTP server may have failed to start (port $HTTP_PORT busy?)"
        HTTP_PID=""
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

load_defaults_from_files

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps1-ip)      VPS1_IP="$2";      shift 2 ;;
        --vps1-user)    VPS1_USER="$2";    shift 2 ;;
        --vps1-key)     VPS1_KEY="$2";     shift 2 ;;
        --vps1-pass)    VPS1_PASS="$2";    shift 2 ;;
        --vps2-ip)      VPS2_IP="$2";      shift 2 ;;
        --vps2-user)    VPS2_USER="$2";    shift 2 ;;
        --vps2-key)     VPS2_KEY="$2";     shift 2 ;;
        --vps2-pass)    VPS2_PASS="$2";    shift 2 ;;
        --vps2-tun-ip)  VPS2_TUN_IP="$2"; shift 2 ;;
        --interval)     INTERVAL="$2";     shift 2 ;;
        --port)         HTTP_PORT="$2";    shift 2 ;;
        --ssh-timeout)  SSH_TIMEOUT="$2";  shift 2 ;;
        --log-file)     LOG_FILE="$2";     shift 2 ;;
        --help|-h)
            echo "Usage: bash monitor-web.sh [OPTIONS]"
            echo "  --interval SEC    Poll interval (default: 5)"
            echo "  --port PORT       HTTP server port (default: 8080)"
            echo "  --ssh-timeout SEC SSH timeout (default: 8)"
            echo "  --vps1-key PATH   SSH key for VPS1"
            echo "  --vps2-key PATH   SSH key for VPS2"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

VPS1_USER="${VPS1_USER:-root}"
VPS2_USER="${VPS2_USER:-root}"

[[ -z "$VPS1_IP" ]] && { echo "Specify VPS1_IP in .env or --vps1-ip" >&2; exit 1; }
[[ -z "$VPS2_IP" ]] && { echo "Specify VPS2_IP in .env or --vps2-ip" >&2; exit 1; }
[[ -z "$VPS1_KEY" && -z "$VPS1_PASS" ]] && { echo "Specify VPS1_KEY in .env or --vps1-key / --vps1-pass" >&2; exit 1; }
[[ -z "$VPS2_KEY" && -z "$VPS2_PASS" ]] && { echo "Specify VPS2_KEY in .env or --vps2-key / --vps2-pass" >&2; exit 1; }

VPS1_KEY="$(expand_tilde "$VPS1_KEY")"
VPS2_KEY="$(expand_tilde "$VPS2_KEY")"
LOG_FILE="$(expand_tilde "$LOG_FILE")"

VPS1_KEY="$(auto_pick_key_if_missing "$VPS1_KEY")"
VPS2_KEY="$(auto_pick_key_if_missing "$VPS2_KEY")"

[[ -n "$VPS1_PASS" ]] && VPS1_KEY=""
[[ -n "$VPS2_PASS" ]] && VPS2_KEY=""
[[ -n "$VPS1_KEY" && ! -f "$VPS1_KEY" && -z "$VPS1_PASS" ]] && VPS1_KEY=""
[[ -n "$VPS2_KEY" && ! -f "$VPS2_KEY" && -z "$VPS2_PASS" ]] && VPS2_KEY=""

VPS1_KEY="$(prepare_key_for_ssh "$VPS1_KEY")"
VPS2_KEY="$(prepare_key_for_ssh "$VPS2_KEY")"

if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [[ "$INTERVAL" -lt 1 ]]; then
    echo "--interval must be integer >= 1" >&2; exit 1
fi
if [[ -n "$VPS1_PASS" || -n "$VPS2_PASS" ]]; then
    command -v sshpass >/dev/null 2>&1 || { echo "sshpass required for password auth" >&2; exit 1; }
fi
command -v ssh     >/dev/null 2>&1 || { echo "ssh not found" >&2; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "timeout not found" >&2; exit 1; }
if command -v python3 >/dev/null 2>&1; then
    PYTHON_CMD=(python3)
elif command -v python >/dev/null 2>&1; then
    PYTHON_CMD=(python)
elif command -v py >/dev/null 2>&1; then
    PYTHON_CMD=(py -3)
else
    echo "Python not found (need python3, python, or py -3)" >&2
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" || { echo "Cannot create log file: $LOG_FILE" >&2; exit 1; }

mkdir -p "$(dirname "$JSON_FILE")"

log_line "INFO" "monitor-web started: vps1=${VPS1_USER}@${VPS1_IP} vps2=${VPS2_USER}@${VPS2_IP} interval=${INTERVAL} port=${HTTP_PORT}"

# ---------------------------------------------------------------------------
# Dynamic IP selection (use internal VPN IP if VPN is active on localhost)
# ---------------------------------------------------------------------------
ping_host() {
    local host="$1"
    # Try Linux ping first, then Windows ping.exe, with strict timeout
    if timeout 2 ping -c 1 -W 1 "$host" >/dev/null 2>&1; then return 0; fi
    if command -v ping.exe >/dev/null 2>&1; then
        timeout 2 ping.exe -n 1 -w 1000 "$host" >/dev/null 2>&1 && return 0
    fi
    return 1
}

check_internal_ips() {
    # VPS1: try internal VPN IP (10.9.0.1) first — reachable when client is connected
    if [[ -n "$VPS1_INTERNAL" ]] && ping_host "$VPS1_INTERNAL"; then
        CURRENT_VPS1_IP="$VPS1_INTERNAL"
        log_line "DEBUG" "VPS1 using internal IP $VPS1_INTERNAL"
    else
        CURRENT_VPS1_IP="$VPS1_IP"
    fi
    # VPS2: always use public IP for SSH — the tunnel IP 10.8.0.2 is the
    # VPS1↔VPS2 inter-server tunnel interface and SSH does not listen there
    CURRENT_VPS2_IP="$VPS2_IP"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

start_http_server

echo ""
echo "  VPN Dashboard running"
echo "  Dashboard : http://127.0.0.1:${HTTP_PORT}/dashboard.html"
echo "  Data JSON : http://127.0.0.1:${HTTP_PORT}/vpn-output/data.json"
echo "  Interval  : ${INTERVAL}s  |  Ctrl+C to stop"
echo ""

while true; do
    check_internal_ips
    PREV_TS="$(date +%s)"

    # Collect from both servers in parallel to avoid one blocking the other
    local_tmp1="$(mktemp)"
    local_tmp2="$(mktemp)"
    collect_vps1 > "$local_tmp1" &
    PID1=$!
    collect_vps2 > "$local_tmp2" &
    PID2=$!

    # Wait with a hard cap: SSH_TIMEOUT + 10s
    local_deadline=$(( SSH_TIMEOUT + 10 ))
    wait_deadline() {
        local pid=$1 sec=0
        while kill -0 "$pid" 2>/dev/null; do
            sleep 1; sec=$((sec+1))
            [[ $sec -ge $local_deadline ]] && { kill "$pid" 2>/dev/null; break; }
        done
    }
    wait_deadline $PID1
    wait_deadline $PID2

    VPS1_DATA="$(cat "$local_tmp1")"; rm -f "$local_tmp1"
    VPS2_DATA="$(cat "$local_tmp2")"; rm -f "$local_tmp2"

    write_json "$VPS1_DATA" "$VPS2_DATA"
    printf "\r  [%s] JSON updated  (next in %ss)" "$(date '+%H:%M:%S')" "$INTERVAL"
    sleep "$INTERVAL"
done
