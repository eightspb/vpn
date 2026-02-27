#!/bin/bash
# =============================================================================
# Реалтайм мониторинг состояния VPS1 и VPS2
# Запуск без аргументов:
#   bash monitor-realtime.sh
#
# Источники настроек (по приоритету):
# 1) Аргументы CLI
# 2) ./.env
# 3) ./vpn-output/keys.env (IP и TUN_NET)
# 4) Встроенные дефолты
# =============================================================================

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

VPS1_IP="89.169.179.233"
VPS1_USER="slava"
VPS1_KEY="C:\Users\slava\.ssh\ssh-key-1772056840349"
VPS1_PASS=""

VPS2_IP="38.135.122.81"
VPS2_USER="root"
VPS2_KEY="~/.ssh/id_rsa"
VPS2_PASS=""

VPS2_TUN_IP="10.8.0.2"
INTERVAL=1
SSH_TIMEOUT=8
LOG_FILE="./vpn-output/monitor.log"
LOG_LEVEL="DEBUG"
LAST_ERR_VPS1=""
LAST_ERR_VPS2=""
TEMP_KEY_FILES=()
VPS1_PREV_RX=0
VPS1_PREV_TX=0
VPS2_PREV_RX=0
VPS2_PREV_TX=0
PREV_TS=0

usage() {
    cat <<'EOF'
Реалтайм мониторинг состояния двух серверов.

Аутентификация:
  --vps1-user USER      SSH пользователь VPS1 (default: root)
  --vps1-key PATH       SSH ключ VPS1
  --vps1-pass PASS      SSH пароль VPS1 (если без ключа)
  --vps2-user USER      SSH пользователь VPS2 (default: root)
  --vps2-key PATH       SSH ключ VPS2
  --vps2-pass PASS      SSH пароль VPS2 (если без ключа)

Опции:
  --vps2-tun-ip IP      Туннельный IP VPS2 для ping с VPS1 (default: 10.8.0.2)
  --interval SEC        Интервал обновления экрана (default: 1)
  --ssh-timeout SEC     Таймаут SSH-команды (default: 8)
  --log-file PATH       Файл лога (default: ./vpn-output/monitor.log)
  --help                Показать эту справку
EOF
}

clean_value() {
    local v="$1"
    v="${v//$'\r'/}"
    v="${v#\"}"
    v="${v%\"}"
    v="${v#\'}"
    v="${v%\'}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf "%s" "$v"
}

read_kv() {
    local file="$1"
    local key="$2"
    local raw
    raw="$(awk -F= -v k="$key" '$1==k{sub(/^[^=]*=/,"",$0); print $0}' "$file" | tail -n 1)"
    clean_value "$raw"
}

load_defaults_from_files() {
    # keys.env содержит IP и внутренние сети после deploy-vps1.sh
    if [[ -f "./vpn-output/keys.env" ]]; then
        local k_vps1 k_tun
        k_vps1="$(read_kv ./vpn-output/keys.env VPS1_IP)"
        k_tun="$(read_kv ./vpn-output/keys.env TUN_NET)"
        [[ -n "${k_vps1}" ]] && VPS1_IP="$k_vps1"
        [[ -n "${k_tun}" ]] && VPS2_TUN_IP="${k_tun}.2"
    fi

    # .env содержит SSH доступ и может переопределять IP
    if [[ -f "./.env" ]]; then
        local e_vps1_ip e_vps1_user e_vps1_key e_vps1_pass
        local e_vps2_ip e_vps2_user e_vps2_key e_vps2_pass
        e_vps1_ip="$(read_kv ./.env VPS1_IP)"
        e_vps1_user="$(read_kv ./.env VPS1_USER)"
        e_vps1_key="$(read_kv ./.env VPS1_KEY)"
        e_vps1_pass="$(read_kv ./.env VPS1_PASS)"
        e_vps2_ip="$(read_kv ./.env VPS2_IP)"
        e_vps2_user="$(read_kv ./.env VPS2_USER)"
        e_vps2_key="$(read_kv ./.env VPS2_KEY)"
        e_vps2_pass="$(read_kv ./.env VPS2_PASS)"

        [[ -n "${e_vps1_ip}" ]] && VPS1_IP="$e_vps1_ip"
        [[ -n "${e_vps1_user}" ]] && VPS1_USER="$e_vps1_user"
        [[ -n "${e_vps1_key}" ]] && VPS1_KEY="$e_vps1_key"
        [[ -n "${e_vps1_pass}" ]] && VPS1_PASS="$e_vps1_pass"
        [[ -n "${e_vps2_ip}" ]] && VPS2_IP="$e_vps2_ip"
        [[ -n "${e_vps2_user}" ]] && VPS2_USER="$e_vps2_user"
        [[ -n "${e_vps2_key}" ]] && VPS2_KEY="$e_vps2_key"
        [[ -n "${e_vps2_pass}" ]] && VPS2_PASS="$e_vps2_pass"
    fi
}

expand_tilde() {
    local p="$1"
    local drive rest
    p="$(clean_value "$p")"
    p="${p//\\//}"
    p="${p/\/~\//\/}"
    if [[ "$p" =~ ^([A-Za-z]):/(.*)$ ]]; then
        drive="${BASH_REMATCH[1],,}"
        rest="${BASH_REMATCH[2]}"
        p="/mnt/${drive}/${rest}"
    fi
    if [[ "$p" == "~/"* ]]; then
        printf "%s" "${HOME}/${p#~/}"
    elif [[ "$p" == "${HOME}/~/"* ]]; then
        printf "%s" "${HOME}/${p#${HOME}/~/}"
    else
        printf "%s" "$p"
    fi
}

log_line() {
    local level="$1"
    local msg="$2"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "[%s] [%s] %s\n" "$ts" "$level" "$msg" >> "$LOG_FILE"
}

set_last_error() {
    local server="$1"
    local msg="$2"
    if [[ "$server" == "VPS1" ]]; then
        LAST_ERR_VPS1="$msg"
    else
        LAST_ERR_VPS2="$msg"
    fi
}

auto_pick_key_if_missing() {
    local current_key="$1"
    local fallback1 fallback2 fallback3 fallback4 win_home
    local candidate
    fallback1="${HOME}/.ssh/id_ed25519"
    fallback2="${HOME}/.ssh/id_rsa"
    win_home="${USERPROFILE:-}"
    win_home="${win_home//\\//}"
    fallback3="${win_home}/.ssh/id_ed25519"
    fallback4="${win_home}/.ssh/id_rsa"

    if [[ -n "$current_key" && -f "$current_key" ]]; then
        printf "%s" "$current_key"
        return
    fi
    if [[ -f "$fallback1" ]]; then
        printf "%s" "$fallback1"
        return
    fi
    if [[ -f "$fallback2" ]]; then
        printf "%s" "$fallback2"
        return
    fi
    if [[ -n "$win_home" && -f "$fallback3" ]]; then
        printf "%s" "$fallback3"
        return
    fi
    if [[ -n "$win_home" && -f "$fallback4" ]]; then
        printf "%s" "$fallback4"
        return
    fi
    for candidate in /c/Users/*/.ssh/id_ed25519 /c/Users/*/.ssh/id_rsa /mnt/c/Users/*/.ssh/id_ed25519 /mnt/c/Users/*/.ssh/id_rsa; do
        if [[ -f "$candidate" ]]; then
            printf "%s" "$candidate"
            return
        fi
    done
    printf "%s" "$current_key"
}

prepare_key_for_ssh() {
    local key="$1"
    local tmp_key
    if [[ -z "$key" || ! -f "$key" ]]; then
        printf "%s" "$key"
        return
    fi
    if [[ "$key" == /mnt/* ]]; then
        tmp_key="$(mktemp /tmp/monitor_key_XXXXXX)" || {
            printf "%s" "$key"
            return
        }
        cp "$key" "$tmp_key" 2>/dev/null || {
            rm -f "$tmp_key"
            printf "%s" "$key"
            return
        }
        chmod 600 "$tmp_key" 2>/dev/null || true
        TEMP_KEY_FILES+=("$tmp_key")
        printf "%s" "$tmp_key"
        return
    fi
    printf "%s" "$key"
}

cleanup_temp_keys() {
    local f
    for f in "${TEMP_KEY_FILES[@]}"; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f"
    done
}

restore_terminal() {
    printf "\033[?25h"
    tput cnorm 2>/dev/null || true
    cleanup_temp_keys
}

trap restore_terminal EXIT

load_defaults_from_files

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps1-ip) VPS1_IP="$2"; shift 2 ;;
        --vps1-user) VPS1_USER="$2"; shift 2 ;;
        --vps1-key) VPS1_KEY="$2"; shift 2 ;;
        --vps1-pass) VPS1_PASS="$2"; shift 2 ;;
        --vps2-ip) VPS2_IP="$2"; shift 2 ;;
        --vps2-user) VPS2_USER="$2"; shift 2 ;;
        --vps2-key) VPS2_KEY="$2"; shift 2 ;;
        --vps2-pass) VPS2_PASS="$2"; shift 2 ;;
        --vps2-tun-ip) VPS2_TUN_IP="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --ssh-timeout) SSH_TIMEOUT="$2"; shift 2 ;;
        --log-file) LOG_FILE="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Неизвестный параметр: $1" >&2; usage; exit 1 ;;
    esac
done

[[ -z "$VPS1_KEY" && -z "$VPS1_PASS" ]] && { echo "Укажите --vps1-key или --vps1-pass" >&2; exit 1; }
[[ -z "$VPS2_KEY" && -z "$VPS2_PASS" ]] && { echo "Укажите --vps2-key или --vps2-pass" >&2; exit 1; }

VPS1_KEY="$(expand_tilde "$VPS1_KEY")"
VPS2_KEY="$(expand_tilde "$VPS2_KEY")"
LOG_FILE="$(expand_tilde "$LOG_FILE")"

VPS1_KEY="$(auto_pick_key_if_missing "$VPS1_KEY")"
VPS2_KEY="$(auto_pick_key_if_missing "$VPS2_KEY")"

# Если задан пароль, явно используем парольную аутентификацию.
if [[ -n "$VPS1_PASS" ]]; then
    VPS1_KEY=""
fi
if [[ -n "$VPS2_PASS" ]]; then
    VPS2_KEY=""
fi

# Если файл ключа не найден, даём ssh использовать дефолтные ключи/agent
if [[ -n "$VPS1_KEY" && ! -f "$VPS1_KEY" && -z "$VPS1_PASS" ]]; then
    VPS1_KEY=""
fi
if [[ -n "$VPS2_KEY" && ! -f "$VPS2_KEY" && -z "$VPS2_PASS" ]]; then
    VPS2_KEY=""
fi

VPS1_KEY="$(prepare_key_for_ssh "$VPS1_KEY")"
VPS2_KEY="$(prepare_key_for_ssh "$VPS2_KEY")"

if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [[ "$INTERVAL" -lt 1 ]]; then
    echo "--interval должен быть целым числом >= 1" >&2
    exit 1
fi

if ! [[ "$SSH_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$SSH_TIMEOUT" -lt 1 ]]; then
    echo "--ssh-timeout должен быть целым числом >= 1" >&2
    exit 1
fi

if [[ -n "$VPS1_PASS" || -n "$VPS2_PASS" ]]; then
    command -v sshpass >/dev/null 2>&1 || {
        echo "Для пароля нужен sshpass (sudo apt install sshpass)" >&2
        exit 1
    }
fi

command -v ssh >/dev/null 2>&1 || { echo "Не найден ssh" >&2; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "Не найден timeout" >&2; exit 1; }

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" || { echo "Не удалось создать лог-файл: $LOG_FILE" >&2; exit 1; }

log_line "INFO" "monitor started: vps1=${VPS1_USER}@${VPS1_IP}, vps2=${VPS2_USER}@${VPS2_IP}, interval=${INTERVAL}, timeout=${SSH_TIMEOUT}"
if [[ -n "$VPS1_KEY" ]]; then
    if [[ -f "$VPS1_KEY" ]]; then
        log_line "INFO" "VPS1 auth=key path=$VPS1_KEY"
    else
        log_line "ERROR" "VPS1 key file not found: $VPS1_KEY"
    fi
else
    if [[ -n "$VPS1_PASS" ]]; then
        log_line "INFO" "VPS1 auth=password"
    else
        log_line "INFO" "VPS1 auth=default_ssh_keys_or_agent"
    fi
fi
if [[ -n "$VPS2_KEY" ]]; then
    if [[ -f "$VPS2_KEY" ]]; then
        log_line "INFO" "VPS2 auth=key path=$VPS2_KEY"
    else
        log_line "ERROR" "VPS2 key file not found: $VPS2_KEY"
    fi
else
    if [[ -n "$VPS2_PASS" ]]; then
        log_line "INFO" "VPS2 auth=password"
    else
        log_line "INFO" "VPS2 auth=default_ssh_keys_or_agent"
    fi
fi

status_color() {
    case "$1" in
        active|up|ok|yes|1) echo "$GREEN" ;;
        unknown|degraded) echo "$YELLOW" ;;
        *) echo "$RED" ;;
    esac
}

fmt_status() {
    local value="${1:-unknown}"
    local color
    color="$(status_color "$value")"
    printf "%b%s%b" "$color" "$value" "$NC"
}

fmt_handshake() {
    local sec="${1:--1}"
    if ! [[ "$sec" =~ ^-?[0-9]+$ ]]; then
        printf "%bunknown%b" "$YELLOW" "$NC"
        return
    fi
    if [[ "$sec" -lt 0 ]]; then
        printf "%bnever%b" "$RED" "$NC"
    elif [[ "$sec" -lt 120 ]]; then
        printf "%b%ss%b" "$GREEN" "$sec" "$NC"
    elif [[ "$sec" -lt 600 ]]; then
        printf "%b%ss%b" "$YELLOW" "$sec" "$NC"
    else
        printf "%b%ss%b" "$RED" "$sec" "$NC"
    fi
}

fmt_rate() {
    local bps="${1:-0}"
    if ! [[ "$bps" =~ ^[0-9]+$ ]]; then
        printf "n/a"
        return
    fi
    awk -v b="$bps" 'BEGIN{
        split("B/s KB/s MB/s GB/s", u, " ");
        i=1;
        while (b>=1024 && i<4) { b/=1024; i++ }
        if (i==1) printf "%d %s", b, u[i];
        else printf "%.1f %s", b, u[i];
    }'
}

update_speed() {
    local server="$1"
    local rx="$2"
    local tx="$3"
    local now elapsed prev_rx prev_tx d_rx d_tx

    now="$(date +%s)"
    if [[ "$PREV_TS" -eq 0 ]]; then
        PREV_TS="$now"
    fi
    elapsed=$((now - PREV_TS))
    [[ "$elapsed" -le 0 ]] && elapsed=1

    if [[ "$server" == "VPS1" ]]; then
        prev_rx="$VPS1_PREV_RX"
        prev_tx="$VPS1_PREV_TX"
        VPS1_PREV_RX="$rx"
        VPS1_PREV_TX="$tx"
    else
        prev_rx="$VPS2_PREV_RX"
        prev_tx="$VPS2_PREV_TX"
        VPS2_PREV_RX="$rx"
        VPS2_PREV_TX="$tx"
    fi

    if ! [[ "$prev_rx" =~ ^[0-9]+$ && "$prev_tx" =~ ^[0-9]+$ && "$rx" =~ ^[0-9]+$ && "$tx" =~ ^[0-9]+$ ]]; then
        log_line "WARN" "update_speed $server: non-numeric rx/tx prev_rx=$prev_rx prev_tx=$prev_tx rx=$rx tx=$tx"
        printf "n/a|n/a"
        return
    fi
    if [[ "$prev_rx" -eq 0 && "$prev_tx" -eq 0 && "$PREV_TS" -eq 0 ]]; then
        printf "0 B/s|0 B/s"
        return
    fi

    d_rx=$((rx - prev_rx))
    d_tx=$((tx - prev_tx))
    [[ "$d_rx" -lt 0 ]] && d_rx=0
    [[ "$d_tx" -lt 0 ]] && d_tx=0

    printf "%s|%s" "$(fmt_rate $((d_rx / elapsed)))" "$(fmt_rate $((d_tx / elapsed)))"
}

ssh_exec() {
    local server="$1"
    local ip="$2"
    local user="$3"
    local key="$4"
    local pass="$5"
    local cmd="$6"
    local ssh_opts=(-F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=no -o ConnectTimeout="$SSH_TIMEOUT")
    local stderr_file rc out err
    stderr_file="$(mktemp)"

    ip="$(clean_value "$ip")"
    user="$(clean_value "$user")"
    key="$(expand_tilde "$key")"
    pass="$(clean_value "$pass")"

    if [[ -n "$key" ]]; then
        out="$(timeout "$SSH_TIMEOUT" ssh "${ssh_opts[@]}" -i "$key" "${user}@${ip}" "$cmd" 2>"$stderr_file")"
        rc=$?
    else
        if [[ -n "$pass" ]]; then
            out="$(timeout "$SSH_TIMEOUT" sshpass -p "$pass" ssh "${ssh_opts[@]}" "${user}@${ip}" "$cmd" 2>"$stderr_file")"
            rc=$?
        else
            out="$(timeout "$SSH_TIMEOUT" ssh "${ssh_opts[@]}" "${user}@${ip}" "$cmd" 2>"$stderr_file")"
            rc=$?
        fi
    fi

    err="$(tr '\n' '|' < "$stderr_file")"
    rm -f "$stderr_file"

    if [[ $rc -ne 0 ]]; then
        [[ -z "$err" ]] && err="no stderr"
        set_last_error "$server" "rc=$rc ${err}"
        log_line "ERROR" "$server ssh failed rc=$rc target=${user}@${ip} err=${err}"
        return "$rc"
    fi

    set_last_error "$server" ""
    if [[ -n "$err" ]]; then
        log_line "WARN" "$server ssh stderr: $err"
    fi
    log_line "DEBUG" "$server ssh ok bytes=$(printf "%s" "$out" | wc -c | tr -d ' ')"
    printf "%s" "$out"
}

collect_vps1() {
    local remote_cmd
    remote_cmd=$(cat <<EOF
HOST=\$(hostname 2>/dev/null || echo n/a)
LOAD=\$(awk '{print \$1","\$2","\$3}' /proc/loadavg 2>/dev/null || echo n/a)
MEM=\$(free -m 2>/dev/null | awk '/Mem:/ {print \$3"/"\$2"MB"}')
DISK=\$(df -h / 2>/dev/null | awk 'NR==2 {print \$3"/"\$2",used="\$5}')
MAIN_IF=\$(ip route 2>/dev/null | awk '/default/ {print \$5; exit}')
RX=\$(awk -v i="\$MAIN_IF" '{gsub(/^[[:space:]]+/,""); split(\$0,a,":"); if(a[1]==i){split(a[2],b," "); print b[1]}}' /proc/net/dev 2>/dev/null | head -1)
TX=\$(awk -v i="\$MAIN_IF" '{gsub(/^[[:space:]]+/,""); split(\$0,a,":"); if(a[1]==i){split(a[2],b," "); print b[9]}}' /proc/net/dev 2>/dev/null | head -1)
TCP_EST=\$(ss -Htn state established 2>/dev/null | wc -l | tr -d ' ')
UDP_CONN=\$(ss -Hun 2>/dev/null | wc -l | tr -d ' ')
TOP_CONN=\$(ss -Htn state established 2>/dev/null | awk '{print \$5}' | sed 's/\\[//g; s/\\]//g' | awk -F: '{NF--; print}' OFS=: | sort | uniq -c | sort -nr | head -3 | awk '{printf "%s(%s) ", \$2, \$1}')
[[ -z "\$TOP_CONN" ]] && TOP_CONN="none"
AWG0=\$(sudo systemctl is-active awg-quick@awg0 2>/dev/null || echo unknown)
AWG1=\$(sudo systemctl is-active awg-quick@awg1 2>/dev/null || echo unknown)
HS0=\$(sudo awg show awg0 latest-handshakes 2>/dev/null | awk 'NR==1 {if (\$2>0) print systime()-\$2; else print -1}')
[[ -z "\$HS0" ]] && HS0=-1
P0=\$(sudo awg show awg0 peers 2>/dev/null | wc -w | tr -d ' ')
P1=\$(sudo awg show awg1 peers 2>/dev/null | wc -w | tr -d ' ')
if ping -c 1 -W 1 -I awg0 "${VPS2_TUN_IP}" >/dev/null 2>&1; then TUN_PING=ok; else TUN_PING=fail; fi
echo "HOST=\$HOST"
echo "LOAD=\$LOAD"
echo "MEM=\$MEM"
echo "DISK=\$DISK"
echo "MAIN_IF=\${MAIN_IF:-n/a}"
echo "RX=\${RX:-0}"
echo "TX=\${TX:-0}"
echo "TCP_EST=\${TCP_EST:-0}"
echo "UDP_CONN=\${UDP_CONN:-0}"
printf "TOP_CONN=%q\n" "${TOP_CONN:-none}"
echo "AWG0=\$AWG0"
echo "AWG1=\$AWG1"
echo "HS0=\$HS0"
echo "P0=\$P0"
echo "P1=\$P1"
echo "TUN_PING=\$TUN_PING"
EOF
)
    ssh_exec "VPS1" "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS" "$remote_cmd"
}

collect_vps2() {
    local remote_cmd
    remote_cmd=$(cat <<'EOF'
HOST=$(hostname 2>/dev/null || echo n/a)
LOAD=$(awk '{print $1","$2","$3}' /proc/loadavg 2>/dev/null || echo n/a)
MEM=$(free -m 2>/dev/null | awk '/Mem:/ {print $3"/"$2"MB"}')
DISK=$(df -h / 2>/dev/null | awk 'NR==2 {print $3"/"$2",used="$5}')
MAIN_IF=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
RX=$(awk -v i="$MAIN_IF" '{gsub(/^[[:space:]]+/,""); split($0,a,":"); if(a[1]==i){split(a[2],b," "); print b[1]}}' /proc/net/dev 2>/dev/null | head -1)
TX=$(awk -v i="$MAIN_IF" '{gsub(/^[[:space:]]+/,""); split($0,a,":"); if(a[1]==i){split(a[2],b," "); print b[9]}}' /proc/net/dev 2>/dev/null | head -1)
TCP_EST=$(ss -Htn state established 2>/dev/null | wc -l | tr -d ' ')
UDP_CONN=$(ss -Hun 2>/dev/null | wc -l | tr -d ' ')
TOP_CONN=$(ss -Htn state established 2>/dev/null | awk '{print $5}' | sed 's/\[//g; s/\]//g' | awk -F: '{NF--; print}' OFS=: | sort | uniq -c | sort -nr | head -3 | awk '{printf "%s(%s) ", $2, $1}')
[[ -z "$TOP_CONN" ]] && TOP_CONN="none"
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
echo "HOST=$HOST"
echo "LOAD=$LOAD"
echo "MEM=$MEM"
echo "DISK=$DISK"
echo "MAIN_IF=${MAIN_IF:-n/a}"
echo "RX=${RX:-0}"
echo "TX=${TX:-0}"
echo "TCP_EST=${TCP_EST:-0}"
echo "UDP_CONN=${UDP_CONN:-0}"
printf "TOP_CONN=%q\n" "${TOP_CONN:-none}"
echo "AWG0=$AWG0"
echo "HS0=$HS0"
echo "P0=$P0"
echo "AGH=$AGH"
echo "DNS53=$DNS53"
echo "WEB3000=$WEB3000"
echo "WAN_PING=$WAN_PING"
EOF
)
    ssh_exec "VPS2" "$VPS2_IP" "$VPS2_USER" "$VPS2_KEY" "$VPS2_PASS" "$remote_cmd"
}

print_block_vps1() {
    local data="$1"
    local speed down up
    if [[ -z "$data" ]]; then
        echo -e "${RED}VPS1 недоступен по SSH${NC}"
        [[ -n "$LAST_ERR_VPS1" ]] && echo -e "  reason: ${YELLOW}${LAST_ERR_VPS1}${NC}"
        return
    fi
    eval "$data"
    log_line "DEBUG" "VPS1 rx=${RX:-0} tx=${TX:-0} if=${MAIN_IF:-?}"
    speed="$(update_speed "VPS1" "${RX:-0}" "${TX:-0}")"
    down="${speed%%|*}"
    up="${speed##*|}"
    echo -e "${BOLD}${CYAN}VPS1 (${VPS1_IP})${NC}"
    echo -e "  host: ${HOST:-n/a}"
    echo -e "  load: ${LOAD:-n/a} | mem: ${MEM:-n/a} | disk: ${DISK:-n/a}"
    echo -e "  net ${MAIN_IF:-n/a}: ↓ ${down} | ↑ ${up}"
    echo -e "  conn: TCP est ${TCP_EST:-0} | UDP ${UDP_CONN:-0} | top: ${TOP_CONN:-none}"
    echo -e "  awg0: $(fmt_status "${AWG0:-unknown}") | awg1: $(fmt_status "${AWG1:-unknown}")"
    echo -e "  awg0 handshake age: $(fmt_handshake "${HS0:--1}") | peers awg0/awg1: ${P0:-0}/${P1:-0}"
    echo -e "  ping awg0 -> ${VPS2_TUN_IP}: $(fmt_status "${TUN_PING:-fail}")"
}

print_block_vps2() {
    local data="$1"
    local speed down up
    if [[ -z "$data" ]]; then
        echo -e "${RED}VPS2 недоступен по SSH${NC}"
        [[ -n "$LAST_ERR_VPS2" ]] && echo -e "  reason: ${YELLOW}${LAST_ERR_VPS2}${NC}"
        return
    fi
    eval "$data"
    log_line "DEBUG" "VPS2 rx=${RX:-0} tx=${TX:-0} if=${MAIN_IF:-?}"
    speed="$(update_speed "VPS2" "${RX:-0}" "${TX:-0}")"
    down="${speed%%|*}"
    up="${speed##*|}"
    echo -e "${BOLD}${CYAN}VPS2 (${VPS2_IP})${NC}"
    echo -e "  host: ${HOST:-n/a}"
    echo -e "  load: ${LOAD:-n/a} | mem: ${MEM:-n/a} | disk: ${DISK:-n/a}"
    echo -e "  net ${MAIN_IF:-n/a}: ↓ ${down} | ↑ ${up}"
    echo -e "  conn: TCP est ${TCP_EST:-0} | UDP ${UDP_CONN:-0} | top: ${TOP_CONN:-none}"
    echo -e "  awg0: $(fmt_status "${AWG0:-unknown}") | handshake age: $(fmt_handshake "${HS0:--1}") | peers: ${P0:-0}"
    echo -e "  AdGuard: $(fmt_status "${AGH:-inactive}") | DNS:53 $(fmt_status "${DNS53:-down}") | Web:3000 $(fmt_status "${WEB3000:-down}")"
    echo -e "  ping 8.8.8.8: $(fmt_status "${WAN_PING:-fail}")"
}

printf "\033[?25l"
tput civis 2>/dev/null || true
while true; do
    printf "\033[H"
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║                 LIVE VPN SERVER MONITOR                     ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e "time: $(date '+%Y-%m-%d %H:%M:%S') | refresh: ${INTERVAL}s | Ctrl+C to exit"
    echo -e "log: ${LOG_FILE}"
    echo ""

    PREV_TS="$(date +%s)"
    VPS1_DATA="$(collect_vps1)"
    VPS2_DATA="$(collect_vps2)"

    print_block_vps1 "$VPS1_DATA"
    echo ""
    print_block_vps2 "$VPS2_DATA"
    echo ""
    sleep "$INTERVAL"
done
