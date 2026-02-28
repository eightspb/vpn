#!/bin/bash
KEY=.ssh/ssh-key-1772056840349
VPS1=slava@130.193.41.13

echo "=== journalctl awg-quick@awg1 ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS1" \
    'sudo journalctl -u awg-quick@awg1 -n 30 --no-pager 2>/dev/null'

echo ""
echo "=== iptables PREROUTING ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS1" \
    'sudo iptables -t nat -L PREROUTING -n -v 2>/dev/null'
