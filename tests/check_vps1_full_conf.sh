#!/bin/bash
KEY=~/.ssh/ssh-key-1772056840349
VPS1=slava@130.193.41.13

echo "=== awg1.conf полный ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS1" \
    'cat /etc/amnezia/amneziawg/awg1.conf 2>/dev/null || echo "Файл не найден"'
