#!/bin/bash
KEY=~/.ssh/ssh-key-1772056840349
VPS1=slava@130.193.41.13

echo "=== ls -la /etc/amnezia/ ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS1" \
    'ls -laR /etc/amnezia/ 2>/dev/null'

echo ""
echo "=== awg-quick@awg1 ExecStart path ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS1" \
    'systemctl cat awg-quick@awg1 2>/dev/null | grep ExecStart'
