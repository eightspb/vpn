#!/usr/bin/env bash
# tests/test-phase3.sh — проверки Фазы 3 (безопасность и архитектура)
# Запуск: bash tests/test-phase3.sh

set -u

PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

check() {
    local condition="$1" pass_msg="$2" fail_msg="$3"
    if eval "$condition"; then ok "$pass_msg"; else fail "$fail_msg"; fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "=== Тесты Фазы 3: Безопасность и архитектура ==="
echo ""

# ---------------------------------------------------------------------------
# 1. scripts/monitor/monitor-realtime.sh: нет eval
# ---------------------------------------------------------------------------
echo "--- 1. scripts/monitor/monitor-realtime.sh: убран eval ---"

if grep -qE '^\s*eval\s+"\$data"' scripts/monitor/monitor-realtime.sh; then
    fail "eval \"\$data\" всё ещё присутствует в scripts/monitor/monitor-realtime.sh"
else
    ok "eval \"\$data\" отсутствует в scripts/monitor/monitor-realtime.sh"
fi

if grep -q 'parse_kv' scripts/monitor/monitor-realtime.sh; then
    ok "parse_kv присутствует в scripts/monitor/monitor-realtime.sh"
else
    fail "parse_kv не найден в scripts/monitor/monitor-realtime.sh"
fi

# ---------------------------------------------------------------------------
# 2. scripts/monitor/monitor-realtime.sh: нет хардкода IP/ключей
# ---------------------------------------------------------------------------
echo ""
echo "--- 2. scripts/monitor/monitor-realtime.sh: нет хардкода дефолтов ---"

if grep -q '89\.169\.179\.233' scripts/monitor/monitor-realtime.sh; then
    fail "Хардкод IP 89.169.179.233 всё ещё присутствует в scripts/monitor/monitor-realtime.sh"
else
    ok "Хардкод IP 89.169.179.233 отсутствует в scripts/monitor/monitor-realtime.sh"
fi

if grep -q '38\.135\.122\.81' scripts/monitor/monitor-realtime.sh; then
    fail "Хардкод IP 38.135.122.81 всё ещё присутствует в scripts/monitor/monitor-realtime.sh"
else
    ok "Хардкод IP 38.135.122.81 отсутствует в scripts/monitor/monitor-realtime.sh"
fi

if grep -q 'ssh-key-1772056840349' scripts/monitor/monitor-realtime.sh; then
    fail "Хардкод SSH-ключа всё ещё присутствует в scripts/monitor/monitor-realtime.sh"
else
    ok "Хардкод SSH-ключа отсутствует в scripts/monitor/monitor-realtime.sh"
fi

# ---------------------------------------------------------------------------
# 3. scripts/monitor/monitor-web.sh: нет хардкода IP/ключей
# ---------------------------------------------------------------------------
echo ""
echo "--- 3. scripts/monitor/monitor-web.sh: нет хардкода дефолтов ---"

if grep -q '89\.169\.179\.233' scripts/monitor/monitor-web.sh; then
    fail "Хардкод IP 89.169.179.233 всё ещё присутствует в scripts/monitor/monitor-web.sh"
else
    ok "Хардкод IP 89.169.179.233 отсутствует в scripts/monitor/monitor-web.sh"
fi

if grep -q '38\.135\.122\.81' scripts/monitor/monitor-web.sh; then
    fail "Хардкод IP 38.135.122.81 всё ещё присутствует в scripts/monitor/monitor-web.sh"
else
    ok "Хардкод IP 38.135.122.81 отсутствует в scripts/monitor/monitor-web.sh"
fi

if grep -q 'ssh-key-1772056840349' scripts/monitor/monitor-web.sh; then
    fail "Хардкод SSH-ключа всё ещё присутствует в scripts/monitor/monitor-web.sh"
else
    ok "Хардкод SSH-ключа отсутствует в scripts/monitor/monitor-web.sh"
fi

# ---------------------------------------------------------------------------
# 4. Скрипты читают .env
# ---------------------------------------------------------------------------
echo ""
echo "--- 4. Скрипты читают .env ---"

grep -q 'load_defaults_from_files' scripts/monitor/monitor-web.sh \
    && ok "scripts/monitor/monitor-web.sh вызывает load_defaults_from_files" \
    || fail "scripts/monitor/monitor-web.sh не вызывает load_defaults_from_files"

grep -q 'load_defaults_from_files' scripts/monitor/monitor-realtime.sh \
    && ok "scripts/monitor/monitor-realtime.sh вызывает load_defaults_from_files" \
    || fail "scripts/monitor/monitor-realtime.sh не вызывает load_defaults_from_files"

# ---------------------------------------------------------------------------
# 5. scripts/tools/add_phone_peer.sh: параметризован
# ---------------------------------------------------------------------------
echo ""
echo "--- 5. scripts/tools/add_phone_peer.sh: параметризация ---"

grep -q '\-\-vps1-ip' scripts/tools/add_phone_peer.sh \
    && ok "scripts/tools/add_phone_peer.sh принимает --vps1-ip" \
    || fail "scripts/tools/add_phone_peer.sh не принимает --vps1-ip"

grep -q '\-\-peer-ip' scripts/tools/add_phone_peer.sh \
    && ok "scripts/tools/add_phone_peer.sh принимает --peer-ip" \
    || fail "scripts/tools/add_phone_peer.sh не принимает --peer-ip"

grep -q '\-\-peer-name' scripts/tools/add_phone_peer.sh \
    && ok "scripts/tools/add_phone_peer.sh принимает --peer-name" \
    || fail "scripts/tools/add_phone_peer.sh не принимает --peer-name"

grep -q 'seq 3' scripts/tools/add_phone_peer.sh \
    && ok "scripts/tools/add_phone_peer.sh содержит автоопределение IP" \
    || fail "scripts/tools/add_phone_peer.sh не содержит автоопределение IP"

grep -q 'load_defaults_from_files' scripts/tools/add_phone_peer.sh \
    && ok "scripts/tools/add_phone_peer.sh читает .env через load_defaults_from_files" \
    || fail "scripts/tools/add_phone_peer.sh не читает .env"

if grep -q '10\.9\.0\.3' scripts/tools/add_phone_peer.sh; then
    fail "Хардкод 10.9.0.3 всё ещё присутствует в scripts/tools/add_phone_peer.sh"
else
    ok "Хардкод 10.9.0.3 убран из scripts/tools/add_phone_peer.sh"
fi

# ---------------------------------------------------------------------------
# 6. config.yaml: CA-сервер на VPN-интерфейсе
# ---------------------------------------------------------------------------
echo ""
echo "--- 6. config.yaml: CA-сервер ограничен VPN-интерфейсом ---"

grep -q '10\.8\.0\.2:8080' youtube-proxy/config.yaml \
    && ok "CA-сервер слушает на 10.8.0.2:8080 (VPN-интерфейс)" \
    || fail "CA-сервер не ограничен VPN-интерфейсом"

if grep -q '0\.0\.0\.0:8080' youtube-proxy/config.yaml; then
    fail "CA-сервер всё ещё слушает на 0.0.0.0:8080"
else
    ok "CA-сервер не слушает на 0.0.0.0:8080"
fi

# ---------------------------------------------------------------------------
# 7. scripts/deploy/deploy-proxy.sh: firewall-правило для порта 8080
# ---------------------------------------------------------------------------
echo ""
echo "--- 7. scripts/deploy/deploy-proxy.sh: firewall для CA-сервера ---"

grep -qE 'iptables.*8080.*DROP|DROP.*8080' scripts/deploy/deploy-proxy.sh \
    && ok "scripts/deploy/deploy-proxy.sh блокирует порт 8080 снаружи" \
    || fail "scripts/deploy/deploy-proxy.sh не блокирует порт 8080 снаружи"

grep -qE 'iptables.*8080.*awg0|awg0.*8080' scripts/deploy/deploy-proxy.sh \
    && ok "scripts/deploy/deploy-proxy.sh разрешает порт 8080 только через awg0" \
    || fail "scripts/deploy/deploy-proxy.sh не ограничивает 8080 интерфейсом awg0"

if grep -q 'http://\$VPS2_IP:8080' scripts/deploy/deploy-proxy.sh; then
    fail "scripts/deploy/deploy-proxy.sh всё ещё содержит публичный URL CA (http://VPS2_IP:8080)"
else
    ok "scripts/deploy/deploy-proxy.sh не содержит публичный URL CA"
fi

grep -q '10\.8\.0\.2:8080' scripts/deploy/deploy-proxy.sh \
    && ok "scripts/deploy/deploy-proxy.sh указывает VPN-URL для CA (10.8.0.2:8080)" \
    || fail "scripts/deploy/deploy-proxy.sh не содержит VPN-URL для CA"

# ---------------------------------------------------------------------------
# 8. Go build проверка
# ---------------------------------------------------------------------------
echo ""
echo "--- 8. Go build youtube-proxy ---"

GO_BIN=""
for candidate in go ~/go/bin/go ~/go-dist/go/bin/go /usr/local/go/bin/go; do
    if command -v "$candidate" >/dev/null 2>&1; then
        GO_BIN="$candidate"
        break
    fi
done

if [[ -n "$GO_BIN" ]]; then
    if (cd youtube-proxy && "$GO_BIN" build ./... 2>&1); then
        ok "go build ./... успешен в youtube-proxy"
    else
        fail "go build ./... завершился с ошибкой"
    fi
else
    echo "  [SKIP] Go не найден, пропускаем go build"
fi

# ---------------------------------------------------------------------------
# Итог
# ---------------------------------------------------------------------------
echo ""
echo "================================"
if [[ "$FAIL" -eq 0 ]]; then
    echo "  PASS: $PASS  |  FAIL: $FAIL" 
    echo "================================"
    echo ""
    exit 0
else
    echo "  PASS: $PASS  |  FAIL: $FAIL"
    echo "================================"
    echo ""
    exit 1
fi
