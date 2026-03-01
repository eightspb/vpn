#!/usr/bin/env bash
# =============================================================================
# tests/test-reorganize.sh — проверки после реорганизации файлов проекта
#
# Проверяет:
#   1. Все файлы на новых местах
#   2. Старые файлы удалены из корня
#   3. source-пути в перемещённых скриптах валидны
#   4. manage.sh ссылается на новые пути
#   5. Тесты ссылаются на новые пути
#   6. Внутренние ссылки скриптов корректны
#
# Запуск: bash tests/test-reorganize.sh
# =============================================================================

set -u

PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "=== Тесты реорганизации файлов проекта ==="
echo ""

# =============================================================================
# 1. Файлы на новых местах
# =============================================================================
echo "--- 1. Файлы на новых местах ---"

EXPECTED_FILES=(
    "scripts/deploy/deploy.sh"
    "scripts/deploy/deploy-vps1.sh"
    "scripts/deploy/deploy-vps2.sh"
    "scripts/deploy/deploy-proxy.sh"
    "scripts/deploy/security-update.sh"
    "scripts/monitor/monitor-realtime.sh"
    "scripts/monitor/monitor-web.sh"
    "scripts/monitor/dashboard.html"
    "scripts/tools/add_phone_peer.sh"
    "scripts/tools/benchmark.sh"
    "scripts/tools/check_ping.sh"
    "scripts/tools/diagnose.sh"
    "scripts/tools/generate-all-configs.sh"
    "scripts/tools/load-test.sh"
    "scripts/tools/optimize-vpn.sh"
    "scripts/tools/repair-vps1.sh"
    "scripts/windows/install-ca.ps1"
    "scripts/windows/repair-local-configs.ps1"
)

for f in "${EXPECTED_FILES[@]}"; do
    if [[ -f "$f" ]]; then
        ok "$f существует"
    else
        fail "$f НЕ найден"
    fi
done

# =============================================================================
# 2. Старые файлы удалены из корня
# =============================================================================
echo ""
echo "--- 2. Старые файлы удалены из корня ---"

OLD_FILES=(
    "deploy.sh"
    "deploy-vps1.sh"
    "deploy-vps2.sh"
    "deploy-proxy.sh"
    "security-update.sh"
    "monitor-realtime.sh"
    "monitor-web.sh"
    "dashboard.html"
    "add_phone_peer.sh"
    "benchmark.sh"
    "check_ping.sh"
    "diagnose.sh"
    "generate-all-configs.sh"
    "load-test.sh"
    "optimize-vpn.sh"
    "repair-vps1.sh"
    "install-ca.ps1"
    "repair-local-configs.ps1"
)

for f in "${OLD_FILES[@]}"; do
    if [[ ! -f "$f" ]]; then
        ok "$f удалён из корня"
    else
        fail "$f всё ещё в корне"
    fi
done

# =============================================================================
# 3. manage.sh ссылается на новые пути
# =============================================================================
echo ""
echo "--- 3. manage.sh: новые пути к скриптам ---"

check_manage_ref() {
    local pattern="$1" desc="$2"
    if grep -q "$pattern" manage.sh 2>/dev/null; then
        ok "manage.sh: $desc"
    else
        fail "manage.sh: $desc НЕ найден"
    fi
}

check_manage_ref 'scripts/deploy/deploy\.sh'          "ссылка на scripts/deploy/deploy.sh"
check_manage_ref 'scripts/deploy/deploy-vps1\.sh'     "ссылка на scripts/deploy/deploy-vps1.sh"
check_manage_ref 'scripts/deploy/deploy-vps2\.sh'     "ссылка на scripts/deploy/deploy-vps2.sh"
check_manage_ref 'scripts/deploy/deploy-proxy\.sh'    "ссылка на scripts/deploy/deploy-proxy.sh"
check_manage_ref 'scripts/monitor/monitor-realtime\.sh' "ссылка на scripts/monitor/monitor-realtime.sh"
check_manage_ref 'scripts/monitor/monitor-web\.sh'    "ссылка на scripts/monitor/monitor-web.sh"
check_manage_ref 'scripts/tools/add_phone_peer\.sh'   "ссылка на scripts/tools/add_phone_peer.sh"
check_manage_ref 'scripts/tools/check_ping\.sh'       "ссылка на scripts/tools/check_ping.sh"

# Старые пути должны отсутствовать
check_manage_no_ref() {
    local pattern="$1" desc="$2"
    if ! grep -qE "SCRIPT_DIR\}/${pattern}" manage.sh 2>/dev/null; then
        ok "manage.sh: старый путь '${pattern}' отсутствует"
    else
        fail "manage.sh: старый путь '${pattern}' всё ещё присутствует"
    fi
}

check_manage_no_ref 'deploy\.sh[^/]'          "deploy.sh без подпапки"
check_manage_no_ref 'monitor-realtime\.sh[^/]' "monitor-realtime.sh без подпапки"
check_manage_no_ref 'add_phone_peer\.sh[^/]'   "add_phone_peer.sh без подпапки"

# =============================================================================
# 4. source-пути в перемещённых скриптах
# =============================================================================
echo ""
echo "--- 4. source-пути: ../../lib/common.sh ---"

for script in scripts/tools/benchmark.sh scripts/tools/load-test.sh scripts/tools/optimize-vpn.sh; do
    if [[ ! -f "$script" ]]; then
        fail "$script не найден"
        continue
    fi
    if grep -q 'source.*\.\./\.\./lib/common\.sh' "$script" 2>/dev/null; then
        ok "$script: source ../../lib/common.sh"
    else
        fail "$script: source ../../lib/common.sh НЕ найден"
    fi
    # Старый путь не должен остаться
    if ! grep -qE 'source.*\$\{SCRIPT_DIR\}/lib/common\.sh' "$script" 2>/dev/null; then
        ok "$script: старый source путь отсутствует"
    else
        fail "$script: старый source путь всё ещё присутствует"
    fi
done

# =============================================================================
# 5. deploy-proxy.sh: PROXY_DIR указывает на ../../youtube-proxy
# =============================================================================
echo ""
echo "--- 5. scripts/deploy/deploy-proxy.sh: PROXY_DIR ---"

if [[ -f "scripts/deploy/deploy-proxy.sh" ]]; then
    if grep -q 'PROXY_DIR=.*\.\./\.\./youtube-proxy' scripts/deploy/deploy-proxy.sh 2>/dev/null; then
        ok "deploy-proxy.sh: PROXY_DIR указывает на ../../youtube-proxy"
    else
        fail "deploy-proxy.sh: PROXY_DIR не обновлён (ожидается ../../youtube-proxy)"
    fi
else
    fail "scripts/deploy/deploy-proxy.sh не найден"
fi

# =============================================================================
# 6. monitor-web.sh: JSON_FILE обновлён
# =============================================================================
echo ""
echo "--- 6. scripts/monitor/monitor-web.sh: JSON_FILE ---"

if [[ -f "scripts/monitor/monitor-web.sh" ]]; then
    if grep -q 'JSON_FILE=.*\.\./\.\./vpn-output/data\.json' scripts/monitor/monitor-web.sh 2>/dev/null; then
        ok "monitor-web.sh: JSON_FILE указывает на ../../vpn-output/data.json"
    else
        fail "monitor-web.sh: JSON_FILE не обновлён (ожидается ../../vpn-output/data.json)"
    fi
    if ! grep -q 'JSON_FILE="\./vpn-output/data\.json"' scripts/monitor/monitor-web.sh 2>/dev/null; then
        ok "monitor-web.sh: старый JSON_FILE путь отсутствует"
    else
        fail "monitor-web.sh: старый JSON_FILE путь ./vpn-output/data.json всё ещё присутствует"
    fi
else
    fail "scripts/monitor/monitor-web.sh не найден"
fi

# =============================================================================
# 7. Синтаксис bash перемещённых скриптов
# =============================================================================
echo ""
echo "--- 7. Синтаксис bash перемещённых скриптов ---"

BASH_SCRIPTS=(
    "scripts/deploy/deploy.sh"
    "scripts/deploy/deploy-vps1.sh"
    "scripts/deploy/deploy-vps2.sh"
    "scripts/deploy/deploy-proxy.sh"
    "scripts/deploy/security-update.sh"
    "scripts/monitor/monitor-realtime.sh"
    "scripts/monitor/monitor-web.sh"
    "scripts/tools/add_phone_peer.sh"
    "scripts/tools/benchmark.sh"
    "scripts/tools/check_ping.sh"
    "scripts/tools/diagnose.sh"
    "scripts/tools/generate-all-configs.sh"
    "scripts/tools/load-test.sh"
    "scripts/tools/optimize-vpn.sh"
    "scripts/tools/repair-vps1.sh"
)

for script in "${BASH_SCRIPTS[@]}"; do
    if [[ ! -f "$script" ]]; then
        fail "$script не найден"
        continue
    fi
    if bash -n <(tr -d '\r' < "$script") 2>/dev/null; then
        ok "$script: синтаксис корректен"
    else
        fail "$script: ошибка синтаксиса bash"
    fi
done

# =============================================================================
# 8. Тесты ссылаются на новые пути (выборочная проверка)
# =============================================================================
echo ""
echo "--- 8. Тесты: новые пути к скриптам ---"

check_test_ref() {
    local file="$1" pattern="$2" desc="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        ok "$file: $desc"
    else
        fail "$file: $desc НЕ найден"
    fi
}

check_test_no_ref() {
    local file="$1" pattern="$2" desc="$3"
    if ! grep -qE "\"${pattern}\"|\b${pattern}\b" "$file" 2>/dev/null; then
        ok "$file: $desc отсутствует"
    else
        fail "$file: $desc всё ещё присутствует"
    fi
}

# test-phase3.sh
if [[ -f "tests/test-phase3.sh" ]]; then
    check_test_ref "tests/test-phase3.sh" "scripts/monitor/monitor-realtime\.sh" "ссылка на scripts/monitor/monitor-realtime.sh"
    check_test_ref "tests/test-phase3.sh" "scripts/monitor/monitor-web\.sh"      "ссылка на scripts/monitor/monitor-web.sh"
    check_test_ref "tests/test-phase3.sh" "scripts/deploy/deploy-proxy\.sh"      "ссылка на scripts/deploy/deploy-proxy.sh"
fi

# test-phase4.sh
if [[ -f "tests/test-phase4.sh" ]]; then
    check_test_ref "tests/test-phase4.sh" "scripts/deploy/deploy\.sh"     "ссылка на scripts/deploy/deploy.sh"
    check_test_ref "tests/test-phase4.sh" "scripts/deploy/deploy-vps1\.sh" "ссылка на scripts/deploy/deploy-vps1.sh"
fi

# test-phase5.sh
if [[ -f "tests/test-phase5.sh" ]]; then
    check_test_ref "tests/test-phase5.sh" "scripts/deploy/deploy\.sh"     "ссылка на scripts/deploy/deploy.sh"
    check_test_ref "tests/test-phase5.sh" "scripts/tools/add_phone_peer\.sh" "ссылка на scripts/tools/add_phone_peer.sh"
fi

# test-monitor-web.sh
if [[ -f "tests/test-monitor-web.sh" ]]; then
    check_test_ref "tests/test-monitor-web.sh" "scripts/monitor/monitor-web\.sh" "ссылка на scripts/monitor/monitor-web.sh"
    check_test_ref "tests/test-monitor-web.sh" "scripts/monitor/dashboard\.html" "ссылка на scripts/monitor/dashboard.html"
    check_test_ref "tests/test-monitor-web.sh" "scripts/deploy/deploy-proxy\.sh" "ссылка на scripts/deploy/deploy-proxy.sh"
fi

# test-optimize.sh
if [[ -f "tests/test-optimize.sh" ]]; then
    check_test_ref "tests/test-optimize.sh" "scripts/tools/optimize-vpn\.sh" "ссылка на scripts/tools/optimize-vpn.sh"
    check_test_ref "tests/test-optimize.sh" "scripts/tools/benchmark\.sh"    "ссылка на scripts/tools/benchmark.sh"
fi

# test-load-test.sh
if [[ -f "tests/test-load-test.sh" ]]; then
    check_test_ref "tests/test-load-test.sh" "scripts/tools/load-test\.sh" "ссылка на scripts/tools/load-test.sh"
fi

# =============================================================================
# 9. Корневые файлы на месте
# =============================================================================
echo ""
echo "--- 9. Корневые файлы на месте ---"

ROOT_FILES=("manage.sh" "lib/common.sh" "README.md" ".env.example" ".gitignore" ".gitattributes")
for f in "${ROOT_FILES[@]}"; do
    if [[ -f "$f" ]]; then
        ok "$f на месте"
    else
        fail "$f отсутствует"
    fi
done

# youtube-proxy/ и tests/ без изменений
if [[ -d "youtube-proxy" ]]; then
    ok "youtube-proxy/ на месте"
else
    fail "youtube-proxy/ отсутствует"
fi

if [[ -d "tests" ]]; then
    ok "tests/ на месте"
else
    fail "tests/ отсутствует"
fi

# =============================================================================
# Итог
# =============================================================================
echo ""
echo "=============================="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "=============================="
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo "Все тесты прошли успешно."
    exit 0
else
    echo "Есть провалившиеся тесты: $FAIL"
    exit 1
fi
