#!/bin/bash
KEY=.ssh/ssh-key-1772056840349
VPS1=slava@130.193.41.13

echo "=== Поиск awg конфигов ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS1" \
    'find /etc -name "awg*.conf" 2>/dev/null; find /etc/wireguard -name "*.conf" 2>/dev/null; ls /etc/amnezia/ 2>/dev/null'

echo ""
echo "=== systemctl status awg1 ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS1" \
    'systemctl status awg-quick@awg1 2>&1 | head -15'
