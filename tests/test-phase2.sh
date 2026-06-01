#!/usr/bin/env bash
# Tests for Phase 2 (performance): MTU in deploy scripts and legacy proxy cleanup
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAIL=0

echo "=== Phase 2: MTU in scripts/deploy/deploy-vps1.sh (awg0, awg1) ==="
if grep -q "MTU = 1420" scripts/deploy/deploy-vps1.sh && grep -q "MTU = 1360" scripts/deploy/deploy-vps1.sh; then
  echo "OK: scripts/deploy/deploy-vps1.sh has MTU for awg0 and awg1"
else
  echo "FAIL: scripts/deploy/deploy-vps1.sh expected MTU = 1420 (awg0) and MTU = 1360 (awg1)"
  FAIL=1
fi

echo ""
echo "=== Phase 2: MTU in scripts/deploy/deploy-vps2.sh (awg0) ==="
if grep -q "MTU = 1420" scripts/deploy/deploy-vps2.sh; then
  echo "OK: scripts/deploy/deploy-vps2.sh has MTU for awg0"
else
  echo "FAIL: scripts/deploy/deploy-vps2.sh expected MTU = 1420 for awg0"
  FAIL=1
fi

echo ""
echo "=== Phase 2: legacy youtube-proxy removed ==="
if [[ ! -d youtube-proxy && ! -f scripts/deploy/deploy-proxy.sh ]]; then
  echo "OK: youtube-proxy code and deploy script removed"
else
  echo "FAIL: youtube-proxy legacy files still present"
  FAIL=1
fi

if ! grep -q -- "--with-proxy" README.md manage.sh; then
  echo "OK: --with-proxy removed from docs/help"
elif grep -q -- '--with-proxy|--remove-adguard' scripts/deploy/deploy.sh; then
  echo "OK: legacy proxy flags are rejected by deploy.sh"
else
  echo "FAIL: --with-proxy still referenced outside explicit rejection"
  FAIL=1
fi

if ! grep -q -- "--proxy" README.md && grep -q -- '--proxy удалён' manage.sh; then
  echo "OK: --proxy removed from docs and rejected by manage.sh"
else
  echo "FAIL: --proxy docs/rejection state is not correct"
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
