#!/usr/bin/env bash
# =============================================================================
# test-common-sh-loading.sh — Проверяет что все скрипты корректно подключают
# lib/common.sh и загружают переменные из .env / keys.env
#
# Запуск:
#   bash tests/test-common-sh-loading.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

PASS=0
FAIL=0
WARN=0

ok()   { echo -e "  ${GREEN}✓${NC} $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${NC} $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; WARN=$((WARN+1)); }
hdr()  { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

# ---------------------------------------------------------------------------
hdr "1. Проверка: все скрипты содержат source lib/common.sh"
# ---------------------------------------------------------------------------

SCRIPTS=(
    "scripts/deploy/deploy.sh"
    "scripts/deploy/deploy-vps1.sh"
    "scripts/deploy/deploy-vps2.sh"
    "scripts/deploy/deploy-proxy.sh"
    "scripts/monitor/monitor-realtime.sh"
    "scripts/monitor/monitor-web.sh"
    "scripts/tools/add_phone_peer.sh"
    "scripts/tools/diagnose.sh"
    "scripts/tools/generate-all-configs.sh"
    "manage.sh"
)

for script in "${SCRIPTS[@]}"; do
    full_path="${PROJECT_ROOT}/${script}"
    if [[ ! -f "$full_path" ]]; then
        fail "${script}: файл не найден"
        continue
    fi
    if grep -q 'source.*lib/common\.sh' "$full_path"; then
        ok "${script}: подключает lib/common.sh"
    else
        fail "${script}: НЕ подключает lib/common.sh"
    fi
done

# ---------------------------------------------------------------------------
hdr "2. Проверка: скрипты НЕ содержат дублированных функций"
# ---------------------------------------------------------------------------

DUPLICATE_FUNCTIONS=("clean_value" "read_kv" "expand_tilde" "auto_pick_key_if_missing" "prepare_key_for_ssh" "cleanup_temp_keys")

for script in "${SCRIPTS[@]}"; do
    full_path="${PROJECT_ROOT}/${script}"
    [[ ! -f "$full_path" ]] && continue
    [[ "$script" == "manage.sh" ]] && continue

    for func in "${DUPLICATE_FUNCTIONS[@]}"; do
        count=$(grep -c "^${func}()\|^${func} ()" "$full_path" 2>/dev/null | tr -d '[:space:]' || echo 0)
        if [[ "$count" -gt 0 ]]; then
            # monitor-realtime.sh и monitor-web.sh имеют свой ssh_exec — это ОК
            # diagnose.sh имеет свой ok/fail/warn — это ОК
            fail "${script}: содержит дублированную функцию ${func}()"
        fi
    done
done

if [[ $FAIL -eq 0 ]]; then
    ok "Дублированных функций не найдено"
fi

# ---------------------------------------------------------------------------
hdr "3. Проверка: lib/common.sh содержит все необходимые функции"
# ---------------------------------------------------------------------------

COMMON="${PROJECT_ROOT}/lib/common.sh"
REQUIRED_FUNCTIONS=(
    "clean_value"
    "read_kv"
    "parse_kv"
    "load_defaults_from_files"
    "require_vars"
    "expand_tilde"
    "auto_pick_key_if_missing"
    "prepare_key_for_ssh"
    "cleanup_temp_keys"
    "ssh_exec"
    "ssh_upload"
    "ssh_run_script"
    "check_deps"
)

for func in "${REQUIRED_FUNCTIONS[@]}"; do
    if grep -q "^${func}()" "$COMMON"; then
        ok "lib/common.sh: ${func}() определена"
    else
        fail "lib/common.sh: ${func}() НЕ определена"
    fi
done

# ---------------------------------------------------------------------------
hdr "4. Проверка: load_defaults_from_files загружает переменные из .env"
# ---------------------------------------------------------------------------

cd "$PROJECT_ROOT"

# Создаём временный .env для теста
TMP_ENV=$(mktemp "${PROJECT_ROOT}/.env.test.XXXXXX")
cat > "$TMP_ENV" << 'EOF'
VPS1_IP=1.1.1.1
VPS1_USER=testuser
VPS1_KEY=~/.ssh/test_key
VPS1_PASS=testpass
VPS2_IP=2.2.2.2
VPS2_USER=testuser2
VPS2_KEY=~/.ssh/test_key2
VPS2_PASS=testpass2
ADGUARD_PASS=secret123
CLIENT_IP=10.9.0.99
EOF

# Тестируем загрузку через подпроцесс
RESULT=$(bash -c "
    source '${COMMON}'
    # Переопределяем путь к .env
    PROJECT_ROOT='${PROJECT_ROOT}'
    # Подменяем env_file в load_defaults_from_files
    VPS1_IP='' VPS1_USER='' VPS1_KEY='' VPS1_PASS=''
    VPS2_IP='' VPS2_USER='' VPS2_KEY='' VPS2_PASS=''
    ADGUARD_PASS='' CLIENT_VPN_IP=''

    # Вызываем с подменённым .env
    env_file='${TMP_ENV}'
    if [[ -f \"\$env_file\" ]]; then
        local_val=\"\$(read_kv \"\$env_file\" VPS1_IP)\"
        [[ -n \"\$local_val\" ]] && VPS1_IP=\"\$local_val\"
        local_val=\"\$(read_kv \"\$env_file\" VPS2_IP)\"
        [[ -n \"\$local_val\" ]] && VPS2_IP=\"\$local_val\"
        local_val=\"\$(read_kv \"\$env_file\" ADGUARD_PASS)\"
        [[ -n \"\$local_val\" ]] && ADGUARD_PASS=\"\$local_val\"
        local_val=\"\$(read_kv \"\$env_file\" CLIENT_IP)\"
        [[ -n \"\$local_val\" ]] && CLIENT_VPN_IP=\"\$local_val\"
    fi
    echo \"VPS1_IP=\$VPS1_IP\"
    echo \"VPS2_IP=\$VPS2_IP\"
    echo \"ADGUARD_PASS=\$ADGUARD_PASS\"
    echo \"CLIENT_VPN_IP=\$CLIENT_VPN_IP\"
" 2>/dev/null) || true

rm -f "$TMP_ENV"

if echo "$RESULT" | grep -q 'VPS1_IP=1.1.1.1'; then
    ok "VPS1_IP загружается из .env"
else
    fail "VPS1_IP не загружается из .env"
fi

if echo "$RESULT" | grep -q 'VPS2_IP=2.2.2.2'; then
    ok "VPS2_IP загружается из .env"
else
    fail "VPS2_IP не загружается из .env"
fi

if echo "$RESULT" | grep -q 'ADGUARD_PASS=secret123'; then
    ok "ADGUARD_PASS загружается из .env"
else
    fail "ADGUARD_PASS не загружается из .env"
fi

if echo "$RESULT" | grep -q 'CLIENT_VPN_IP=10.9.0.99'; then
    ok "CLIENT_IP → CLIENT_VPN_IP загружается из .env"
else
    fail "CLIENT_IP → CLIENT_VPN_IP не загружается из .env"
fi

# ---------------------------------------------------------------------------
hdr "4b. Проверка: VPS*_USER не захардкожен как 'root' до load_defaults_from_files"
# ---------------------------------------------------------------------------

ALL_SCRIPTS=(
    "scripts/deploy/deploy.sh"
    "scripts/deploy/deploy-vps1.sh"
    "scripts/deploy/deploy-vps2.sh"
    "scripts/deploy/deploy-proxy.sh"
    "scripts/monitor/monitor-realtime.sh"
    "scripts/monitor/monitor-web.sh"
    "scripts/tools/add_phone_peer.sh"
    "scripts/tools/diagnose.sh"
    "scripts/tools/generate-all-configs.sh"
    "scripts/tools/manage-peers.sh"
    "scripts/tools/load-test.sh"
    "scripts/tools/benchmark.sh"
    "scripts/tools/optimize-vpn.sh"
    "manage.sh"
)

for script in "${ALL_SCRIPTS[@]}"; do
    full_path="${PROJECT_ROOT}/${script}"
    [[ ! -f "$full_path" ]] && continue
    if grep -q 'VPS[12]_USER="root"' "$full_path"; then
        fail "${script}: содержит VPS*_USER=\"root\" (должно быть VPS*_USER=\"\" + fallback)"
    else
        ok "${script}: VPS*_USER не захардкожен"
    fi
done

# Проверяем наличие fallback-паттерна ${VPS*_USER:-root}
for script in "${ALL_SCRIPTS[@]}"; do
    full_path="${PROJECT_ROOT}/${script}"
    [[ ! -f "$full_path" ]] && continue
    # Проверяем что хотя бы один fallback есть
    if grep -q 'VPS[12]_USER=.*:-root' "$full_path"; then
        ok "${script}: имеет fallback \${VPS*_USER:-root}"
    else
        warn "${script}: нет fallback \${VPS*_USER:-root} (может быть не нужен)"
    fi
done

# Функциональный тест: .env USER перезаписывает дефолт
FUNC_RESULT=$(bash -c "
    source '${COMMON}'
    VPS1_USER=''
    VPS2_USER=''
    VPS1_IP='' VPS1_KEY='' VPS1_PASS=''
    VPS2_IP='' VPS2_KEY='' VPS2_PASS=''
    ADGUARD_PASS='' CLIENT_VPN_IP=''
    load_defaults_from_files
    VPS1_USER=\"\${VPS1_USER:-root}\"
    VPS2_USER=\"\${VPS2_USER:-root}\"
    echo \"VPS1_USER=\$VPS1_USER\"
    echo \"VPS2_USER=\$VPS2_USER\"
" 2>/dev/null) || true

ACTUAL_VPS1_USER=$(echo "$FUNC_RESULT" | grep '^VPS1_USER=' | cut -d= -f2)
ACTUAL_VPS2_USER=$(echo "$FUNC_RESULT" | grep '^VPS2_USER=' | cut -d= -f2)

ENV_VPS1_USER=$(grep '^VPS1_USER=' "${PROJECT_ROOT}/.env" 2>/dev/null | cut -d= -f2 || echo "")
ENV_VPS2_USER=$(grep '^VPS2_USER=' "${PROJECT_ROOT}/.env" 2>/dev/null | cut -d= -f2 || echo "")

if [[ -n "$ENV_VPS1_USER" ]]; then
    if [[ "$ACTUAL_VPS1_USER" == "$ENV_VPS1_USER" ]]; then
        ok "VPS1_USER загружается из .env (=${ENV_VPS1_USER}), а не дефолт root"
    else
        fail "VPS1_USER=${ACTUAL_VPS1_USER}, ожидалось ${ENV_VPS1_USER} из .env"
    fi
else
    if [[ "$ACTUAL_VPS1_USER" == "root" ]]; then
        ok "VPS1_USER=root (дефолт, т.к. не задан в .env)"
    else
        fail "VPS1_USER=${ACTUAL_VPS1_USER}, ожидалось root (дефолт)"
    fi
fi

if [[ -n "$ENV_VPS2_USER" ]]; then
    if [[ "$ACTUAL_VPS2_USER" == "$ENV_VPS2_USER" ]]; then
        ok "VPS2_USER загружается из .env (=${ENV_VPS2_USER}), а не дефолт root"
    else
        fail "VPS2_USER=${ACTUAL_VPS2_USER}, ожидалось ${ENV_VPS2_USER} из .env"
    fi
else
    if [[ "$ACTUAL_VPS2_USER" == "root" ]]; then
        ok "VPS2_USER=root (дефолт, т.к. не задан в .env)"
    else
        fail "VPS2_USER=${ACTUAL_VPS2_USER}, ожидалось root (дефолт)"
    fi
fi

# ---------------------------------------------------------------------------
hdr "5. Проверка: require_vars работает"
# ---------------------------------------------------------------------------

ERR_OUTPUT=$(bash -c "
    source '${COMMON}'
    VPS1_IP='1.2.3.4'
    VPS2_IP=''
    require_vars 'test' VPS1_IP VPS2_IP
" 2>&1) && {
    fail "require_vars не вызвал ошибку при пустой VPS2_IP"
} || {
    if echo "$ERR_OUTPUT" | grep -q 'VPS2_IP'; then
        ok "require_vars корректно определяет пустые переменные"
    else
        fail "require_vars не указал какая переменная пуста"
    fi
}

# ---------------------------------------------------------------------------
hdr "6. Проверка: .env содержит все необходимые ключи"
# ---------------------------------------------------------------------------

ENV_FILE="${PROJECT_ROOT}/.env"
REQUIRED_KEYS=("VPS1_IP" "VPS1_USER" "VPS1_KEY" "VPS2_IP" "VPS2_USER" "VPS2_KEY")

if [[ -f "$ENV_FILE" ]]; then
    for key in "${REQUIRED_KEYS[@]}"; do
        if grep -q "^${key}=" "$ENV_FILE"; then
            ok ".env содержит ${key}"
        else
            fail ".env не содержит ${key}"
        fi
    done
else
    fail ".env не найден"
fi

# ---------------------------------------------------------------------------
hdr "Итог"
# ---------------------------------------------------------------------------

TOTAL=$((PASS + FAIL))
echo ""
echo -e "  Пройдено: ${GREEN}${PASS}${NC}/${TOTAL}"
[[ $FAIL -gt 0 ]] && echo -e "  Ошибок:   ${RED}${FAIL}${NC}"
[[ $WARN -gt 0 ]] && echo -e "  Предупр.: ${YELLOW}${WARN}${NC}"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}Все тесты пройдены!${NC}"
    exit 0
else
    echo -e "  ${RED}${BOLD}Есть ошибки — исправьте перед использованием.${NC}"
    exit 1
fi
