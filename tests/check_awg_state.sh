#!/bin/bash
KEY=.ssh/ssh-key-1772056840349
VPS1=slava@130.193.41.13

echo "=== awg show all ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS1" \
    'awg show all 2>/dev/null || echo "awg не найден"'

echo ""
echo "=== ip link show ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS1" \
    'ip link show | grep -E "awg|wg"'

echo ""
echo "=== iptables PREROUTING ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS1" \
    'iptables -t nat -L PREROUTING -n 2>/dev/null'
