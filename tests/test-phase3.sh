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
    fail "Хардкод устаревшего VPS1 IP всё ещё присутствует в scripts/monitor/monitor-realtime.sh"
else
    ok "Хардкод устаревшего VPS1 IP отсутствует в scripts/monitor/monitor-realtime.sh"
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
    fail "Хардкод устаревшего VPS1 IP всё ещё присутствует в scripts/monitor/monitor-web.sh"
else
    ok "Хардкод устаревшего VPS1 IP отсутствует в scripts/monitor/monitor-web.sh"
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
# 6. deploy.sh: legacy proxy flags are rejected
# ---------------------------------------------------------------------------
echo ""
echo "--- 6. scripts/deploy/deploy.sh: legacy proxy flags rejected ---"

if grep -q -- '--with-proxy|--remove-adguard' scripts/deploy/deploy.sh; then
    ok "deploy.sh явно отклоняет --with-proxy/--remove-adguard"
else
    fail "deploy.sh не отклоняет legacy proxy flags"
fi

# ---------------------------------------------------------------------------
# 7. manage.sh: legacy proxy mode is rejected
# ---------------------------------------------------------------------------
echo ""
echo "--- 7. manage.sh: legacy proxy mode rejected ---"

if grep -q -- '--proxy удалён' manage.sh; then
    ok "manage.sh явно отклоняет --proxy"
else
    fail "manage.sh не отклоняет --proxy"
fi

# ---------------------------------------------------------------------------
# 8. diagnose.sh: AdGuard Home is the DNS service
# ---------------------------------------------------------------------------
echo ""
echo "--- 8. scripts/tools/diagnose.sh: AdGuard Home checks ---"

if grep -q 'AdGuard Home' scripts/tools/diagnose.sh && grep -q 'port53' scripts/tools/diagnose.sh; then
    ok "diagnose.sh проверяет AdGuard Home и DNS port 53"
else
    fail "diagnose.sh не проверяет AdGuard Home/DNS"
fi

if grep -q 'systemctl start AdGuardHome' scripts/tools/diagnose.sh && grep -q 'Восстанавливаю legacy youtube-proxy' scripts/tools/diagnose.sh; then
    ok "diagnose.sh ремонтирует AdGuard Home и восстанавливает legacy DNS только при rollback"
else
    fail "diagnose.sh не содержит безопасный rollback legacy DNS при ошибке AdGuard"
fi

# ---------------------------------------------------------------------------
# 9. deploy scripts: safe AdGuard switch before legacy cleanup
# ---------------------------------------------------------------------------
echo ""
echo "--- 9. deploy scripts: safe AdGuard switch before legacy cleanup ---"

for deploy_file in scripts/deploy/deploy.sh scripts/deploy/deploy-vps2.sh; do
    if grep -q 'ADGUARD_WAS_ACTIVE' "$deploy_file" && \
       grep -q 'ADGUARD_CONFIG_BACKUP' "$deploy_file" && \
       grep -q 'LEGACY_YOUTUBE_PROXY_ACTIVE' "$deploy_file" && \
       grep -q 'restore_previous_dns' "$deploy_file" && \
       grep -q 'health_ok' "$deploy_file"; then
        ok "$deploy_file: есть rollback конфига/сервиса и healthcheck при переключении DNS"
    else
        fail "$deploy_file: нет полного rollback/healthcheck при переключении DNS"
    fi

    backup_line=$(grep -n 'ADGUARD_CONFIG_BACKUP=' "$deploy_file" | head -1 | cut -d: -f1)
    curl_line=$(grep -n 'curl -fsSL https://static.adguard.com' "$deploy_file" | head -1 | cut -d: -f1)
    health_line=$(grep -n 'health_ok=false' "$deploy_file" | head -1 | cut -d: -f1)
    cleanup_line=$(grep -n 'rm -rf /opt/youtube-proxy' "$deploy_file" | head -1 | cut -d: -f1)

    if [[ -n "$backup_line" && -n "$curl_line" && -n "$health_line" && -n "$cleanup_line" && \
          "$backup_line" -lt "$curl_line" && "$curl_line" -lt "$health_line" && "$health_line" -lt "$cleanup_line" ]]; then
        ok "$deploy_file: backup и legacy cleanup выполняются в безопасном порядке"
    else
        fail "$deploy_file: backup/cleanup порядок может сломать DNS при неудачном deploy"
    fi
done

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
