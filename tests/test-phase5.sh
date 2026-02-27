#!/usr/bin/env bash
# tests/test-phase5.sh — проверки Фазы 5 (рефакторинг: lib/common.sh + manage.sh)
# Запуск: bash tests/test-phase5.sh

set -u

PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "=== Тесты Фазы 5: Рефакторинг (lib/common.sh + manage.sh) ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Наличие файлов
# ---------------------------------------------------------------------------
echo "--- 1. Новые файлы присутствуют ---"

if [[ -f "lib/common.sh" ]]; then
    ok "lib/common.sh существует"
else
    fail "lib/common.sh отсутствует"
fi

if [[ -f "manage.sh" ]]; then
    ok "manage.sh существует"
else
    fail "manage.sh отсутствует"
fi

# ---------------------------------------------------------------------------
# 2. Синтаксис bash
# ---------------------------------------------------------------------------
echo ""
echo "--- 2. Синтаксис bash корректен ---"

for f in lib/common.sh manage.sh; do
    if [[ ! -f "$f" ]]; then
        fail "$f: файл отсутствует"
        continue
    fi
    if bash -n <(tr -d '\r' < "$f") 2>/dev/null; then
        ok "$f: синтаксис bash корректен"
    else
        fail "$f: ошибка синтаксиса bash"
    fi
done

# ---------------------------------------------------------------------------
# 3. lib/common.sh содержит все ключевые функции
# ---------------------------------------------------------------------------
echo ""
echo "--- 3. lib/common.sh содержит ключевые функции ---"

check_function() {
    local func="$1"
    if grep -qE "^${func}\(\)" lib/common.sh 2>/dev/null; then
        ok "lib/common.sh: функция ${func}()"
    else
        fail "lib/common.sh: функция ${func}() отсутствует"
    fi
}

check_function "clean_value"
check_function "read_kv"
check_function "parse_kv"
check_function "load_defaults_from_files"
check_function "expand_tilde"
check_function "auto_pick_key_if_missing"
check_function "prepare_key_for_ssh"
check_function "cleanup_temp_keys"
check_function "ssh_exec"
check_function "ssh_upload"
check_function "ssh_run_script"
check_function "check_deps"

# ---------------------------------------------------------------------------
# 4. lib/common.sh содержит цвета и функции вывода
# ---------------------------------------------------------------------------
echo ""
echo "--- 4. lib/common.sh содержит цвета и функции вывода ---"

for var in RED GREEN YELLOW CYAN BOLD NC; do
    if grep -q "^${var}=" lib/common.sh 2>/dev/null; then
        ok "lib/common.sh: переменная ${var}"
    else
        fail "lib/common.sh: переменная ${var} отсутствует"
    fi
done

for func in log ok err warn step; do
    if grep -qE "^${func}\(\)" lib/common.sh 2>/dev/null; then
        ok "lib/common.sh: функция вывода ${func}()"
    else
        fail "lib/common.sh: функция вывода ${func}() отсутствует"
    fi
done

# ---------------------------------------------------------------------------
# 5. manage.sh подключает lib/common.sh
# ---------------------------------------------------------------------------
echo ""
echo "--- 5. manage.sh подключает lib/common.sh ---"

if grep -q 'source.*lib/common.sh' manage.sh 2>/dev/null; then
    ok "manage.sh: source lib/common.sh найден"
else
    fail "manage.sh: source lib/common.sh не найден"
fi

# ---------------------------------------------------------------------------
# 6. manage.sh содержит все подкоманды
# ---------------------------------------------------------------------------
echo ""
echo "--- 6. manage.sh содержит все подкоманды ---"

for cmd in deploy monitor add-peer check help; do
    # Ищем подкоманду: как строку в case, как имя функции cmd_X, или как usage_main для help
    cmd_func="${cmd//-/_}"
    if grep -qE "(\"${cmd}\"|'${cmd}'|cmd_${cmd_func}|usage_main)" manage.sh 2>/dev/null; then
        ok "manage.sh: подкоманда '${cmd}'"
    else
        fail "manage.sh: подкоманда '${cmd}' не найдена"
    fi
done

# ---------------------------------------------------------------------------
# 7. manage.sh вызывает правильные скрипты
# ---------------------------------------------------------------------------
echo ""
echo "--- 7. manage.sh делегирует вызовы правильным скриптам ---"

check_delegates() {
    local script="$1"
    if grep -q "$script" manage.sh 2>/dev/null; then
        ok "manage.sh: делегирует в ${script}"
    else
        fail "manage.sh: не делегирует в ${script}"
    fi
}

check_delegates "deploy.sh"
check_delegates "deploy-vps1.sh"
check_delegates "deploy-vps2.sh"
check_delegates "deploy-proxy.sh"
check_delegates "monitor-realtime.sh"
check_delegates "monitor-web.sh"
check_delegates "add_phone_peer.sh"
check_delegates "check_ping.sh"

# ---------------------------------------------------------------------------
# 8. manage.sh: справка работает без ошибок
# ---------------------------------------------------------------------------
echo ""
echo "--- 8. manage.sh: справка запускается без ошибок ---"

if bash manage.sh help >/dev/null 2>&1; then
    ok "manage.sh help: завершился без ошибок"
else
    fail "manage.sh help: завершился с ошибкой"
fi

for subcmd in deploy monitor add-peer check; do
    if bash manage.sh "$subcmd" --help >/dev/null 2>&1; then
        ok "manage.sh ${subcmd} --help: завершился без ошибок"
    else
        fail "manage.sh ${subcmd} --help: завершился с ошибкой"
    fi
done

# ---------------------------------------------------------------------------
# 9. manage.sh: неизвестная команда возвращает ненулевой код
# ---------------------------------------------------------------------------
echo ""
echo "--- 9. manage.sh: обработка неизвестной команды ---"

if ! bash manage.sh unknown-command >/dev/null 2>&1; then
    ok "manage.sh: неизвестная команда возвращает ненулевой код"
else
    fail "manage.sh: неизвестная команда должна возвращать ненулевой код"
fi

# ---------------------------------------------------------------------------
# 10. lib/common.sh: функциональный тест clean_value
# ---------------------------------------------------------------------------
echo ""
echo "--- 10. lib/common.sh: функциональные тесты ---"

_test_clean_value() {
    source lib/common.sh 2>/dev/null || { fail "lib/common.sh: не удалось подключить"; return; }
    local result
    # Передаём строку с двойными кавычками внутри через переменную
    local input='  hello world  '
    result="$(clean_value "$input")"
    if [[ "$result" == "hello world" ]]; then
        ok "clean_value: убирает пробелы по краям"
    else
        fail "clean_value: ожидалось 'hello world', получено '${result}'"
    fi

    result="$(clean_value $'value\r')"
    if [[ "$result" == "value" ]]; then
        ok "clean_value: убирает \\r"
    else
        fail "clean_value: ожидалось 'value', получено '${result}'"
    fi
}

_test_clean_value

# ---------------------------------------------------------------------------
# 11. lib/common.sh: тест parse_kv
# ---------------------------------------------------------------------------

_test_parse_kv() {
    source lib/common.sh 2>/dev/null || return
    local data="HOST=myserver
LOAD=0.1,0.2,0.3
MEM=512/1024MB"
    local result
    result="$(parse_kv "$data" HOST)"
    if [[ "$result" == "myserver" ]]; then
        ok "parse_kv: корректно парсит HOST"
    else
        fail "parse_kv: ожидалось 'myserver', получено '${result}'"
    fi

    result="$(parse_kv "$data" MEM)"
    if [[ "$result" == "512/1024MB" ]]; then
        ok "parse_kv: корректно парсит MEM"
    else
        fail "parse_kv: ожидалось '512/1024MB', получено '${result}'"
    fi
}

_test_parse_kv

# ---------------------------------------------------------------------------
# 12. lib/common.sh: тест expand_tilde
# ---------------------------------------------------------------------------

_test_expand_tilde() {
    source lib/common.sh 2>/dev/null || return
    local result

    result="$(expand_tilde "~/test/path")"
    expected="${HOME}/test/path"
    if [[ "$result" == "$expected" ]]; then
        ok "expand_tilde: разворачивает ~/"
    else
        fail "expand_tilde: ожидалось '${expected}', получено '${result}'"
    fi

    result="$(expand_tilde "C:/Users/test/.ssh/id_rsa")"
    if [[ "$result" == "/mnt/c/Users/test/.ssh/id_rsa" ]]; then
        ok "expand_tilde: конвертирует Windows-путь C:/"
    else
        fail "expand_tilde: ожидалось '/mnt/c/Users/test/.ssh/id_rsa', получено '${result}'"
    fi
}

_test_expand_tilde

# ---------------------------------------------------------------------------
# Итог
# ---------------------------------------------------------------------------
echo ""
echo "================================="
echo "Итого: PASS=$PASS  FAIL=$FAIL"
echo "================================="
echo ""

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
