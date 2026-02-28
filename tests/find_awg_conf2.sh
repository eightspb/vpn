#!/bin/bash
KEY=.ssh/ssh-key-1772056840349
VPS1=slava@130.193.41.13

echo "=== /etc/amnezia/amneziawg/ ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS1" \
    'ls -la /etc/amnezia/amneziawg/ 2>/dev/null && cat /etc/amnezia/amneziawg/awg1.conf 2>/dev/null || echo "awg1.conf не найден"'

echo ""
echo "=== /etc/wireguard/ ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS1" \
    'ls -la /etc/wireguard/ 2>/dev/null || echo "нет /etc/wireguard"'
