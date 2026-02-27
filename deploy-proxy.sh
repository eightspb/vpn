#!/usr/bin/env bash
# deploy-proxy.sh — deploys youtube-proxy to VPS2
# Called from deploy.sh with --with-proxy flag, or standalone:
#   bash deploy-proxy.sh --vps2-ip 38.135.122.81 --vps2-key ~/.ssh/id_rsa
#
# Prerequisites: Go installed locally (https://go.dev/dl/)
# The script cross-compiles the binary for Linux amd64 and uploads it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY_DIR="$SCRIPT_DIR/youtube-proxy"
BINARY_NAME="youtube-proxy"
REMOTE_DIR="/opt/youtube-proxy"

# ── Parse arguments ──────────────────────────────────────────────────────────
VPS2_IP=""
VPS2_KEY=""
ADGUARD_REMOVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps2-ip)    VPS2_IP="$2";    shift 2 ;;
        --vps2-key)   VPS2_KEY="$2";   shift 2 ;;
        --remove-adguard) ADGUARD_REMOVE=true; shift ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$VPS2_IP" || -z "$VPS2_KEY" ]]; then
    echo "Usage: bash deploy-proxy.sh --vps2-ip <IP> --vps2-key <path-to-key> [--remove-adguard]"
    exit 1
fi

SSH="ssh -i $VPS2_KEY -o StrictHostKeyChecking=no root@$VPS2_IP"
SCP="scp -i $VPS2_KEY -o StrictHostKeyChecking=no"

echo ""
echo "=== YouTube Proxy Deploy ==="
echo "  Target: root@$VPS2_IP"
echo ""

# ── Step 1: Build binary ──────────────────────────────────────────────────────
echo "[1/5] Building youtube-proxy for linux/amd64..."
cd "$PROXY_DIR"

if ! command -v go &>/dev/null; then
    echo "ERROR: Go is not installed. Download from https://go.dev/dl/"
    exit 1
fi

GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o "$BINARY_NAME" ./cmd/proxy
echo "      Binary size: $(du -sh $BINARY_NAME | cut -f1)"

# ── Step 2: Upload files ──────────────────────────────────────────────────────
echo "[2/5] Uploading files to VPS2..."
$SSH "mkdir -p $REMOTE_DIR/certs $REMOTE_DIR/blocklists"

$SCP "$PROXY_DIR/$BINARY_NAME"       "root@$VPS2_IP:$REMOTE_DIR/"
$SCP "$PROXY_DIR/config.yaml"        "root@$VPS2_IP:$REMOTE_DIR/"
$SCP "$PROXY_DIR/blocklists/"*.txt   "root@$VPS2_IP:$REMOTE_DIR/blocklists/"

$SSH "chmod +x $REMOTE_DIR/$BINARY_NAME"

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
ExecStart=/opt/youtube-proxy/youtube-proxy --config /opt/youtube-proxy/config.yaml
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

# ── Step 4: Configure DNS on VPS2 ────────────────────────────────────────────
echo "[4/5] Configuring DNS on VPS2..."

# Stop systemd-resolved if it holds port 53
$SSH "systemctl stop systemd-resolved 2>/dev/null || true"
$SSH "systemctl disable systemd-resolved 2>/dev/null || true"

# Point VPS2 itself to our DNS
$SSH "echo 'nameserver 127.0.0.1' > /etc/resolv.conf"

# Update AmneziaWG client config to use our DNS
# The DNS= line in the WireGuard config tells clients which DNS to use
$SSH "grep -q '^DNS=' /etc/amnezia/amneziawg/awg0.conf && \
      sed -i 's/^DNS=.*/DNS=10.8.0.2/' /etc/amnezia/amneziawg/awg0.conf || \
      sed -i '/^\[Interface\]/a DNS=10.8.0.2' /etc/amnezia/amneziawg/awg0.conf"

# ── Step 5: Remove AdGuard Home (optional) ────────────────────────────────────
if [[ "$ADGUARD_REMOVE" == "true" ]]; then
    echo "[5/5] Removing AdGuard Home..."
    $SSH "systemctl stop AdGuardHome 2>/dev/null || true"
    $SSH "systemctl disable AdGuardHome 2>/dev/null || true"
    $SSH "rm -f /etc/systemd/system/AdGuardHome.service"
    $SSH "systemctl daemon-reload"
    echo "      AdGuard Home removed."
else
    echo "[5/5] Skipping AdGuard Home removal (use --remove-adguard to remove)."
    echo "      Note: AdGuard Home and youtube-proxy both use port 53."
    echo "      You should either remove AdGuard Home or change its port."
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
echo "Root CA certificate is available at:"
echo "  http://$VPS2_IP:8080/ca.crt"
echo ""
echo "Install it on your devices:"
echo "  iOS:     Open http://$VPS2_IP:8080 in Safari → Download ca.crt"
echo "           Settings → Profile Downloaded → Install → Trust"
echo "  Android: Download ca.crt → Settings → Security → Install certificate → CA"
echo "  Windows: Download ca.crt → double-click → Install → Trusted Root CAs"
echo ""
echo "After installing the certificate, your devices will have:"
echo "  ✓ YouTube pre-roll ads removed"
echo "  ✓ Ad/tracking/malware domains blocked (DNS)"
echo "  ✓ No additional apps needed on devices"
