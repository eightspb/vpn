#!/usr/bin/env bash
# Tests for Phase 2 (performance): DNS cache, streaming, connection pooling, MTU in deploy scripts
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAIL=0

echo "=== Phase 2: Go build youtube-proxy ==="
if (cd youtube-proxy && go build ./...); then
  echo "OK: youtube-proxy build"
else
  echo "FAIL: youtube-proxy build"
  FAIL=1
fi

echo ""
echo "=== Phase 2: MTU in scripts/deploy/deploy-vps1.sh (awg0, awg1) ==="
if grep -q "MTU = 1320" scripts/deploy/deploy-vps1.sh && grep -q "MTU = 1280" scripts/deploy/deploy-vps1.sh; then
  echo "OK: scripts/deploy/deploy-vps1.sh has MTU for awg0 and awg1"
else
  echo "FAIL: scripts/deploy/deploy-vps1.sh expected MTU = 1320 (awg0) and MTU = 1280 (awg1)"
  FAIL=1
fi

echo ""
echo "=== Phase 2: MTU in scripts/deploy/deploy-vps2.sh (awg0) ==="
if grep -q "MTU = 1280" scripts/deploy/deploy-vps2.sh; then
  echo "OK: scripts/deploy/deploy-vps2.sh has MTU for awg0"
else
  echo "FAIL: scripts/deploy/deploy-vps2.sh expected MTU = 1280 for awg0"
  FAIL=1
fi

echo ""
echo "=== Phase 2: proxy.go connection pooling ==="
if grep -q "MaxIdleConns" youtube-proxy/internal/proxy/proxy.go; then
  echo "OK: connection pooling in proxy.go"
else
  echo "FAIL: proxy.go expected MaxIdleConns"
  FAIL=1
fi

echo ""
echo "=== Phase 2: proxy.go streaming ==="
if grep -q "io.Copy(w, resp.Body)" youtube-proxy/internal/proxy/proxy.go; then
  echo "OK: streaming for non-filtered requests"
else
  echo "FAIL: proxy.go expected io.Copy streaming"
  FAIL=1
fi

echo ""
echo "=== Phase 2: dns/server.go cache ==="
if grep -q "cacheEntry" youtube-proxy/internal/dns/server.go && grep -q "maxCacheTTL" youtube-proxy/internal/dns/server.go; then
  echo "OK: DNS cache in server.go"
else
  echo "FAIL: dns/server.go expected cache (cacheEntry, maxCacheTTL)"
  FAIL=1
fi

if [ $FAIL -eq 0 ]; then
  echo ""
  echo "=== All Phase 2 checks passed ==="
  exit 0
else
  echo ""
  echo "=== Some checks failed ==="
  exit 1
fi
