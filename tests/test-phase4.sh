#!/usr/bin/env bash
# tests/test-phase4.sh — проверки Фазы 4 (чистка и документация)
# Запуск: bash tests/test-phase4.sh

set -u

PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "=== Тесты Фазы 4: Чистка и документация ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Устаревшие скрипты удалены
# ---------------------------------------------------------------------------
echo "--- 1. Устаревшие скрипты удалены ---"

if [[ ! -f "update-dashboard-data.sh" ]]; then
    ok "update-dashboard-data.sh отсутствует"
else
    fail "update-dashboard-data.sh всё ещё существует"
fi

if [[ ! -f "update-dashboard-simple.sh" ]]; then
    ok "update-dashboard-simple.sh отсутствует"
else
    fail "update-dashboard-simple.sh всё ещё существует"
fi

# ---------------------------------------------------------------------------
# 2. Мусорные файлы удалены
# ---------------------------------------------------------------------------
echo ""
echo "--- 2. Мусорные файлы удалены ---"

if [[ ! -f "qc" ]]; then
    ok "файл qc отсутствует"
else
    fail "файл qc всё ещё существует"
fi

if [[ ! -f "query" ]]; then
    ok "файл query отсутствует"
else
    fail "файл query всё ещё существует"
fi

# ---------------------------------------------------------------------------
# 3. spb_client.conf удалён
# ---------------------------------------------------------------------------
echo ""
echo "--- 3. spb_client.conf с приватным ключом удалён ---"

if [[ ! -f "spb_client.conf" ]]; then
    ok "spb_client.conf отсутствует"
else
    fail "spb_client.conf всё ещё существует (содержит приватный ключ!)"
fi

# ---------------------------------------------------------------------------
# 4. .gitignore содержит нужные записи
# ---------------------------------------------------------------------------
echo ""
echo "--- 4. .gitignore содержит нужные записи ---"

check_gitignore() {
    local pattern="$1"
    if grep -qF "$pattern" .gitignore 2>/dev/null; then
        ok ".gitignore содержит: $pattern"
    else
        fail ".gitignore не содержит: $pattern"
    fi
}

check_gitignore "*.conf"
check_gitignore "vpn-output/*"
check_gitignore ".env"
check_gitignore "youtube-proxy/youtube-proxy"

# ---------------------------------------------------------------------------
# 5. README.md содержит актуальную документацию
# ---------------------------------------------------------------------------
echo ""
echo "--- 5. README.md содержит актуальную документацию ---"

if [[ -f "README.md" ]]; then
    ok "README.md существует"
else
    fail "README.md отсутствует"
fi

# Проверяем наличие секций тестов всех фаз
for phase in test-phase2 test-phase3 test-phase4; do
    if grep -q "$phase" README.md 2>/dev/null; then
        ok "README.md упоминает $phase"
    else
        fail "README.md не упоминает $phase"
    fi
done

# Проверяем что нет хардкода приватных ключей в README
if grep -qE 'PrivateKey\s*=' README.md 2>/dev/null; then
    fail "README.md содержит PrivateKey!"
else
    ok "README.md не содержит приватных ключей"
fi

# ---------------------------------------------------------------------------
# 6. Структура тестов
# ---------------------------------------------------------------------------
echo ""
echo "--- 6. Тесты всех фаз присутствуют ---"

for f in tests/test-phase2.sh tests/test-phase2.ps1 \
          tests/test-phase3.sh tests/test-phase3.ps1 \
          tests/test-phase4.sh tests/test-phase4.ps1; do
    if [[ -f "$f" ]]; then
        ok "$f существует"
    else
        fail "$f отсутствует"
    fi
done

# ---------------------------------------------------------------------------
# 7. deploy-скрипты: dry-run валидация структуры
# ---------------------------------------------------------------------------
echo ""
echo "--- 7. Deploy-скрипты: базовая валидация структуры ---"

for script in scripts/deploy/deploy.sh scripts/deploy/deploy-vps1.sh scripts/deploy/deploy-vps2.sh scripts/deploy/deploy-proxy.sh; do
    if [[ ! -f "$script" ]]; then
        fail "$script отсутствует"
        continue
    fi

    # Проверяем синтаксис bash (нормализуем CRLF для Windows-совместимости)
    if bash -n <(tr -d '\r' < "$script") 2>/dev/null; then
        ok "$script: синтаксис bash корректен"
    else
        fail "$script: ошибка синтаксиса bash"
    fi

    # Проверяем наличие set -e или set -euo
    if grep -qE '^\s*set\s+-[a-z]*e' "$script" 2>/dev/null; then
        ok "$script: содержит set -e (безопасный режим)"
    else
        fail "$script: отсутствует set -e"
    fi

    # Проверяем что нет хардкода приватных ключей
    if grep -qE 'PrivateKey\s*=\s*[A-Za-z0-9+/]{40,}' "$script" 2>/dev/null; then
        fail "$script: содержит хардкод приватного ключа!"
    else
        ok "$script: нет хардкода приватных ключей"
    fi
done

# ---------------------------------------------------------------------------
# Итог
# ---------------------------------------------------------------------------
echo ""
echo "================================="
echo "Итого: PASS=$PASS  FAIL=$FAIL"
echo "================================="
echo ""

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
