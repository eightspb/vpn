#!/usr/bin/env bash
set -euo pipefail

sudo apt-get update -qq
sudo apt-get install -y -qq certbot python3-certbot-nginx >/dev/null

# Make sure nginx config is valid before certbot
sudo nginx -t
sudo systemctl restart nginx

# Issue cert for root domain only (www not configured in DNS yet)
sudo certbot --nginx -d vpnrus.net --non-interactive --agree-tos --register-unsafely-without-email --redirect

sudo nginx -t
sudo systemctl reload nginx

sudo ls -la /etc/letsencrypt/live/vpnrus.net/
sudo systemctl is-active nginx
curl -fsS https://vpnrus.net/api/health
