#!/usr/bin/env bash
# =============================================================================
# tests/test-cleanup-legacy.sh — проверки после удаления legacy-файлов
#
# Запуск: bash tests/test-cleanup-legacy.sh
# =============================================================================

set -u

PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "=== Тесты чистки legacy-файлов ==="
echo ""

# =============================================================================
# 1. Legacy-файлы удалены из корня
# =============================================================================
echo "--- 1. Legacy-файлы удалены ---"

for f in phase4-cleanup.sh vpn-dashboard-nginx.conf ru-ips.txt; do
    if [[ ! -f "$f" ]]; then
        ok "$f удалён"
    else
        fail "$f всё ещё существует"
    fi
done

# =============================================================================
# 2. README.md: пути generate-split-config.py обновлены
# =============================================================================
echo ""
echo "--- 2. README.md: пути generate-split-config.py ---"

if grep -q 'scripts/tools/generate-split-config\.py' README.md 2>/dev/null; then
    ok "README.md: путь scripts/tools/generate-split-config.py присутствует"
else
    fail "README.md: путь scripts/tools/generate-split-config.py не найден"
fi

if ! grep -qE '^python3 generate-split-config\.py' README.md 2>/dev/null; then
    ok "README.md: старый путь generate-split-config.py (без scripts/tools/) отсутствует"
else
    fail "README.md: старый путь generate-split-config.py всё ещё присутствует"
fi

# =============================================================================
# 3. .gitignore: запись phase4-cleanup.sh удалена
# =============================================================================
echo ""
echo "--- 3. .gitignore: phase4-cleanup.sh удалён ---"

if ! grep -q 'phase4-cleanup\.sh' .gitignore 2>/dev/null; then
    ok ".gitignore: phase4-cleanup.sh не упоминается"
else
    fail ".gitignore: phase4-cleanup.sh всё ещё упоминается"
fi

# vpn-dashboard-nginx.conf и ru-ips.txt остаются в .gitignore (на случай повторного появления)
if grep -q 'vpn-dashboard-nginx\.conf' .gitignore 2>/dev/null; then
    ok ".gitignore: vpn-dashboard-nginx.conf сохранён (защита от повторного трекинга)"
else
    fail ".gitignore: vpn-dashboard-nginx.conf отсутствует"
fi

if grep -q 'ru-ips\.txt' .gitignore 2>/dev/null; then
    ok ".gitignore: ru-ips.txt сохранён (автогенерируемый файл)"
else
    fail ".gitignore: ru-ips.txt отсутствует"
fi

# =============================================================================
# 4. Корень проекта содержит только нужные файлы
# =============================================================================
echo ""
echo "--- 4. Корень проекта: только нужные файлы ---"

for f in manage.sh README.md .env.example .gitignore .gitattributes; do
    if [[ -f "$f" ]]; then
        ok "$f на месте"
    else
        fail "$f отсутствует"
    fi
done

for d in lib scripts tests youtube-proxy vpn-output; do
    if [[ -d "$d" ]]; then
        ok "$d/ на месте"
    else
        fail "$d/ отсутствует"
    fi
done

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
