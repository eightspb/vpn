#!/usr/bin/env bash
set -euo pipefail

sudo apt-get update -qq
sudo apt-get install -y -qq nginx >/dev/null

# Bind admin backend to localhost only
sudo sed -i 's/--host 0\.0\.0\.0/--host 127.0.0.1/g' /etc/systemd/system/vpn-admin.service

CERT_FULL=/etc/letsencrypt/live/vpnrus.net/fullchain.pem
CERT_KEY=/etc/letsencrypt/live/vpnrus.net/privkey.pem
if [[ ! -f "$CERT_FULL" || ! -f "$CERT_KEY" ]]; then
  CERT_FULL=/opt/vpn/scripts/admin/certs/admin.crt
  CERT_KEY=/opt/vpn/scripts/admin/certs/admin.key
fi

sudo tee /etc/nginx/sites-available/vpn-admin.conf >/dev/null <<NGINX
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    listen [::]:80;
    server_name vpnrus.net www.vpnrus.net;
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name vpnrus.net www.vpnrus.net;

    ssl_certificate ${CERT_FULL};
    ssl_certificate_key ${CERT_KEY};
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass https://127.0.0.1:8443;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
        proxy_ssl_verify off;
    }
}
NGINX

sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/vpn-admin.conf /etc/nginx/sites-enabled/vpn-admin.conf
sudo nginx -t

sudo systemctl daemon-reload
sudo systemctl restart vpn-admin
sudo systemctl enable nginx >/dev/null
sudo systemctl restart nginx

# Firewall: open 80/443, close direct 8443
sudo iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || sudo iptables -I INPUT 4 -p tcp --dport 80 -j ACCEPT
sudo iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || sudo iptables -I INPUT 4 -p tcp --dport 443 -j ACCEPT
while sudo iptables -C INPUT -p tcp --dport 8443 -j ACCEPT 2>/dev/null; do
  sudo iptables -D INPUT -p tcp --dport 8443 -j ACCEPT
done
if command -v netfilter-persistent >/dev/null 2>&1; then
  sudo netfilter-persistent save >/dev/null 2>&1 || true
fi

echo "CERT_FULL=$CERT_FULL"
echo "CERT_KEY=$CERT_KEY"
sudo systemctl is-active vpn-admin
sudo systemctl is-active nginx
curl -kfsS https://127.0.0.1/api/health
