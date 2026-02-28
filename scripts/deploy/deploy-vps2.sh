#!/bin/bash
# =============================================================================
# Деплой только VPS2 (точка выхода: AmneziaWG туннель + AdGuard Home)
#
# Запускайте после deploy-vps1.sh. Требуется файл ключей (keys.env).
#
# Использование:
#   bash deploy-vps2.sh --vps2-ip IP --vps2-key KEY --keys-file ./vpn-output/keys.env [опции]
#
# Опции:
#   --vps2-ip       IP адрес VPS2
#   --vps2-user     Пользователь на VPS2 (default: root)
#   --vps2-key      Путь к SSH ключу для VPS2
#   --vps2-pass     Пароль для VPS2 (если нет ключа)
#   --keys-file     Путь к keys.env (создаётся deploy-vps1.sh)
#   --adguard-pass  Пароль AdGuard Home Web UI (обязательный, без дефолта)
#   --help          Справка
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
err()  { echo -e "${RED}✗ ОШИБКА:${NC} $*" >&2; exit 1; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
step() { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

VPS2_IP=""; VPS2_USER="root"; VPS2_KEY=""; VPS2_PASS=""
KEYS_FILE=""
ADGUARD_PASS=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECURITY_UPDATE_SCRIPT="${SCRIPT_DIR}/security-update.sh"
SECURITY_HARDEN_SCRIPT="${SCRIPT_DIR}/security-harden.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps2-ip)     VPS2_IP="$2";      shift 2 ;;
        --vps2-user)   VPS2_USER="$2";    shift 2 ;;
        --vps2-key)    VPS2_KEY="$2";     shift 2 ;;
        --vps2-pass)   VPS2_PASS="$2";    shift 2 ;;
        --keys-file)   KEYS_FILE="$2";    shift 2 ;;
        --adguard-pass) ADGUARD_PASS="$2"; shift 2 ;;
        --help|-h)
            sed -n '/^# Использование/,/^# ====/p' "$0" | grep -v "^# ====" | sed 's/^# \?//'
            exit 0 ;;
        *) err "Неизвестный параметр: $1" ;;
    esac
done

[[ -z "$VPS2_IP" ]] && err "Укажите --vps2-ip"
[[ -z "$KEYS_FILE" ]] && err "Укажите --keys-file (файл keys.env из deploy-vps1.sh)"
[[ -f "$KEYS_FILE" ]] || err "Файл ключей не найден: $KEYS_FILE"
[[ -z "$VPS2_KEY" && -z "$VPS2_PASS" ]] && err "Укажите --vps2-key или --vps2-pass"

# Загружаем ключи (игнорируем комментарии)
set -a
source <(grep -v '^#' "$KEYS_FILE" | grep '=' | tr -d '\r')
set +a

[[ -z "$VPS1_TUNNEL_PUB" || -z "$VPS2_TUNNEL_PRIV" ]] && err "В keys.env должны быть VPS1_TUNNEL_PUB и VPS2_TUNNEL_PRIV"

TUN_NET="${TUN_NET:-10.8.0}"
CLIENT_NET="${CLIENT_NET:-10.9.0}"
VPS2_PORT="${VPS2_PORT:-51820}"

ssh_cmd() {
    local ip=$1; local user=$2; local key=$3; local pass=$4
    local opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=no"
    if [[ -n "$key" ]]; then
        echo "ssh -T -i $key $opts ${user}@${ip}"
    else
        echo "sshpass -p '$pass' ssh -T $opts ${user}@${ip}"
    fi
}

run2() { eval "$(ssh_cmd $VPS2_IP $VPS2_USER "$VPS2_KEY" "$VPS2_PASS")" "$@" 2>&1; }

upload2() {
    local f=$1; local dst=${2:-/tmp/$(basename $f)}
    if [[ -n "$VPS2_KEY" ]]; then
        scp -i "$VPS2_KEY" -o StrictHostKeyChecking=accept-new "$f" "${VPS2_USER}@${VPS2_IP}:${dst}" 2>&1
    else
        sshpass -p "$VPS2_PASS" scp -o StrictHostKeyChecking=accept-new "$f" "${VPS2_USER}@${VPS2_IP}:${dst}" 2>&1
    fi
}

run_script2() {
    local script=$1; local tmp=$(mktemp /tmp/deploy_XXXX.sh)
    echo "$script" > "$tmp"; upload2 "$tmp" /tmp/_deploy_step.sh; rm "$tmp"
    run2 "sudo bash /tmp/_deploy_step.sh"
}

check_deps() {
    local missing=()
    command -v ssh  &>/dev/null || missing+=("ssh")
    command -v scp  &>/dev/null || missing+=("scp")
    command -v awk  &>/dev/null || missing+=("awk")
    [[ -n "$VPS2_PASS" ]] && { command -v sshpass &>/dev/null || missing+=("sshpass"); }
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Не хватает: ${missing[*]}"
    fi
    return 0
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Деплой VPS2 (точка выхода, туннель + AdGuard Home)        ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
log "VPS2: ${BOLD}${VPS2_USER}@${VPS2_IP}${NC}"
log "Ключи: ${KEYS_FILE}"
echo ""

check_deps
[[ -f "$SECURITY_UPDATE_SCRIPT" ]] || err "Не найден скрипт обновлений: $SECURITY_UPDATE_SCRIPT"
[[ -f "$SECURITY_HARDEN_SCRIPT" ]] || err "Не найден скрипт hardening: $SECURITY_HARDEN_SCRIPT"
[[ -z "$ADGUARD_PASS" ]] && err "Укажите --adguard-pass (пароль для AdGuard Home). Пароль admin123 запрещён."
[[ "$ADGUARD_PASS" == "admin123" ]] && err "Пароль admin123 слишком слабый. Укажите надёжный пароль через --adguard-pass"

step "Шаг 1/4: Проверка SSH к VPS2"
VPS2_OS=$(run2 "cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"'") \
    || err "Не удалось подключиться к VPS2 (${VPS2_IP})"
ok "VPS2: $VPS2_OS"

step "Шаг 2/4: Обновления безопасности на VPS2"
upload2 "$SECURITY_UPDATE_SCRIPT" /tmp/security-update.sh >/dev/null
run2 "sudo bash /tmp/security-update.sh" | tail -6
ok "Обновления безопасности применены на VPS2"

step "Шаг 2.5/4: Security hardening на VPS2"
upload2 "$SECURITY_HARDEN_SCRIPT" /tmp/security-harden.sh >/dev/null
run2 "sudo bash /tmp/security-harden.sh --role vps2 --vpn-port ${VPS2_PORT} --vpn-net ${TUN_NET}.0/24 --client-net ${CLIENT_NET}.0/24 --adguard-bind ${TUN_NET}.2" | tail -12
ok "VPS2 hardening завершён"

step "Шаг 3/4: Установка и настройка AmneziaWG на VPS2"
INSTALL_AWG='
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1
apt-get -qq update
apt-get -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install software-properties-common openresolv
add-apt-repository -y ppa:amnezia/ppa 2>/dev/null
apt-get -qq update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install amneziawg amneziawg-tools
modprobe amneziawg 2>/dev/null || true
awg --version
'
run_script2 "$INSTALL_AWG" | tail -3
ok "AmneziaWG установлен"

run_script2 "
MAIN_IF=\$(ip route | grep default | awk '{print \$5}' | head -1)
mkdir -p /etc/amnezia/amneziawg

cat > /etc/amnezia/amneziawg/awg0.conf << WGEOF
[Interface]
Address = ${TUN_NET}.2/24
MTU = 1420
PrivateKey = ${VPS2_TUNNEL_PRIV}
ListenPort = ${VPS2_PORT}

PostUp   = iptables -t nat -A POSTROUTING -s ${TUN_NET}.0/24 -o \${MAIN_IF} -j MASQUERADE
PostUp   = iptables -t nat -A POSTROUTING -s ${CLIENT_NET}.0/24 -o \${MAIN_IF} -j MASQUERADE
PostUp   = iptables -A FORWARD -i awg0 -o \${MAIN_IF} -j ACCEPT
PostUp   = iptables -A FORWARD -i \${MAIN_IF} -o awg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostUp   = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1320
PostDown = iptables -t nat -D POSTROUTING -s ${TUN_NET}.0/24 -o \${MAIN_IF} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${CLIENT_NET}.0/24 -o \${MAIN_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i awg0 -o \${MAIN_IF} -j ACCEPT
PostDown = iptables -D FORWARD -i \${MAIN_IF} -o awg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1320

[Peer]
PublicKey  = ${VPS1_TUNNEL_PUB}
AllowedIPs = ${TUN_NET}.1/32, ${CLIENT_NET}.0/24
PersistentKeepalive = 60
WGEOF

chmod 600 /etc/amnezia/amneziawg/awg0.conf

cat > /etc/systemd/system/awg-quick@.service << 'SVCEOF'
[Unit]
Description=AmneziaWG via awg-quick(8) for %I
After=network-online.target nss-lookup.target
Wants=network-online.target nss-lookup.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/awg-quick up %i
ExecStop=/usr/bin/awg-quick down %i
Environment=WG_ENDPOINT_RESOLUTION_RETRIES=infinity
[Install]
WantedBy=multi-user.target
SVCEOF

sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
sysctl -w net.core.rmem_max=67108864
sysctl -w net.core.wmem_max=67108864
sysctl -w net.core.netdev_max_backlog=16384
sysctl -w net.netfilter.nf_conntrack_max=524288 2>/dev/null || true
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true
sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
sysctl -w net.ipv4.tcp_rmem='4096 131072 16777216' 2>/dev/null || true
sysctl -w net.ipv4.tcp_wmem='4096 65536 16777216' 2>/dev/null || true
sysctl -w net.core.rmem_default=1048576 2>/dev/null || true
sysctl -w net.core.wmem_default=1048576 2>/dev/null || true
sysctl -w net.core.somaxconn=4096 2>/dev/null || true
sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null || true
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 2>/dev/null || true
sysctl -w net.ipv4.tcp_mtu_probing=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_timestamps=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_sack=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_window_scaling=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_no_metrics_save=1 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=7200 2>/dev/null || true
sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
sysctl -w net.ipv4.conf.default.rp_filter=0 2>/dev/null || true
cat > /etc/sysctl.d/99-vpn.conf << 'SYSCTLEOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.netdev_max_backlog=16384
net.netfilter.nf_conntrack_max=524288
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_rmem=4096 131072 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.core.somaxconn=4096
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_no_metrics_save=1
net.netfilter.nf_conntrack_tcp_timeout_established=7200
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
SYSCTLEOF
systemctl daemon-reload
systemctl enable awg-quick@awg0
systemctl restart awg-quick@awg0
sleep 2
awg show awg0
echo VPS2_AWG_OK
"
ok "VPS2 (awg0) настроен"

step "Шаг 4/4: Установка AdGuard Home на VPS2"

AGH_PASS_HASH=$(python3 -c "
import bcrypt, sys
pw = sys.argv[1].encode()
print(bcrypt.hashpw(pw, bcrypt.gensalt(10)).decode())
" "$ADGUARD_PASS" 2>/dev/null) || \
err "Не удалось сгенерировать bcrypt-хэш пароля. Установите python3-bcrypt: pip3 install bcrypt"

run_script2 "
export DEBIAN_FRONTEND=noninteractive
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/adguard.conf << 'EOF'
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
EOF
systemctl restart systemd-resolved 2>/dev/null || true
sleep 1

cd /tmp
curl -fsSL https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz -o agh.tar.gz
tar -xzf agh.tar.gz
cd AdGuardHome
./AdGuardHome -s install 2>/dev/null || true
sleep 2
/opt/AdGuardHome/AdGuardHome -s stop 2>/dev/null || true
sleep 1

cat > /opt/AdGuardHome/AdGuardHome.yaml << 'AGHEOF'
http:
  address: ${TUN_NET}.2:3000
users:
  - name: admin
    password: '${AGH_PASS_HASH}'
dns:
  bind_hosts:
    - ${TUN_NET}.2
    - 127.0.0.1
  port: 53
  upstream_dns:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
    - tls://1.1.1.1
    - tls://8.8.8.8
  bootstrap_dns:
    - 9.9.9.10
    - 149.112.112.10
  upstream_mode: load_balance
  cache_size: 4194304
  enable_dnssec: true
  refuse_any: true
  ratelimit: 20
filtering:
  filtering_enabled: true
  protection_enabled: true
  filters_update_interval: 24
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
    name: AdAway Default Blocklist
    id: 2
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_4.txt
    name: Dan Pollock's List
    id: 4
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_24.txt
    name: NoCoin Filter List
    id: 24
querylog:
  interval: 2160h
  enabled: true
  file_enabled: true
statistics:
  interval: 2160h
  enabled: true
schema_version: 28
AGHEOF

/opt/AdGuardHome/AdGuardHome -s start
sleep 3
/opt/AdGuardHome/AdGuardHome -s status
echo AGH_OK
"
ok "AdGuard Home установлен"

echo ""
echo -e "${BOLD}Деплой VPS2 завершён.${NC}"
echo ""
echo -e "  ${GREEN}AdGuard Home:${NC} http://${VPS2_IP}:3000"
echo -e "  Логин: admin, пароль: ${ADGUARD_PASS}"
echo ""
