#!/usr/bin/env bash
# deploy-proxy.sh — deploys youtube-proxy to VPS2
# Called from deploy.sh with --with-proxy flag, or standalone:
#   bash deploy-proxy.sh --vps2-ip 38.135.122.81 --vps2-key ~/.ssh/id_rsa
#
# Prerequisites: Go installed locally (https://go.dev/dl/)
# The script cross-compiles the binary for Linux amd64 and uploads it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# On Windows/Git Bash, convert drive-letter paths to /mnt/... style if needed
if [[ "$SCRIPT_DIR" =~ ^/[A-Za-z]/ ]]; then
    DRIVE=$(echo "$SCRIPT_DIR" | cut -c2 | tr '[:upper:]' '[:lower:]')
    REST=$(echo "$SCRIPT_DIR" | cut -c3-)
    SCRIPT_DIR="/mnt/${DRIVE}${REST}"
fi

source "${SCRIPT_DIR}/../../lib/common.sh"

PROXY_DIR="$SCRIPT_DIR/../../youtube-proxy"
BINARY_NAME="youtube-proxy"
REMOTE_DIR="/opt/youtube-proxy"

# ── Parse arguments ──────────────────────────────────────────────────────────
VPS2_IP=""
VPS2_USER="root"
VPS2_KEY=""
VPS2_PASS=""
ADGUARD_REMOVE=false

load_defaults_from_files

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps2-ip)    VPS2_IP="$2";    shift 2 ;;
        --vps2-user)  VPS2_USER="$2";  shift 2 ;;
        --vps2-key)   VPS2_KEY="$2";   shift 2 ;;
        --vps2-pass)  VPS2_PASS="$2";  shift 2 ;;
        --remove-adguard) ADGUARD_REMOVE=true; shift ;;
        --help|-h)
            echo "Usage: bash deploy-proxy.sh [--vps2-ip IP] [--vps2-key KEY] [--vps2-user USER] [--vps2-pass PASS] [--remove-adguard]"
            echo "Parameters auto-loaded from .env if not specified."
            exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

VPS2_KEY="$(expand_tilde "$VPS2_KEY")"
VPS2_KEY="$(auto_pick_key_if_missing "$VPS2_KEY")"

require_vars "deploy-proxy.sh" VPS2_IP
[[ -z "$VPS2_KEY" && -z "$VPS2_PASS" ]] && err "Укажите --vps2-key или --vps2-pass (или VPS2_KEY в .env)"

# Формируем SSH/SCP команды с учётом ключа или пароля
if [[ -n "$VPS2_KEY" ]]; then
    SSH="ssh -i $VPS2_KEY -o StrictHostKeyChecking=accept-new ${VPS2_USER}@$VPS2_IP"
    SCP="scp -i $VPS2_KEY -o StrictHostKeyChecking=accept-new"
elif [[ -n "$VPS2_PASS" ]]; then
    SSH="sshpass -p '$VPS2_PASS' ssh -o StrictHostKeyChecking=accept-new ${VPS2_USER}@$VPS2_IP"
    SCP="sshpass -p '$VPS2_PASS' scp -o StrictHostKeyChecking=accept-new"
else
    SSH="ssh -o StrictHostKeyChecking=accept-new ${VPS2_USER}@$VPS2_IP"
    SCP="scp -o StrictHostKeyChecking=accept-new"
fi

echo ""
echo "=== YouTube Proxy Deploy ==="
echo "  Target: ${VPS2_USER}@$VPS2_IP"
echo ""

# ── Step 1: Build binary ──────────────────────────────────────────────────────
echo "[1/5] Building youtube-proxy for linux/amd64..."
cd "$PROXY_DIR"

# Find go binary: check PATH first, then common install locations
GO_BIN=""
if command -v go &>/dev/null; then
    GO_BIN=$(command -v go)
else
    for candidate in ~/go-dist/go/bin/go ~/go/bin/go /usr/local/go/bin/go; do
        if [[ -x "$candidate" ]]; then
            GO_BIN="$candidate"
            break
        fi
    done
fi

if [[ -z "$GO_BIN" ]]; then
    echo "ERROR: Go is not installed. Run: bash install-go.sh"
    exit 1
fi
echo "      Using Go: $GO_BIN ($($GO_BIN version))"

GOOS=linux GOARCH=amd64 "$GO_BIN" build -ldflags="-s -w" -o "$BINARY_NAME" ./cmd/proxy
echo "      Binary size: $(du -sh $BINARY_NAME | cut -f1)"

# ── Step 2: Upload files ──────────────────────────────────────────────────────
echo "[2/5] Uploading files to VPS2..."
$SSH "mkdir -p $REMOTE_DIR/certs $REMOTE_DIR/blocklists"

# Останавливаем сервис перед заменой бинарника (иначе "Text file busy")
$SSH "systemctl stop youtube-proxy 2>/dev/null || true"
sleep 1

$SCP "$PROXY_DIR/$BINARY_NAME"       "${VPS2_USER}@$VPS2_IP:$REMOTE_DIR/"
$SCP "$PROXY_DIR/config.yaml"        "${VPS2_USER}@$VPS2_IP:$REMOTE_DIR/"
$SCP "$PROXY_DIR/blocklists/"*.txt   "${VPS2_USER}@$VPS2_IP:$REMOTE_DIR/blocklists/"

$SSH "chmod +x $REMOTE_DIR/$BINARY_NAME"

# Remove old server cert so it is regenerated with updated SANs from config.yaml.
# CA cert is intentionally preserved — it is already installed on client devices.
echo "      Removing old server cert (will be regenerated with new SANs)..."
$SSH "rm -f $REMOTE_DIR/certs/server.crt $REMOTE_DIR/certs/server.key"

# ── Step 3: Create systemd service ───────────────────────────────────────────
echo "[3/5] Installing systemd service..."
$SSH "cat > /etc/systemd/system/youtube-proxy.service" << 'EOF'
[Unit]
Description=YouTube Ad Proxy (DNS + HTTPS filter)
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=/opt/youtube-proxy
ExecStartPre=+/bin/sh -c '/sbin/iptables -D INPUT -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true'
ExecStartPre=+/bin/sh -c '/sbin/iptables -I INPUT 1 -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable'
ExecStart=/opt/youtube-proxy/youtube-proxy --config /opt/youtube-proxy/config.yaml
ExecStopPost=+/bin/sh -c '/sbin/iptables -D INPUT -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true'
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
# Allow binding to ports 53 and 443
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

$SSH "systemctl daemon-reload && systemctl enable youtube-proxy"

# ── Step 4: Configure DNS & Firewall on VPS2 ─────────────────────────────────
echo "[4/5] Configuring DNS & Firewall on VPS2..."

# Stop systemd-resolved if it holds port 53
$SSH "systemctl stop systemd-resolved 2>/dev/null || true"
$SSH "systemctl disable systemd-resolved 2>/dev/null || true"

# AdGuard Home and youtube-proxy both need port 53 — they cannot coexist.
# Always stop AdGuard Home; use --remove-adguard to fully uninstall it.
echo "      Stopping AdGuard Home (conflicts with youtube-proxy on port 53)..."
$SSH "systemctl stop AdGuardHome 2>/dev/null || systemctl stop adguardhome 2>/dev/null || true"
$SSH "systemctl disable AdGuardHome 2>/dev/null || systemctl disable adguardhome 2>/dev/null || true"

# Point VPS2 itself to our DNS
# /etc/resolv.conf может быть симлинком от systemd-resolved — заменяем на реальный файл
$SSH "rm -f /etc/resolv.conf && printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf"

# Update AmneziaWG client config to use our DNS
# The DNS= line in the WireGuard config tells clients which DNS to use
$SSH "grep -q '^DNS=' /etc/amnezia/amneziawg/awg0.conf && \
      sed -i 's/^DNS=.*/DNS=10.8.0.2/' /etc/amnezia/amneziawg/awg0.conf || \
      sed -i '/^\[Interface\]/a DNS=10.8.0.2' /etc/amnezia/amneziawg/awg0.conf"

# Allow TCP 443 (HTTPS proxy) from VPN tunnel — clients connect to 10.8.0.2:443
$SSH "iptables -C INPUT -p tcp --dport 443 -i awg0 -j ACCEPT 2>/dev/null || \
      iptables -I INPUT 1 -p tcp --dport 443 -i awg0 -j ACCEPT"
echo "      TCP 443 from VPN tunnel (awg0) allowed for HTTPS proxy"

# Block CA server port 8080 from public internet (only accessible via VPN tunnel)
# The CA server listens on 10.8.0.2:8080 (VPN interface only), but add explicit
# firewall rules to prevent any accidental exposure on the public interface
$SSH "iptables -C INPUT -p tcp --dport 8080 -i awg0 -j ACCEPT 2>/dev/null || \
      iptables -I INPUT 1 -p tcp --dport 8080 -i awg0 -j ACCEPT"
$SSH "iptables -C INPUT -p tcp --dport 8080 -j DROP 2>/dev/null || \
      iptables -A INPUT -p tcp --dport 8080 -j DROP"
echo "      CA server port 8080 restricted to VPN interface (awg0) only"

# Allow SSH from VPN client network (needed for dashboard monitor)
$SSH "iptables -C INPUT -p tcp --dport 22 -s 10.9.0.0/24 -j ACCEPT 2>/dev/null || \
      iptables -I INPUT 1 -p tcp --dport 22 -s 10.9.0.0/24 -j ACCEPT"
echo "      SSH from VPN client network (10.9.0.0/24) allowed"

# ── Step 5: Remove AdGuard Home (optional) ────────────────────────────────────
if [[ "$ADGUARD_REMOVE" == "true" ]]; then
    echo "[5/5] Removing AdGuard Home..."
    $SSH "systemctl stop AdGuardHome 2>/dev/null || true"
    $SSH "systemctl disable AdGuardHome 2>/dev/null || true"
    $SSH "rm -f /etc/systemd/system/AdGuardHome.service /etc/systemd/system/adguardhome.service"
    $SSH "rm -rf /opt/AdGuardHome"
    $SSH "systemctl daemon-reload"
    echo "      AdGuard Home removed."
else
    echo "[5/5] AdGuard Home stopped/disabled (conflicts with youtube-proxy on port 53)."
    echo "      Run with --remove-adguard to fully uninstall it."
fi

# ── Start service ─────────────────────────────────────────────────────────────
echo ""
echo "Starting youtube-proxy..."
$SSH "systemctl start youtube-proxy"
sleep 2
$SSH "systemctl status youtube-proxy --no-pager -l"

# ── Print CA download URL ─────────────────────────────────────────────────────
echo ""
echo "=== DONE ==="
echo ""
echo "Root CA certificate is available ONLY via VPN tunnel at:"
echo "  http://10.8.0.2:8080/ca.crt"
echo ""
echo "IMPORTANT: Port 8080 is blocked from the public internet."
echo "Connect to VPN first, then install the certificate."
echo ""
echo "━━━ Install CA certificate on your devices (VPN must be ON) ━━━"
echo ""
echo "  Windows (automated):"
echo "    powershell -ExecutionPolicy Bypass -File install-ca.ps1"
echo ""
echo "  Windows (manual):"
echo "    1. Connect to VPN"
echo "    2. Open http://10.8.0.2:8080 in browser → Download ca.crt"
echo "    3. Double-click ca.crt → Install Certificate → Local Machine"
echo "       → Place in Trusted Root Certification Authorities → Finish"
echo "    4. Restart browser"
echo ""
echo "  iOS:"
echo "    1. Connect to VPN"
echo "    2. Open http://10.8.0.2:8080 in Safari → Download ca.crt"
echo "    3. Settings → Profile Downloaded → Install → Trust"
echo "    4. Settings → General → About → Certificate Trust Settings → Enable"
echo ""
echo "  Android:"
echo "    1. Connect to VPN"
echo "    2. Download ca.crt from http://10.8.0.2:8080"
echo "    3. Settings → Security → Install certificate → CA certificate"
echo ""
echo "After installing the certificate, your devices will have:"
echo "  ✓ YouTube pre-roll ads removed"
echo "  ✓ Ad/tracking/malware domains blocked (DNS)"
echo "  ✓ No additional apps needed on devices"
echo ""
echo "NOTE: Without the CA certificate, YouTube will show SSL errors."
echo "      This is expected — the proxy intercepts HTTPS traffic."
