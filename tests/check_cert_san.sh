#!/bin/bash
# Проверяет IP SAN в серверном сертификате youtube-proxy на VPS2
KEY=~/.ssh/ssh-key-1772056840349
VPS2=root@38.135.122.81

echo "=== Проверка SAN в server.crt ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS2" \
    'openssl x509 -in /opt/youtube-proxy/certs/server.crt -noout -text 2>&1 | grep -A5 "Subject Alternative"'

echo ""
echo "=== Проверка TLS подключения к 10.8.0.2:443 ==="
ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS2" \
    'echo | openssl s_client -connect 10.8.0.2:443 -servername youtubei.googleapis.com 2>&1 | grep -E "subject|issuer|Verify|IP Address|DNS:" | head -10'
