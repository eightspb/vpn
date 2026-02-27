#!/bin/bash
# Дампим текущую конфигурацию awg интерфейсов с VPS1
KEY=~/.ssh/ssh-key-1772056840349
VPS1=slava@130.193.41.13

echo "=== awg showconf awg0 ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS1" \
    'sudo awg showconf awg0 2>/dev/null || wg showconf awg0 2>/dev/null || echo "awg/wg не найден"'

echo ""
echo "=== awg showconf awg1 ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS1" \
    'sudo awg showconf awg1 2>/dev/null || wg showconf awg1 2>/dev/null || echo "awg/wg не найден"'
