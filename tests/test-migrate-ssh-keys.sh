#!/usr/bin/env bash
# =============================================================================
# test-migrate-ssh-keys.sh — тесты для migrate-ssh-keys.sh
#
# Проверяет:
#   1. .ssh/ папка создана в проекте
#   2. Ключи скопированы с правильными правами
#   3. .gitignore содержит .ssh/
#   4. .env указывает на .ssh/ (не на ~/.ssh/)
#   5. .env.example указывает на .ssh/
#   6. lib/common.sh ищет ключи в .ssh/ проекта
#   7. Нет захардкоженных ~/.ssh/ssh-key-* в скриптах
#   8. manage.sh не содержит старых путей
#   9. README.md не содержит старых путей
#
# Использование:
#   bash tests/test-migrate-ssh-keys.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0; TOTAL=0

check() {
    local desc="$2"
    TOTAL=$((TOTAL + 1))
    if eval "$1"; then
        printf "\033[0;32m  ✓\033[0m %s\n" "$desc"
        PASS=$((PASS + 1))
    else
        printf "\033[0;31m  ✗\033[0m %s\n" "$desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "═══════════════════════════════════════════════════"
echo " Тесты миграции SSH-ключей"
echo "═══════════════════════════════════════════════════"
echo ""

# ── 1. .ssh/ папка существует ─────────────────────────────────────────────────
echo "── 1. Папка .ssh/ ──"
check "[[ -d '${PROJECT_ROOT}/.ssh' ]]" ".ssh/ папка существует в проекте"

# ── 2. Ключи скопированы ─────────────────────────────────────────────────────
echo ""
echo "── 2. SSH-ключи скопированы ──"

read_kv() {
    awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"",$0); gsub(/\r/,""); gsub(/^[ \t'"'"']+|[ \t'"'"']+$/,""); print; exit}' "$1" 2>/dev/null
}

VPS1_KEY="$(read_kv "${PROJECT_ROOT}/.env" VPS1_KEY)"
VPS2_KEY="$(read_kv "${PROJECT_ROOT}/.env" VPS2_KEY)"

check "[[ -f '${PROJECT_ROOT}/${VPS1_KEY}' ]]" "VPS1_KEY файл существует: $VPS1_KEY"
check "[[ -f '${PROJECT_ROOT}/${VPS2_KEY}' ]]" "VPS2_KEY файл существует: $VPS2_KEY"

if [[ -f "${PROJECT_ROOT}/${VPS1_KEY}" ]]; then
    perms="$(stat -c '%a' "${PROJECT_ROOT}/${VPS1_KEY}" 2>/dev/null || stat -f '%Lp' "${PROJECT_ROOT}/${VPS1_KEY}" 2>/dev/null || echo "unknown")"
    # На NTFS (Windows/WSL) chmod не работает — права всегда 777; prepare_key_for_ssh обрабатывает это
    if [[ "${PROJECT_ROOT}" == /mnt/* ]]; then
        check "[[ '$perms' == '600' || '$perms' == '777' || '$perms' == '755' ]]" "VPS1_KEY права допустимы на NTFS (текущие: $perms)"
    else
        check "[[ '$perms' == '600' ]]" "VPS1_KEY права 600 (текущие: $perms)"
    fi
fi

# ── 3. .gitignore ─────────────────────────────────────────────────────────────
echo ""
echo "── 3. .gitignore ──"
check "grep -qF '.ssh/' '${PROJECT_ROOT}/.gitignore'" ".gitignore содержит .ssh/"

# ── 4. .env пути ─────────────────────────────────────────────────────────────
echo ""
echo "── 4. .env пути ──"
check "[[ '$VPS1_KEY' == .ssh/* ]]" ".env VPS1_KEY начинается с .ssh/ ($VPS1_KEY)"
check "[[ '$VPS2_KEY' == .ssh/* ]]" ".env VPS2_KEY начинается с .ssh/ ($VPS2_KEY)"
check "! grep -q '~/.ssh/' '${PROJECT_ROOT}/.env'" ".env не содержит ~/.ssh/"

# ── 5. .env.example ──────────────────────────────────────────────────────────
echo ""
echo "── 5. .env.example ──"
if [[ -f "${PROJECT_ROOT}/.env.example" ]]; then
    EX_VPS1="$(read_kv "${PROJECT_ROOT}/.env.example" VPS1_KEY)"
    EX_VPS2="$(read_kv "${PROJECT_ROOT}/.env.example" VPS2_KEY)"
    check "[[ '$EX_VPS1' == .ssh/* ]]" ".env.example VPS1_KEY = $EX_VPS1"
    check "[[ '$EX_VPS2' == .ssh/* ]]" ".env.example VPS2_KEY = $EX_VPS2"
else
    check "false" ".env.example существует"
fi

# ── 6. lib/common.sh ─────────────────────────────────────────────────────────
echo ""
echo "── 6. lib/common.sh (auto_pick_key_if_missing) ──"
check "grep -q 'project_ssh_dir' '${PROJECT_ROOT}/lib/common.sh'" "common.sh содержит поиск в project_ssh_dir"

# ── 7. Нет старых путей в тестовых скриптах ───────────────────────────────────
echo ""
echo "── 7. Нет ~/.ssh/ssh-key-* в тестовых скриптах ──"

OLD_KEY='~/.ssh/ssh-key-1772056840349'
TEST_SCRIPTS=(
    "tests/dump_awg_conf.sh"
    "tests/check_vps1_keys.sh"
    "tests/find_awg_conf3.sh"
    "tests/find_awg_conf2.sh"
    "tests/find_awg_conf.sh"
    "tests/check_awg1_journal.sh"
    "tests/check_cert_san.sh"
    "tests/check_vps1_full_conf.sh"
    "tests/check_vps1_conf.sh"
    "tests/check_awg_state.sh"
)

for script in "${TEST_SCRIPTS[@]}"; do
    full="${PROJECT_ROOT}/${script}"
    if [[ -f "$full" ]]; then
        check "! grep -qF '$OLD_KEY' '$full'" "$script не содержит старый путь"
    else
        check "false" "$script существует"
    fi
done

# ── 8. manage.sh ─────────────────────────────────────────────────────────────
echo ""
echo "── 8. manage.sh ──"
check "! grep -qF '$OLD_KEY' '${PROJECT_ROOT}/manage.sh'" "manage.sh не содержит старый ssh-key путь"
check "! grep -qF '~/.ssh/id_rsa' '${PROJECT_ROOT}/manage.sh'" "manage.sh не содержит ~/.ssh/id_rsa"

# ── 9. README.md ─────────────────────────────────────────────────────────────
echo ""
echo "── 9. README.md ──"
check "! grep -qF '$OLD_KEY' '${PROJECT_ROOT}/README.md'" "README.md не содержит старый ssh-key путь"

# ── Итог ─────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
if [[ $FAIL -eq 0 ]]; then
    printf "\033[0;32m  Все тесты пройдены: %d/%d\033[0m\n" "$PASS" "$TOTAL"
else
    printf "\033[0;31m  Провалено: %d/%d (прошло: %d)\033[0m\n" "$FAIL" "$TOTAL" "$PASS"
fi
echo "═══════════════════════════════════════════════════"

exit $FAIL
