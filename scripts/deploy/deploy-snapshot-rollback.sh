#!/usr/bin/env bash
# =============================================================================
# deploy-snapshot-rollback.sh — pre-deploy snapshot and emergency rollback
#
# Usage:
#   bash scripts/deploy/deploy-snapshot-rollback.sh snapshot
#   bash scripts/deploy/deploy-snapshot-rollback.sh rollback --snapshot-id ID
#   bash scripts/deploy/deploy-snapshot-rollback.sh status
#
# Scope:
#   - local vpn-output snapshot
#   - VPS1/VPS2 VPN configs, service states, firewall state, DNS services
#   - split-tunneling files/state when present
#
# Does not roll back OS package versions installed by apt.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"

ACTION="${1:-}"
[[ -n "$ACTION" ]] && shift || true

SNAPSHOT_ID=""
SNAPSHOT_ROOT="/root/vpn-predeploy-snapshots"
LOCAL_SNAPSHOT_ROOT="${PROJECT_ROOT}/vpn-output/deploy-snapshots"

VPS1_IP=""; VPS1_USER=""; VPS1_KEY=""; VPS1_PASS=""
VPS2_IP=""; VPS2_USER=""; VPS2_KEY=""; VPS2_PASS=""

usage() {
    cat <<EOF
Usage:
  bash scripts/deploy/deploy-snapshot-rollback.sh snapshot [options]
  bash scripts/deploy/deploy-snapshot-rollback.sh rollback --snapshot-id ID [options]
  bash scripts/deploy/deploy-snapshot-rollback.sh status [options]

Options:
  --snapshot-id ID       Snapshot id. Defaults to timestamp for snapshot.
  --snapshot-root DIR    Remote root directory. Default: /root/vpn-predeploy-snapshots
  --vps1-ip IP           Override VPS1_IP
  --vps1-user USER       Override VPS1_USER
  --vps1-key KEY         Override VPS1_KEY
  --vps1-pass PASS       Override VPS1_PASS
  --vps2-ip IP           Override VPS2_IP
  --vps2-user USER       Override VPS2_USER
  --vps2-key KEY         Override VPS2_KEY
  --vps2-pass PASS       Override VPS2_PASS
EOF
}

require_option_value() {
    local opt="$1" value="${2:-}"
    [[ -n "$value" && "$value" != --* ]] || err "$opt requires a value"
}

case "$ACTION" in
    snapshot|rollback|status|--help|-h) ;;
    "") usage; exit 1 ;;
    *) err "Unknown action: $ACTION" ;;
esac

if [[ "$ACTION" == "--help" || "$ACTION" == "-h" ]]; then
    usage
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --snapshot-id)   require_option_value "$1" "${2:-}"; SNAPSHOT_ID="$2"; shift 2 ;;
        --snapshot-root) require_option_value "$1" "${2:-}"; SNAPSHOT_ROOT="$2"; shift 2 ;;
        --vps1-ip)       require_option_value "$1" "${2:-}"; VPS1_IP="$2"; shift 2 ;;
        --vps1-user)     require_option_value "$1" "${2:-}"; VPS1_USER="$2"; shift 2 ;;
        --vps1-key)      require_option_value "$1" "${2:-}"; VPS1_KEY="$2"; shift 2 ;;
        --vps1-pass)     require_option_value "$1" "${2:-}"; VPS1_PASS="$2"; shift 2 ;;
        --vps2-ip)       require_option_value "$1" "${2:-}"; VPS2_IP="$2"; shift 2 ;;
        --vps2-user)     require_option_value "$1" "${2:-}"; VPS2_USER="$2"; shift 2 ;;
        --vps2-key)      require_option_value "$1" "${2:-}"; VPS2_KEY="$2"; shift 2 ;;
        --vps2-pass)     require_option_value "$1" "${2:-}"; VPS2_PASS="$2"; shift 2 ;;
        --help|-h)       usage; exit 0 ;;
        *) err "Unknown option: $1" ;;
    esac
done

load_defaults_from_files

if [[ "$ACTION" != "status" ]]; then
    VPS1_USER="${VPS1_USER:-root}"
    VPS2_USER="${VPS2_USER:-root}"

    VPS1_KEY="$(expand_tilde "$VPS1_KEY")"
    VPS2_KEY="$(expand_tilde "$VPS2_KEY")"
    [[ -z "$VPS1_PASS" ]] && VPS1_KEY="$(auto_pick_key_if_missing "$VPS1_KEY")"
    [[ -z "$VPS2_PASS" ]] && VPS2_KEY="$(auto_pick_key_if_missing "$VPS2_KEY")"
    VPS1_KEY="$(prepare_key_for_ssh "$VPS1_KEY")"
    VPS2_KEY="$(prepare_key_for_ssh "$VPS2_KEY")"
    trap cleanup_temp_keys EXIT
fi

if [[ "$ACTION" == "snapshot" && -z "$SNAPSHOT_ID" ]]; then
    SNAPSHOT_ID="$(date +%Y%m%d-%H%M%S)"
fi

if [[ "$ACTION" == "rollback" && -z "$SNAPSHOT_ID" ]]; then
    err "rollback requires --snapshot-id"
fi

if [[ "$ACTION" != "status" ]]; then
    [[ "$SNAPSHOT_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || err "Invalid --snapshot-id: start with a letter/digit; use only letters, digits, dot, underscore, dash"
    [[ "$SNAPSHOT_ROOT" == /* ]] || err "--snapshot-root must be an absolute remote path"
    [[ "$SNAPSHOT_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] || err "--snapshot-root may contain only letters, digits, slash, dot, underscore, dash"
    [[ "$SNAPSHOT_ROOT" != *"/../"* && "$SNAPSHOT_ROOT" != */.. && "$SNAPSHOT_ROOT" != *"/./"* && "$SNAPSHOT_ROOT" != */. ]] || err "--snapshot-root must not contain dot path segments"
fi

if [[ "$ACTION" != "status" ]]; then
    require_vars "deploy-snapshot-rollback.sh" VPS1_IP VPS2_IP
    [[ -z "$VPS1_KEY" && -z "$VPS1_PASS" ]] && err "Provide VPS1 key/pass via .env or CLI"
    [[ -z "$VPS2_KEY" && -z "$VPS2_PASS" ]] && err "Provide VPS2 key/pass via .env or CLI"
fi

remote_run() {
    local role="$1" script="$2"
    if [[ "$role" == "vps1" ]]; then
        ssh_run_script "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS" "$script"
    else
        ssh_run_script "$VPS2_IP" "$VPS2_USER" "$VPS2_KEY" "$VPS2_PASS" "$script"
    fi
}

local_snapshot_dir() {
    printf "%s/%s" "$LOCAL_SNAPSHOT_ROOT" "$SNAPSHOT_ID"
}

snapshot_local() {
    local dir
    dir="$(local_snapshot_dir)"
    [[ ! -e "$dir" ]] || err "Snapshot already exists locally: ${dir}"
    mkdir -p "$dir"
    {
        echo "SNAPSHOT_ID=$SNAPSHOT_ID"
        echo "CREATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "VPS1_IP=$VPS1_IP"
        echo "VPS2_IP=$VPS2_IP"
        echo "REMOTE_ROOT=$SNAPSHOT_ROOT"
    } > "${dir}/manifest.env"

    if [[ -d "${PROJECT_ROOT}/vpn-output" ]]; then
        tar --exclude 'vpn-output/deploy-snapshots' \
            -czf "${dir}/local-vpn-output.tar.gz" \
            -C "$PROJECT_ROOT" vpn-output
    fi
    ok "Local snapshot saved: ${dir}"
}

restore_local() {
    local dir tarball tmp_tar backup_dir
    dir="$(local_snapshot_dir)"
    tarball="${dir}/local-vpn-output.tar.gz"
    [[ -f "$tarball" ]] || { warn "No local vpn-output snapshot found: $tarball"; return 0; }

    tmp_tar="$(mktemp /tmp/vpn-output-rollback-XXXX.tar.gz)"
    cp "$tarball" "$tmp_tar"
    backup_dir="${PROJECT_ROOT}/vpn-output.before-rollback.$(date +%Y%m%d-%H%M%S)"

    if [[ -d "${PROJECT_ROOT}/vpn-output" ]]; then
        mv "${PROJECT_ROOT}/vpn-output" "$backup_dir"
        warn "Current vpn-output moved to: ${backup_dir}"
    fi

    tar -xzf "$tmp_tar" -C "$PROJECT_ROOT"
    rm -f "$tmp_tar"
    ok "Local vpn-output restored from snapshot"
}

remote_snapshot_script() {
    local role="$1"
    cat <<REMOTE
set -euo pipefail
SNAPSHOT_ID="${SNAPSHOT_ID}"
SNAPSHOT_ROOT="${SNAPSHOT_ROOT}"
ROLE="${role}"
DEST="\${SNAPSHOT_ROOT}/\${SNAPSHOT_ID}/\${ROLE}"

mkdir -p "\${DEST}/state"
chmod 700 "\${SNAPSHOT_ROOT}" "\${SNAPSHOT_ROOT}/\${SNAPSHOT_ID}" "\${DEST}"

log() { echo "[snapshot:\${ROLE}] \$*"; logger -t vpn-deploy-snapshot -- "\$*" 2>/dev/null || true; }

log "writing manifest"
{
    echo "SNAPSHOT_ID=\${SNAPSHOT_ID}"
    echo "ROLE=\${ROLE}"
    echo "CREATED_AT=\$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "HOSTNAME=\$(hostname 2>/dev/null || true)"
    echo "KERNEL=\$(uname -sr 2>/dev/null || true)"
} > "\${DEST}/manifest.env"

log "recording service states"
for svc in awg-quick@awg0 awg-quick@awg1 AdGuardHome adguardhome youtube-proxy dnsmasq systemd-resolved ssh sshd fail2ban split-tunnel-restore.service split-tunnel-auto-rollback.timer; do
    systemctl is-active "\$svc" > "\${DEST}/state/\${svc}.active" 2>/dev/null || echo "inactive" > "\${DEST}/state/\${svc}.active"
    systemctl is-enabled "\$svc" > "\${DEST}/state/\${svc}.enabled" 2>/dev/null || echo "unknown" > "\${DEST}/state/\${svc}.enabled"
done

if ip rule show 2>/dev/null | grep -q 'fwmark 0x100.*lookup 100'; then
    echo 1 > "\${DEST}/state/split.active"
else
    echo 0 > "\${DEST}/state/split.active"
fi

log "saving firewall/routing state"
iptables-save > "\${DEST}/iptables-save.v4" 2>/dev/null || true
ip6tables-save > "\${DEST}/iptables-save.v6" 2>/dev/null || true
ip rule show > "\${DEST}/ip-rule.txt" 2>/dev/null || true
ip route show table all > "\${DEST}/ip-route-all.txt" 2>/dev/null || true
if command -v ipset >/dev/null 2>&1; then
    ipset save > "\${DEST}/ipset-save.txt" 2>/dev/null || true
else
    : > "\${DEST}/ipset-save.txt"
fi

log "collecting file list"
cat > "\${DEST}/file-list.candidates" <<'EOF'
etc/amnezia/amneziawg
etc/amnezia/keys
etc/systemd/system/awg-quick@.service
etc/systemd/system/AdGuardHome.service
etc/systemd/system/adguardhome.service
etc/systemd/system/youtube-proxy.service
etc/sysctl.d/99-vpn.conf
etc/systemd/resolved.conf.d/adguard.conf
etc/resolv.conf
etc/hosts
etc/ssh/sshd_config
etc/ssh/sshd_config.d
etc/fail2ban
etc/apt/apt.conf.d/20auto-upgrades
etc/apt/apt.conf.d/50unattended-upgrades
etc/rkhunter.conf
opt/AdGuardHome
opt/youtube-proxy
etc/dnsmasq.conf
etc/dnsmasq.conf.bak.pre-split-tunneling
etc/dnsmasq.d
etc/systemd/system/dnsmasq.service.d
etc/systemd/system/split-tunnel-restore.service
usr/local/sbin/split-tunnel-apply.sh
usr/local/sbin/split-tunnel-rollback.sh
usr/local/sbin/restore-vpn-routing.sh
etc/iptables/rules.v4
etc/iptables/rules.v6
etc/vpn-last-deploy.ts
EOF

cat > "\${DEST}/file-list.managed-remove-if-absent" <<'EOF'
etc/systemd/system/AdGuardHome.service
etc/systemd/system/adguardhome.service
etc/systemd/system/youtube-proxy.service
etc/systemd/resolved.conf.d/adguard.conf
opt/AdGuardHome
opt/youtube-proxy
etc/dnsmasq.conf
etc/dnsmasq.conf.bak.pre-split-tunneling
etc/dnsmasq.d/vpn.conf
etc/systemd/system/dnsmasq.service.d/override.conf
etc/systemd/system/split-tunnel-restore.service
usr/local/sbin/split-tunnel-apply.sh
usr/local/sbin/split-tunnel-rollback.sh
usr/local/sbin/restore-vpn-routing.sh
etc/iptables/rules.v4
etc/iptables/rules.v6
etc/vpn-last-deploy.ts
EOF

: > "\${DEST}/file-list.existing"
while IFS= read -r p; do
    [ -e "/\$p" ] && printf '%s\n' "\$p" >> "\${DEST}/file-list.existing"
done < "\${DEST}/file-list.candidates"

if [ -s "\${DEST}/file-list.existing" ]; then
    log "creating files.tar.gz"
    tar -C / -czf "\${DEST}/files.tar.gz" -T "\${DEST}/file-list.existing"
else
    log "no files matched snapshot list"
    : > "\${DEST}/files.empty"
fi

log "snapshot complete: \${DEST}"
REMOTE
}

remote_rollback_script() {
    local role="$1"
    cat <<REMOTE
set -euo pipefail
SNAPSHOT_ID="${SNAPSHOT_ID}"
SNAPSHOT_ROOT="${SNAPSHOT_ROOT}"
ROLE="${role}"
DEST="\${SNAPSHOT_ROOT}/\${SNAPSHOT_ID}/\${ROLE}"

[ -d "\${DEST}" ] || { echo "[rollback:\${ROLE}] missing snapshot dir: \${DEST}" >&2; exit 1; }

log() { echo "[rollback:\${ROLE}] \$*"; logger -t vpn-deploy-rollback -- "\$*" 2>/dev/null || true; }
state() { cat "\${DEST}/state/\$1.\$2" 2>/dev/null || echo "unknown"; }

restore_service() {
    local svc="\$1" active enabled
    active="\$(state "\$svc" active)"
    enabled="\$(state "\$svc" enabled)"

    case "\$enabled" in
        enabled) systemctl enable "\$svc" 2>/dev/null || true ;;
        disabled) systemctl disable "\$svc" 2>/dev/null || true ;;
    esac

    if [ "\$active" = "active" ]; then
        systemctl start "\$svc" 2>/dev/null || true
    else
        systemctl stop "\$svc" 2>/dev/null || true
    fi
}

restore_adguard_service() {
    local upper_active lower_active upper_enabled lower_enabled
    upper_active="\$(state AdGuardHome active)"
    lower_active="\$(state adguardhome active)"
    upper_enabled="\$(state AdGuardHome enabled)"
    lower_enabled="\$(state adguardhome enabled)"

    if [ "\$upper_enabled" = "enabled" ]; then
        systemctl enable AdGuardHome 2>/dev/null || true
    elif [ "\$lower_enabled" = "enabled" ]; then
        systemctl enable adguardhome 2>/dev/null || true
    else
        systemctl disable AdGuardHome 2>/dev/null || true
        systemctl disable adguardhome 2>/dev/null || true
    fi

    if [ "\$upper_active" = "active" ]; then
        systemctl start AdGuardHome 2>/dev/null || true
    elif [ "\$lower_active" = "active" ]; then
        systemctl start adguardhome 2>/dev/null || true
    else
        systemctl stop AdGuardHome 2>/dev/null || true
        systemctl stop adguardhome 2>/dev/null || true
    fi
}

reload_ssh_runtime() {
    if command -v sshd >/dev/null 2>&1 && ! sshd -t 2>/dev/null; then
        log "restored SSH config did not pass sshd -t; skipping SSH reload"
        return 0
    fi

    if [ "\$(state sshd active)" = "active" ]; then
        systemctl reload sshd 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    elif [ "\$(state ssh active)" = "active" ]; then
        systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    else
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    fi
}

remove_rule_by_awk_match() {
    local awk_expr="\$1" fallback_args="\$2" pref
    while ip rule show | awk "\$awk_expr" | grep -q .; do
        pref="\$(ip rule show | awk "\$awk_expr" | head -1)"
        if [ -n "\$pref" ]; then
            ip rule del pref "\$pref" 2>/dev/null || eval "ip rule del \$fallback_args" 2>/dev/null || break
        else
            eval "ip rule del \$fallback_args" 2>/dev/null || break
        fi
    done
}

cleanup_split_runtime_state_if_absent() {
    local snapshot_split_active
    [ "\$ROLE" = "vps1" ] || return 0
    snapshot_split_active="\$(cat "\${DEST}/state/split.active" 2>/dev/null || echo 0)"
    [ "\$snapshot_split_active" = "1" ] && return 0

    log "snapshot had split tunneling inactive; removing split runtime state"

    remove_rule_by_awk_match \
        '\$0 ~ /fwmark 0x100/ && \$0 ~ /lookup 100/ {sub(/:.*/, "", \$1); print \$1}' \
        'fwmark 0x100 table 100'

    remove_rule_by_awk_match \
        '\$0 ~ /from 10[.]9[.]0[.]1/ && \$0 ~ /to 10[.]9[.]0[.]0\\/24/ && \$0 ~ /lookup main/ {sub(/:.*/, "", \$1); print \$1}' \
        'from 10.9.0.1/32 to 10.9.0.0/24 table main'

    ip route flush table 100 2>/dev/null || true
    ip route flush cache 2>/dev/null || true

    if command -v ipset >/dev/null 2>&1 && ! grep -qE '^create[[:space:]]+ru_subnets([[:space:]]|$)' "\${DEST}/ipset-save.txt" 2>/dev/null; then
        ipset destroy ru_subnets 2>/dev/null || true
    fi
}

log "stopping mutable services before restore"
systemctl stop split-tunnel-auto-rollback.timer 2>/dev/null || true
systemctl stop split-tunnel-restore.service 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
systemctl stop AdGuardHome 2>/dev/null || true
systemctl stop adguardhome 2>/dev/null || true
systemctl stop youtube-proxy 2>/dev/null || true
systemctl stop awg-quick@awg1 2>/dev/null || true
systemctl stop awg-quick@awg0 2>/dev/null || true

if [ -f "\${DEST}/file-list.managed-remove-if-absent" ] && [ -f "\${DEST}/file-list.existing" ]; then
    log "removing managed paths absent from snapshot"
    while IFS= read -r p; do
        [ -n "\$p" ] || continue
        if ! grep -Fxq "\$p" "\${DEST}/file-list.existing"; then
            rm -rf "/\$p"
        fi
    done < "\${DEST}/file-list.managed-remove-if-absent"
fi

if [ -f "\${DEST}/files.tar.gz" ]; then
    log "restoring filesystem snapshot"
    tar -C / -xzf "\${DEST}/files.tar.gz"
fi

systemctl daemon-reload 2>/dev/null || true
sysctl --system >/dev/null 2>&1 || true

if command -v ipset >/dev/null 2>&1 && [ -s "\${DEST}/ipset-save.txt" ]; then
    log "restoring ipset state"
    ipset restore -exist < "\${DEST}/ipset-save.txt" 2>/dev/null || true
fi

log "restoring service states"
reload_ssh_runtime
restore_service fail2ban
restore_service systemd-resolved
restore_service awg-quick@awg0
restore_service awg-quick@awg1
restore_adguard_service
restore_service youtube-proxy
restore_service dnsmasq
restore_service split-tunnel-restore.service
restore_service split-tunnel-auto-rollback.timer

if [ "\$(cat "\${DEST}/state/split.active" 2>/dev/null || echo 0)" = "1" ] && [ -x /usr/local/sbin/split-tunnel-apply.sh ]; then
    log "snapshot had split tunneling active; re-applying split rules"
    bash /usr/local/sbin/split-tunnel-apply.sh 2>/dev/null || true
elif [ "\$(cat "\${DEST}/state/split.active" 2>/dev/null || echo 0)" != "1" ] && [ -x /usr/local/sbin/split-tunnel-rollback.sh ]; then
    log "snapshot had split tunneling inactive; ensuring split rules are removed"
    bash /usr/local/sbin/split-tunnel-rollback.sh 2>/dev/null || true
fi

cleanup_split_runtime_state_if_absent

if [ -s "\${DEST}/iptables-save.v4" ]; then
    log "restoring final IPv4 firewall state"
    iptables-restore < "\${DEST}/iptables-save.v4" 2>/dev/null || true
fi
if [ -s "\${DEST}/iptables-save.v6" ]; then
    log "restoring final IPv6 firewall state"
    ip6tables-restore < "\${DEST}/iptables-save.v6" 2>/dev/null || true
fi

log "rollback completed"
REMOTE
}

snapshot_remote() {
    local role="$1"
    step "Remote snapshot: ${role}"
    remote_run "$role" "$(remote_snapshot_script "$role")"
}

rollback_remote() {
    local role="$1"
    step "Remote rollback: ${role}"
    remote_run "$role" "$(remote_rollback_script "$role")"
}

status_local() {
    step "Local deploy snapshots"
    if [[ -d "$LOCAL_SNAPSHOT_ROOT" ]]; then
        find "$LOCAL_SNAPSHOT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | sort
    else
        warn "No local snapshot dir: $LOCAL_SNAPSHOT_ROOT"
    fi
}

case "$ACTION" in
    snapshot)
        step "Creating pre-deploy snapshot: ${SNAPSHOT_ID}"
        snapshot_local
        snapshot_remote vps1
        snapshot_remote vps2
        ok "Snapshot ready: ${SNAPSHOT_ID}"
        echo "Rollback command:"
        echo "  bash scripts/deploy/deploy-snapshot-rollback.sh rollback --snapshot-id ${SNAPSHOT_ID}"
        ;;
    rollback)
        [[ -n "$SNAPSHOT_ID" ]] || err "rollback requires --snapshot-id"
        step "Rolling back to snapshot: ${SNAPSHOT_ID}"
        rollback_remote vps1
        rollback_remote vps2
        restore_local
        ok "Rollback finished: ${SNAPSHOT_ID}"
        ;;
    status)
        status_local
        ;;
esac
