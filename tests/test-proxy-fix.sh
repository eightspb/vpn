#!/usr/bin/env bash
# tests/test-proxy-fix.sh — проверка изменений youtube-proxy (фикс стабильности)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PASS=0; FAIL=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo ""
echo "=== Тест: youtube-proxy stability fix ==="
echo ""

# 1. config.yaml — DNS привязан к 10.8.0.2
if grep -q 'listen: "10.8.0.2:53"' youtube-proxy/config.yaml; then
  ok "config.yaml: DNS слушает на 10.8.0.2:53"
else
  fail "config.yaml: DNS не привязан к 10.8.0.2:53"
fi

# 2. config.yaml — прокси привязан к 10.8.0.2
if grep -q 'listen: "10.8.0.2:443"' youtube-proxy/config.yaml; then
  ok "config.yaml: прокси слушает на 10.8.0.2:443"
else
  fail "config.yaml: прокси не привязан к 10.8.0.2:443"
fi

# 3. config.yaml — intercept_hosts закомментирован или отсутствует
if ! grep -q '^[[:space:]]*intercept_hosts:' youtube-proxy/config.yaml; then
  ok "config.yaml: intercept_hosts отсутствует или закомментирован"
else
  fail "config.yaml: intercept_hosts присутствует и не закомментирован"
fi

# 4. config.yaml — новые блоклисты добавлены (hagezi)
if grep -q 'hagezi' youtube-proxy/config.yaml; then
  ok "config.yaml: блоклисты hagezi добавлены"
else
  fail "config.yaml: блоклисты hagezi не найдены"
fi

# 5. config.yaml — новые эндпоинты добавлены
if grep -q '/youtubei/v1/search' youtube-proxy/config.yaml; then
  ok "config.yaml: эндпоинт /youtubei/v1/search добавлен"
else
  fail "config.yaml: эндпоинт /youtubei/v1/search не найден"
fi

# 6. config.yaml — новые ключи фильтра добавлены
if grep -q 'adBreakServiceRenderer' youtube-proxy/config.yaml; then
  ok "config.yaml: ключ фильтра adBreakServiceRenderer добавлен"
else
  fail "config.yaml: ключ фильтра adBreakServiceRenderer не найден"
fi

# 7. ads.txt — расширен (больше 20 строк с доменами)
domain_count=$(grep -c '\.' youtube-proxy/blocklists/ads.txt 2>/dev/null || echo 0)
if [[ "$domain_count" -gt 20 ]]; then
  ok "ads.txt: содержит $domain_count доменов (> 20)"
else
  fail "ads.txt: содержит только $domain_count доменов (ожидается > 20)"
fi

# 8. ads.txt — imasdk.googleapis.com добавлен
if grep -q 'imasdk.googleapis.com' youtube-proxy/blocklists/ads.txt; then
  ok "ads.txt: imasdk.googleapis.com присутствует"
else
  fail "ads.txt: imasdk.googleapis.com не найден"
fi

# 9. proxy.go — ReadHeaderTimeout добавлен
if grep -q 'ReadHeaderTimeout' youtube-proxy/internal/proxy/proxy.go; then
  ok "proxy.go: ReadHeaderTimeout добавлен"
else
  fail "proxy.go: ReadHeaderTimeout не найден"
fi

# 10. proxy.go — TLSNextProto добавлен
if grep -q 'TLSNextProto' youtube-proxy/internal/proxy/proxy.go; then
  ok "proxy.go: TLSNextProto добавлен"
else
  fail "proxy.go: TLSNextProto не найден"
fi

echo ""
echo "Результат: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && echo "OK — все проверки прошли" && exit 0
echo "FAIL — есть ошибки" && exit 1
