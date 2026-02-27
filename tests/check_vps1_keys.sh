#!/bin/bash
# Читаем текущие ключи с VPS1 для восстановления awg1.conf
KEY=~/.ssh/ssh-key-1772056840349
VPS1=slava@130.193.41.13

echo "=== Ключи на VPS1 ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS1" '
echo "vps1_tunnel_pub=$(cat /etc/amnezia/keys/vps1_tunnel_pub 2>/dev/null)"
echo "vps1_tunnel_priv=$(cat /etc/amnezia/keys/vps1_tunnel_priv 2>/dev/null)"
echo "vps2_tunnel_pub=$(cat /etc/amnezia/keys/vps2_tunnel_pub 2>/dev/null)"
echo "vps1_client_pub=$(cat /etc/amnezia/keys/vps1_client_pub 2>/dev/null)"
echo "vps1_client_priv=$(cat /etc/amnezia/keys/vps1_client_priv 2>/dev/null)"
echo "client_spb_pub=$(cat /etc/amnezia/keys/client_spb_pub 2>/dev/null)"
echo "client_spb_priv=$(cat /etc/amnezia/keys/client_spb_priv 2>/dev/null)"
'

echo ""
echo "=== awg0 interface state ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS1" 'ip addr show awg0 2>/dev/null; ip addr show awg1 2>/dev/null'
