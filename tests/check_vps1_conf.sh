#!/bin/bash
KEY=.ssh/ssh-key-1772056840349
VPS1=slava@130.193.41.13

echo "=== awg1.conf DNAT строки ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS1" \
    'cat /etc/amnezia/amneziawg/awg1.conf 2>/dev/null | grep -E "DNAT|PostUp|PostDown" || echo "Нет DNAT в конфиге"'

echo ""
echo "=== Текущие PREROUTING правила ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS1" \
    'iptables -t nat -L PREROUTING -n 2>/dev/null | grep -E "53|DNAT" || echo "Нет DNAT правил"'
