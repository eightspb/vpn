#!/usr/bin/env bash
set -euo pipefail

sudo tee /etc/systemd/system/vpn-monitor-web.service >/dev/null <<UNIT
[Unit]
Description=VPN monitor-web collector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=slava
Group=slava
WorkingDirectory=/opt/vpn/scripts/monitor
ExecStart=/usr/bin/env bash /opt/vpn/scripts/monitor/monitor-web.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable vpn-monitor-web.service >/dev/null
sudo systemctl restart vpn-monitor-web.service
sleep 3
sudo systemctl --no-pager --full status vpn-monitor-web.service | sed -n '1,28p'
