#!/bin/bash
# =============================================================================
# security-harden.sh — комплексный hardening VPS-серверов
#
# Устанавливает и настраивает:
#   1. fail2ban          — защита SSH от брутфорса
#   2. unattended-upgrades — автоматические security-обновления
#   3. SSH hardening      — запрет паролей, ограничение root, лимит попыток
#   4. iptables hardening — default DROP, persistent rules
#   5. rkhunter           — сканер руткитов/майнеров (по cron)
#   6. CPU watchdog       — cron-мониторинг аномальной нагрузки (майнеры)
#   7. Логирование DROP   — iptables LOG для отброшенных пакетов
#   8. Kernel hardening   — sysctl параметры безопасности
#
# Использование (на сервере):
#   sudo bash security-harden.sh [--ssh-port 22] [--vpn-port 51820]
#                                [--vpn-net 10.8.0.0/24] [--client-net 10.9.0.0/24]
#                                [--adguard-bind 10.8.0.2] [--role vps1|vps2]
#
# Вызывается автоматически из deploy.sh / deploy-vps1.sh / deploy-vps2.sh
# =============================================================================

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1

APT_OPTS=(-y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

SSH_PORT=22
VPN_PORT=51820
VPN_NET="10.8.0.0/24"
CLIENT_NET="10.9.0.0/24"
ADGUARD_BIND=""
ROLE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-port)    SSH_PORT="$2";     shift 2 ;;
        --vpn-port)    VPN_PORT="$2";     shift 2 ;;
        --vpn-net)     VPN_NET="$2";      shift 2 ;;
        --client-net)  CLIENT_NET="$2";   shift 2 ;;
        --adguard-bind) ADGUARD_BIND="$2"; shift 2 ;;
        --role)        ROLE="$2";         shift 2 ;;
        *) echo "Unknown: $1"; shift ;;
    esac
done

echo "[security-harden] Starting hardening (role=${ROLE:-any})..."

# ── 1. fail2ban ──────────────────────────────────────────────────────────────
echo "[security-harden] Installing fail2ban..."
apt-get -qq update
apt-get "${APT_OPTS[@]}" install fail2ban >/dev/null 2>&1

cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
backend  = systemd

[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 3600
EOF

systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban >/dev/null 2>&1
echo "[security-harden] fail2ban configured: ban after 3 attempts for 1 hour"

# ── 2. unattended-upgrades ──────────────────────────────────────────────────
echo "[security-harden] Configuring unattended-upgrades..."
apt-get "${APT_OPTS[@]}" install unattended-upgrades apt-listchanges >/dev/null 2>&1

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

systemctl enable unattended-upgrades >/dev/null 2>&1
systemctl restart unattended-upgrades >/dev/null 2>&1
echo "[security-harden] unattended-upgrades: daily security updates enabled"

# ── 3. SSH hardening ────────────────────────────────────────────────────────
echo "[security-harden] Hardening SSH daemon..."

SSHD_CONF="/etc/ssh/sshd_config"
SSHD_DROP="/etc/ssh/sshd_config.d/99-hardening.conf"
mkdir -p /etc/ssh/sshd_config.d

cat > "$SSHD_DROP" << EOF
PermitRootLogin prohibit-password
PasswordAuthentication no
MaxAuthTries 3
MaxSessions 5
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitEmptyPasswords no
Protocol 2
LoginGraceTime 30
EOF

if grep -q "^Include /etc/ssh/sshd_config.d/" "$SSHD_CONF" 2>/dev/null; then
    : # already includes drop-in directory
else
    echo "Include /etc/ssh/sshd_config.d/*.conf" >> "$SSHD_CONF"
fi

sshd -t 2>/dev/null && systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
echo "[security-harden] SSH: root password login disabled, max 3 auth tries"

# ── 4. iptables hardening (persistent base rules) ───────────────────────────
echo "[security-harden] Setting up persistent iptables base rules..."
apt-get "${APT_OPTS[@]}" install iptables-persistent >/dev/null 2>&1 || true

MAIN_IF=$(ip route | grep default | awk '{print $5}' | head -1)

iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i lo -j ACCEPT
iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 2 -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -C INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 3 -p tcp --dport "$SSH_PORT" -j ACCEPT
iptables -C INPUT -p udp --dport "$VPN_PORT" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 4 -p udp --dport "$VPN_PORT" -j ACCEPT

if [[ "$ROLE" == "vps1" ]]; then
    VPN_PORT_TUNNEL="${VPN_PORT_TUNNEL:-51821}"
    iptables -C INPUT -p udp --dport "$VPN_PORT_TUNNEL" -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p udp --dport "$VPN_PORT_TUNNEL" -j ACCEPT
fi

iptables -C INPUT -i awg0 -j ACCEPT 2>/dev/null || iptables -A INPUT -i awg0 -j ACCEPT
if [[ "$ROLE" == "vps1" ]]; then
    iptables -C INPUT -i awg1 -j ACCEPT 2>/dev/null || iptables -A INPUT -i awg1 -j ACCEPT
fi

iptables -C INPUT -p icmp --icmp-type echo-request -m limit --limit 5/sec -j ACCEPT 2>/dev/null || \
    iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/sec -j ACCEPT

# Rate-limit new SSH connections (anti-bruteforce at iptables level)
iptables -C INPUT -p tcp --dport "$SSH_PORT" -m state --state NEW -m recent --set --name SSH 2>/dev/null || \
    iptables -A INPUT -p tcp --dport "$SSH_PORT" -m state --state NEW -m recent --set --name SSH
iptables -C INPUT -p tcp --dport "$SSH_PORT" -m state --state NEW -m recent --update --seconds 60 --hitcount 6 --name SSH -j DROP 2>/dev/null || \
    iptables -A INPUT -p tcp --dport "$SSH_PORT" -m state --state NEW -m recent --update --seconds 60 --hitcount 6 --name SSH -j DROP

# Log dropped packets (limited to avoid log flood)
iptables -C INPUT -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "IPT_DROP: " --log-level 4 2>/dev/null || \
    iptables -A INPUT -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "IPT_DROP: " --log-level 4

iptables -P INPUT DROP
iptables -P FORWARD DROP

# FORWARD: allow VPN traffic (WireGuard PostUp handles specific rules, but base allows established)
iptables -C FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -m state --state ESTABLISHED,RELATED -j ACCEPT

# Save persistent rules
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
netfilter-persistent save 2>/dev/null || true

echo "[security-harden] iptables: default DROP policy, persistent rules saved"

# ── 5. rkhunter (rootkit/miner scanner) ─────────────────────────────────────
echo "[security-harden] Installing rkhunter..."
apt-get "${APT_OPTS[@]}" install rkhunter >/dev/null 2>&1 || true

if command -v rkhunter >/dev/null 2>&1; then
    rkhunter --update --nocolors 2>/dev/null || true
    rkhunter --propupd --nocolors 2>/dev/null || true

    cat > /etc/cron.daily/rkhunter-check << 'CRONEOF'
#!/bin/bash
/usr/bin/rkhunter --check --nocolors --skip-keypress --report-warnings-only \
    --logfile /var/log/rkhunter-daily.log 2>/dev/null
WARNINGS=$(grep -c "Warning:" /var/log/rkhunter-daily.log 2>/dev/null || echo 0)
if [[ "$WARNINGS" -gt 0 ]]; then
    echo "[rkhunter] $WARNINGS warnings found — check /var/log/rkhunter-daily.log" | \
        logger -t rkhunter -p auth.warning
fi
CRONEOF
    chmod +x /etc/cron.daily/rkhunter-check
    echo "[security-harden] rkhunter: daily scan configured"
else
    echo "[security-harden] rkhunter: package not available, skipping"
fi

# ── 6. CPU watchdog (miner detection) ───────────────────────────────────────
echo "[security-harden] Installing CPU watchdog cron..."

cat > /usr/local/bin/cpu-watchdog.sh << 'WATCHEOF'
#!/bin/bash
THRESHOLD=80
LOG="/var/log/cpu-watchdog.log"

CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print int($2 + $4)}')

if [[ "$CPU_USAGE" -gt "$THRESHOLD" ]]; then
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$TIMESTAMP] HIGH CPU: ${CPU_USAGE}% — top processes:" >> "$LOG"
    ps aux --sort=-%cpu | head -6 >> "$LOG"
    echo "---" >> "$LOG"

    SUSPICIOUS=$(ps aux --sort=-%cpu | awk 'NR>1 && $3>50 {print $11}' | head -3)
    for proc in $SUSPICIOUS; do
        KNOWN=false
        for safe in awg-quick awg youtube-proxy AdGuardHome sshd systemd apt dpkg; do
            [[ "$proc" == *"$safe"* ]] && KNOWN=true && break
        done
        if [[ "$KNOWN" == "false" ]]; then
            echo "[$TIMESTAMP] SUSPICIOUS: $proc using >50% CPU" >> "$LOG"
            logger -t cpu-watchdog -p auth.warning "Suspicious process: $proc using >50% CPU"
        fi
    done
fi
WATCHEOF
chmod +x /usr/local/bin/cpu-watchdog.sh

CRON_LINE="*/5 * * * * /usr/local/bin/cpu-watchdog.sh"
(crontab -l 2>/dev/null | grep -v "cpu-watchdog" ; echo "$CRON_LINE") | crontab -
echo "[security-harden] CPU watchdog: checks every 5 min, threshold 80%"

# ── 7. Kernel hardening (sysctl) ────────────────────────────────────────────
echo "[security-harden] Applying kernel security parameters..."

cat > /etc/sysctl.d/98-security.conf << 'EOF'
# Ignore ICMP redirects (prevent MITM)
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0

# Ignore source-routed packets
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0

# Log martian packets
net.ipv4.conf.all.log_martians=1
net.ipv4.conf.default.log_martians=1

# SYN flood protection
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_max_syn_backlog=4096

# Ignore ICMP broadcast
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1

# Disable IPv6 (not used in this VPN setup)
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1

# Restrict dmesg access
kernel.dmesg_restrict=1

# Restrict kernel pointer exposure
kernel.kptr_restrict=2

# Restrict ptrace scope
kernel.yama.ptrace_scope=1
EOF

sysctl -p /etc/sysctl.d/98-security.conf 2>/dev/null || true
echo "[security-harden] Kernel hardening applied"

# ── 8. AdGuard Home bind restriction (VPS2 only) ────────────────────────────
if [[ -n "$ADGUARD_BIND" && -f /opt/AdGuardHome/AdGuardHome.yaml ]]; then
    echo "[security-harden] Restricting AdGuard Home to ${ADGUARD_BIND}..."
    sed -i "s|address: 0.0.0.0:3000|address: ${ADGUARD_BIND}:3000|" /opt/AdGuardHome/AdGuardHome.yaml
    sed -i 's/bind_hosts:/bind_hosts:/' /opt/AdGuardHome/AdGuardHome.yaml
    sed -i "s|    - 0.0.0.0|    - ${ADGUARD_BIND}|" /opt/AdGuardHome/AdGuardHome.yaml
    /opt/AdGuardHome/AdGuardHome -s restart 2>/dev/null || true
    echo "[security-harden] AdGuard Home now listens on ${ADGUARD_BIND} only"
fi

# ── 9. Log rotation for security logs ───────────────────────────────────────
cat > /etc/logrotate.d/vpn-security << 'EOF'
/var/log/rkhunter-daily.log /var/log/cpu-watchdog.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF

echo "[security-harden] Log rotation configured"
echo "[security-harden] Hardening complete."
