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
# 1. monitor-realtime.sh: нет eval
# ---------------------------------------------------------------------------
echo "--- 1. monitor-realtime.sh: убран eval ---"

if grep -qE '^\s*eval\s+"\$data"' monitor-realtime.sh; then
    fail "eval \"\$data\" всё ещё присутствует в monitor-realtime.sh"
else
    ok "eval \"\$data\" отсутствует в monitor-realtime.sh"
fi

if grep -q 'parse_kv' monitor-realtime.sh; then
    ok "parse_kv присутствует в monitor-realtime.sh"
else
    fail "parse_kv не найден в monitor-realtime.sh"
fi

# ---------------------------------------------------------------------------
# 2. monitor-realtime.sh: нет хардкода IP/ключей
# ---------------------------------------------------------------------------
echo ""
echo "--- 2. monitor-realtime.sh: нет хардкода дефолтов ---"

if grep -q '89\.169\.179\.233' monitor-realtime.sh; then
    fail "Хардкод IP 89.169.179.233 всё ещё присутствует в monitor-realtime.sh"
else
    ok "Хардкод IP 89.169.179.233 отсутствует в monitor-realtime.sh"
fi

if grep -q '38\.135\.122\.81' monitor-realtime.sh; then
    fail "Хардкод IP 38.135.122.81 всё ещё присутствует в monitor-realtime.sh"
else
    ok "Хардкод IP 38.135.122.81 отсутствует в monitor-realtime.sh"
fi

if grep -q 'ssh-key-1772056840349' monitor-realtime.sh; then
    fail "Хардкод SSH-ключа всё ещё присутствует в monitor-realtime.sh"
else
    ok "Хардкод SSH-ключа отсутствует в monitor-realtime.sh"
fi

# ---------------------------------------------------------------------------
# 3. monitor-web.sh: нет хардкода IP/ключей
# ---------------------------------------------------------------------------
echo ""
echo "--- 3. monitor-web.sh: нет хардкода дефолтов ---"

if grep -q '89\.169\.179\.233' monitor-web.sh; then
    fail "Хардкод IP 89.169.179.233 всё ещё присутствует в monitor-web.sh"
else
    ok "Хардкод IP 89.169.179.233 отсутствует в monitor-web.sh"
fi

if grep -q '38\.135\.122\.81' monitor-web.sh; then
    fail "Хардкод IP 38.135.122.81 всё ещё присутствует в monitor-web.sh"
else
    ok "Хардкод IP 38.135.122.81 отсутствует в monitor-web.sh"
fi

if grep -q 'ssh-key-1772056840349' monitor-web.sh; then
    fail "Хардкод SSH-ключа всё ещё присутствует в monitor-web.sh"
else
    ok "Хардкод SSH-ключа отсутствует в monitor-web.sh"
fi

# ---------------------------------------------------------------------------
# 4. Скрипты читают .env
# ---------------------------------------------------------------------------
echo ""
echo "--- 4. Скрипты читают .env ---"

grep -q 'load_defaults_from_files' monitor-web.sh \
    && ok "monitor-web.sh вызывает load_defaults_from_files" \
    || fail "monitor-web.sh не вызывает load_defaults_from_files"

grep -q 'load_defaults_from_files' monitor-realtime.sh \
    && ok "monitor-realtime.sh вызывает load_defaults_from_files" \
    || fail "monitor-realtime.sh не вызывает load_defaults_from_files"

# ---------------------------------------------------------------------------
# 5. add_phone_peer.sh: параметризован
# ---------------------------------------------------------------------------
echo ""
echo "--- 5. add_phone_peer.sh: параметризация ---"

grep -q '\-\-vps1-ip' add_phone_peer.sh \
    && ok "add_phone_peer.sh принимает --vps1-ip" \
    || fail "add_phone_peer.sh не принимает --vps1-ip"

grep -q '\-\-peer-ip' add_phone_peer.sh \
    && ok "add_phone_peer.sh принимает --peer-ip" \
    || fail "add_phone_peer.sh не принимает --peer-ip"

grep -q '\-\-peer-name' add_phone_peer.sh \
    && ok "add_phone_peer.sh принимает --peer-name" \
    || fail "add_phone_peer.sh не принимает --peer-name"

grep -q 'seq 3' add_phone_peer.sh \
    && ok "add_phone_peer.sh содержит автоопределение IP" \
    || fail "add_phone_peer.sh не содержит автоопределение IP"

grep -q 'load_defaults_from_files' add_phone_peer.sh \
    && ok "add_phone_peer.sh читает .env через load_defaults_from_files" \
    || fail "add_phone_peer.sh не читает .env"

if grep -q '10\.9\.0\.3' add_phone_peer.sh; then
    fail "Хардкод 10.9.0.3 всё ещё присутствует в add_phone_peer.sh"
else
    ok "Хардкод 10.9.0.3 убран из add_phone_peer.sh"
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
# 7. deploy-proxy.sh: firewall-правило для порта 8080
# ---------------------------------------------------------------------------
echo ""
echo "--- 7. deploy-proxy.sh: firewall для CA-сервера ---"

grep -qE 'iptables.*8080.*DROP|DROP.*8080' deploy-proxy.sh \
    && ok "deploy-proxy.sh блокирует порт 8080 снаружи" \
    || fail "deploy-proxy.sh не блокирует порт 8080 снаружи"

grep -qE 'iptables.*8080.*awg0|awg0.*8080' deploy-proxy.sh \
    && ok "deploy-proxy.sh разрешает порт 8080 только через awg0" \
    || fail "deploy-proxy.sh не ограничивает 8080 интерфейсом awg0"

if grep -q 'http://\$VPS2_IP:8080' deploy-proxy.sh; then
    fail "deploy-proxy.sh всё ещё содержит публичный URL CA (http://VPS2_IP:8080)"
else
    ok "deploy-proxy.sh не содержит публичный URL CA"
fi

grep -q '10\.8\.0\.2:8080' deploy-proxy.sh \
    && ok "deploy-proxy.sh указывает VPN-URL для CA (10.8.0.2:8080)" \
    || fail "deploy-proxy.sh не содержит VPN-URL для CA"

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
