#!/usr/bin/env bash
# =============================================================================
# rollback-split-tunneling.sh - emergency local rollback for VPS1 split tunnel
#
# Runs from the control machine. It does not require the remote rollback script
# to exist: the rollback logic is sent inline over SSH.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${PROJECT_ROOT}/lib/common.sh"

VPS1_IP=""; VPS1_USER=""; VPS1_KEY=""; VPS1_PASS=""
TUN_NET=""; CLIENT_NET=""
MARK_HEX="0x100"
ROUTE_TABLE="100"
DNS_REPLY_RULE_PRIORITY="90"
IPSET_NAME="ru_subnets"
WATCHDOG_UNIT="split-tunnel-auto-rollback"

load_defaults_from_files

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps1-ip)   VPS1_IP="$2";   shift 2 ;;
        --vps1-user) VPS1_USER="$2"; shift 2 ;;
        --vps1-key)  VPS1_KEY="$2";  shift 2 ;;
        --vps1-pass) VPS1_PASS="$2"; shift 2 ;;
        --tun-net)   TUN_NET="$2";   shift 2 ;;
        --client-net) CLIENT_NET="$2"; shift 2 ;;
        --help|-h)
            cat <<EOF
Usage: bash $0 [options]

Emergency rollback for VPS1 split tunneling.

Options:
  --vps1-ip IP
  --vps1-user USER
  --vps1-key KEY
  --vps1-pass PASS
  --tun-net NET       default: 10.8.0
  --client-net NET    default: 10.9.0
EOF
            exit 0 ;;
        *) err "Unknown option: $1" ;;
    esac
done

VPS1_USER="${VPS1_USER:-root}"
TUN_NET="${TUN_NET:-10.8.0}"
CLIENT_NET="${CLIENT_NET:-10.9.0}"

VPS1_KEY="$(expand_tilde "$VPS1_KEY")"
VPS1_KEY="$(auto_pick_key_if_missing "$VPS1_KEY")"
VPS1_KEY="$(prepare_key_for_ssh "$VPS1_KEY")"

require_vars "rollback-split-tunneling.sh" VPS1_IP
[[ -z "$VPS1_KEY" && -z "$VPS1_PASS" ]] && err "Provide --vps1-key or --vps1-pass, or set VPS1_KEY/VPS1_PASS in .env"

trap cleanup_temp_keys EXIT

remote_script() { ssh_run_script "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS" "$1"; }

step "Emergency rollback split tunneling on VPS1 (${VPS1_IP})"

if ! ROLLBACK_OUTPUT="$(remote_script "$(cat <<REMOTE_ROLLBACK
set -uo pipefail

CLIENT_NET="${CLIENT_NET}"
TUN_NET="${TUN_NET}"
DNSMASQ_IP="\${CLIENT_NET}.1"
VPS2_DNS_IP="\${TUN_NET}.2"
MARK_HEX="${MARK_HEX}"
ROUTE_TABLE="${ROUTE_TABLE}"
DNS_REPLY_RULE_PRIORITY="${DNS_REPLY_RULE_PRIORITY}"
IPSET_NAME="${IPSET_NAME}"
WATCHDOG_UNIT="${WATCHDOG_UNIT}"
CLIENT_CIDR="\${CLIENT_NET}.0/24"

log() { echo "[rollback] \$*"; logger -t rollback-split-tunneling -- "\$*" 2>/dev/null || true; }

ipt_drop_all() {
    local table="\$1" chain="\$2"; shift 2
    while iptables -t "\$table" -C "\$chain" "\$@" 2>/dev/null; do
        iptables -t "\$table" -D "\$chain" "\$@" 2>/dev/null || break
    done
}

MAIN_IF="\$(ip route show default 2>/dev/null | awk '/^default/ {print \$5; exit}')"

log "stop watchdog timer and split restore units"
systemctl stop "\${WATCHDOG_UNIT}.timer" 2>/dev/null || true
systemctl reset-failed "\${WATCHDOG_UNIT}.timer" "\${WATCHDOG_UNIT}.service" 2>/dev/null || true
systemctl disable split-tunnel-restore.service 2>/dev/null || true

log "restore DNS DNAT to VPS2 DNS \${VPS2_DNS_IP}:53"
iptables -t nat -C PREROUTING -i awg1 -p udp --dport 53 -j DNAT --to-destination "\${VPS2_DNS_IP}:53" 2>/dev/null \
  || iptables -t nat -I PREROUTING 1 -i awg1 -p udp --dport 53 -j DNAT --to-destination "\${VPS2_DNS_IP}:53"
iptables -t nat -C PREROUTING -i awg1 -p tcp --dport 53 -j DNAT --to-destination "\${VPS2_DNS_IP}:53" 2>/dev/null \
  || iptables -t nat -I PREROUTING 1 -i awg1 -p tcp --dport 53 -j DNAT --to-destination "\${VPS2_DNS_IP}:53"

log "remove DNS DNAT to local dnsmasq \${DNSMASQ_IP}:53"
ipt_drop_all nat PREROUTING -i awg1 -p udp --dport 53 -j DNAT --to-destination "\${DNSMASQ_IP}:53"
ipt_drop_all nat PREROUTING -i awg1 -p tcp --dport 53 -j DNAT --to-destination "\${DNSMASQ_IP}:53"
ipt_drop_all nat POSTROUTING -o awg1 -s "\${DNSMASQ_IP}/32" -d "\$CLIENT_CIDR" -p udp --sport 53 -j SNAT --to-source "\$VPS2_DNS_IP"
ipt_drop_all nat POSTROUTING -o awg1 -s "\${DNSMASQ_IP}/32" -d "\$CLIENT_CIDR" -p tcp --sport 53 -j SNAT --to-source "\$VPS2_DNS_IP"
ipt_drop_all filter INPUT -i awg1 -d "\$DNSMASQ_IP" -p udp --dport 53 -j ACCEPT
ipt_drop_all filter INPUT -i awg1 -d "\$DNSMASQ_IP" -p tcp --dport 53 -j ACCEPT

while ip rule show | grep -Fq "from \${DNSMASQ_IP} to \${CLIENT_CIDR} lookup main"; do
    pref="\$(ip rule show | awk -v src="\$DNSMASQ_IP" -v dst="\$CLIENT_CIDR" '\$0 ~ "from " src && \$0 ~ "to " dst && \$0 ~ "lookup main" {sub(/:.*/, "", \$1); print \$1; exit}')"
    if [ -n "\$pref" ]; then
        ip rule del pref "\$pref" 2>/dev/null || ip rule del from "\${DNSMASQ_IP}/32" to "\$CLIENT_CIDR" table main 2>/dev/null || break
    else
        ip rule del from "\${DNSMASQ_IP}/32" to "\$CLIENT_CIDR" table main 2>/dev/null || break
    fi
done
ip route flush cache 2>/dev/null || true

if [ -n "\$MAIN_IF" ]; then
    log "remove split FORWARD and MASQUERADE rules via \$MAIN_IF"
    ipt_drop_all filter FORWARD -i awg1 -o "\$MAIN_IF" -m mark --mark "\$MARK_HEX" -j ACCEPT
    ipt_drop_all filter FORWARD -i "\$MAIN_IF" -o awg1 -m state --state RELATED,ESTABLISHED -j ACCEPT
    ipt_drop_all nat POSTROUTING -s "\$CLIENT_CIDR" -o "\$MAIN_IF" -j MASQUERADE
fi

log "remove mangle marks"
ipt_drop_all mangle PREROUTING -i awg1 -m conntrack --ctstate ESTABLISHED,RELATED -j CONNMARK --restore-mark
ipt_drop_all mangle PREROUTING -i awg1 -m conntrack --ctstate NEW -m set --match-set "\$IPSET_NAME" dst -j MARK --set-mark "\$MARK_HEX"
ipt_drop_all mangle PREROUTING -i awg1 -m conntrack --ctstate NEW -j CONNMARK --save-mark

log "remove policy routing table \$ROUTE_TABLE"
while ip rule show | grep -q "fwmark \$MARK_HEX lookup \$ROUTE_TABLE"; do
    pref="\$(ip rule show | awk -v mark="\$MARK_HEX" -v tbl="\$ROUTE_TABLE" '\$0 ~ "fwmark " mark && \$0 ~ "lookup " tbl {sub(/:.*/, "", \$1); print \$1; exit}')"
    if [ -n "\$pref" ]; then
        ip rule del pref "\$pref" 2>/dev/null || ip rule del fwmark "\$MARK_HEX" table "\$ROUTE_TABLE" 2>/dev/null || break
    else
        ip rule del fwmark "\$MARK_HEX" table "\$ROUTE_TABLE" 2>/dev/null || break
    fi
done
ip route flush table "\$ROUTE_TABLE" 2>/dev/null || true

log "destroy ipset and stop dnsmasq"
if command -v ipset >/dev/null 2>&1; then
    ipset destroy "\$IPSET_NAME" 2>/dev/null || true
fi
systemctl stop dnsmasq 2>/dev/null || true
systemctl unmask dnsmasq 2>/dev/null || true

log "verify restored full-tunnel state"
FAIL=0
iptables -t nat -C PREROUTING -i awg1 -p udp --dport 53 -j DNAT --to-destination "\${VPS2_DNS_IP}:53" 2>/dev/null || { echo "verify: missing UDP DNAT to \${VPS2_DNS_IP}:53"; FAIL=1; }
iptables -t nat -C PREROUTING -i awg1 -p tcp --dport 53 -j DNAT --to-destination "\${VPS2_DNS_IP}:53" 2>/dev/null || { echo "verify: missing TCP DNAT to \${VPS2_DNS_IP}:53"; FAIL=1; }
if ip rule show | grep -q "fwmark \$MARK_HEX lookup \$ROUTE_TABLE"; then echo "verify: fwmark rule still exists"; FAIL=1; fi
if ip rule show | grep -Fq "from \${DNSMASQ_IP} to \${CLIENT_CIDR} lookup main"; then echo "verify: DNS reply rule still exists"; FAIL=1; fi
if ip route show table "\$ROUTE_TABLE" 2>/dev/null | grep -q .; then echo "verify: table \$ROUTE_TABLE is not empty"; FAIL=1; fi
if command -v ipset >/dev/null 2>&1 && ipset list "\$IPSET_NAME" >/dev/null 2>&1; then echo "verify: ipset \$IPSET_NAME still exists"; FAIL=1; fi
if [ -n "\$MAIN_IF" ]; then
    iptables -C FORWARD -i awg1 -o "\$MAIN_IF" -m mark --mark "\$MARK_HEX" -j ACCEPT 2>/dev/null && { echo "verify: split FORWARD rule still exists"; FAIL=1; }
    iptables -t nat -C POSTROUTING -s "\$CLIENT_CIDR" -o "\$MAIN_IF" -j MASQUERADE 2>/dev/null && { echo "verify: split MASQUERADE still exists"; FAIL=1; }
fi
iptables -t nat -C POSTROUTING -o awg1 -s "\${DNSMASQ_IP}/32" -d "\$CLIENT_CIDR" -p udp --sport 53 -j SNAT --to-source "\$VPS2_DNS_IP" 2>/dev/null && { echo "verify: DNS reply SNAT UDP still exists"; FAIL=1; }
iptables -t nat -C POSTROUTING -o awg1 -s "\${DNSMASQ_IP}/32" -d "\$CLIENT_CIDR" -p tcp --sport 53 -j SNAT --to-source "\$VPS2_DNS_IP" 2>/dev/null && { echo "verify: DNS reply SNAT TCP still exists"; FAIL=1; }
iptables -C INPUT -i awg1 -d "\$DNSMASQ_IP" -p udp --dport 53 -j ACCEPT 2>/dev/null && { echo "verify: DNS INPUT UDP still exists"; FAIL=1; }
iptables -C INPUT -i awg1 -d "\$DNSMASQ_IP" -p tcp --dport 53 -j ACCEPT 2>/dev/null && { echo "verify: DNS INPUT TCP still exists"; FAIL=1; }
dig +time=3 +tries=1 @"\$VPS2_DNS_IP" google.com +short | grep -E '^[0-9]+\\.' >/dev/null 2>&1 || { echo "verify: VPS2 DNS does not resolve google.com"; FAIL=1; }

if [ "\$FAIL" -ne 0 ]; then
    log "rollback verification FAILED"
    exit 1
fi

log "rollback verification OK"
exit 0
REMOTE_ROLLBACK
)")"; then
    echo "${ROLLBACK_OUTPUT:-}"
    err "Emergency rollback failed on VPS1; see remote output above"
fi

echo "$ROLLBACK_OUTPUT"
ok "Emergency rollback completed and verified"
