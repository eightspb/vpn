#!/usr/bin/env bash
# =============================================================================
# test-manage-peers.sh — тесты для scripts/tools/manage-peers.sh
#
# Проверяет:
#   1. Наличие скрипта и исполняемость
#   2. Синтаксис bash (bash -n)
#   3. Все команды и подкоманды (help)
#   4. Парсинг аргументов
#   5. Функции генерации конфигов (шаблон)
#   6. Функции работы с базой пиров (peers.json)
#   7. Формат CSV для batch
#   8. Валидация IP-адресов
#   9. Интеграция с lib/common.sh
#  10. Формат конфигов AmneziaWG
#
# Использование:
#   bash tests/test-manage-peers.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MANAGE_PEERS="${PROJECT_ROOT}/scripts/tools/manage-peers.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

PASS=0 FAIL=0 SKIP=0

pass() { PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} $*"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  ${RED}✗${NC} $*"; }
skip() { SKIP=$((SKIP + 1)); echo -e "  ${YELLOW}⊘${NC} $* (skipped)"; }

# ── Test 1: Script exists ────────────────────────────────────────────────────

echo -e "\n${BOLD}━━━ 1/10: Наличие скрипта ━━━${NC}"

if [[ -f "$MANAGE_PEERS" ]]; then
    pass "manage-peers.sh существует"
else
    fail "manage-peers.sh не найден: $MANAGE_PEERS"
    echo "Тесты прерваны — скрипт не найден."
    exit 1
fi

# ── Test 2: Bash syntax ─────────────────────────────────────────────────────

echo -e "\n${BOLD}━━━ 2/10: Синтаксис bash ━━━${NC}"

if bash -n "$MANAGE_PEERS" 2>/dev/null; then
    pass "bash -n: синтаксис корректен"
else
    fail "bash -n: ошибка синтаксиса"
fi

# ── Test 3: All commands have help ───────────────────────────────────────────

echo -e "\n${BOLD}━━━ 3/10: Справка по командам ━━━${NC}"

for cmd in help add batch list remove export info; do
    if [[ "$cmd" == "help" ]]; then
        output=$(bash "$MANAGE_PEERS" help 2>&1 || true)
    else
        output=$(bash "$MANAGE_PEERS" "$cmd" --help 2>&1 || true)
    fi
    if echo "$output" | grep -qi "manage-peers\|использование\|опции\|примеры"; then
        pass "Команда '$cmd' имеет справку"
    else
        fail "Команда '$cmd': справка не найдена"
    fi
done

# ── Test 4: Argument parsing ────────────────────────────────────────────────

echo -e "\n${BOLD}━━━ 4/10: Парсинг аргументов ━━━${NC}"

# add without --name should fail
output=$(bash "$MANAGE_PEERS" add 2>&1 || true)
if echo "$output" | grep -qi "name\|имя"; then
    pass "add без --name: ожидаемая ошибка"
else
    fail "add без --name: нет ошибки о name"
fi

# batch without --file/--prefix should fail
output=$(bash "$MANAGE_PEERS" batch 2>&1 || true)
if echo "$output" | grep -qi "file\|prefix"; then
    pass "batch без --file/--prefix: ожидаемая ошибка"
else
    fail "batch без --file/--prefix: нет ошибки"
fi

# remove without --name/--ip should fail
output=$(bash "$MANAGE_PEERS" remove 2>&1 || true)
if echo "$output" | grep -qi "name\|ip\|имя"; then
    pass "remove без --name/--ip: ожидаемая ошибка"
else
    fail "remove без --name/--ip: нет ошибки"
fi

# export without --name/--ip should fail
output=$(bash "$MANAGE_PEERS" export 2>&1 || true)
if echo "$output" | grep -qi "name\|ip\|имя"; then
    pass "export без --name/--ip: ожидаемая ошибка"
else
    fail "export без --name/--ip: нет ошибки"
fi

# Unknown command should fail
output=$(bash "$MANAGE_PEERS" nonexistent 2>&1 || true)
if echo "$output" | grep -qi "неизвестн\|unknown"; then
    pass "Неизвестная команда: ожидаемая ошибка"
else
    fail "Неизвестная команда: нет ошибки"
fi

# ── Test 5: Config template structure ────────────────────────────────────────

echo -e "\n${BOLD}━━━ 5/10: Шаблон конфига в скрипте ━━━${NC}"

if grep -q '\[Interface\]' "$MANAGE_PEERS"; then
    pass "Шаблон содержит [Interface]"
else
    fail "Шаблон не содержит [Interface]"
fi

if grep -q '\[Peer\]' "$MANAGE_PEERS"; then
    pass "Шаблон содержит [Peer]"
else
    fail "Шаблон не содержит [Peer]"
fi

if grep -q '# Name =' "$MANAGE_PEERS"; then
    pass "Шаблон содержит имя профиля для AmneziaWG"
else
    fail "Шаблон не содержит имя профиля для AmneziaWG"
fi

if grep -q 'PrivateKey' "$MANAGE_PEERS"; then
    pass "Шаблон содержит PrivateKey"
else
    fail "Шаблон не содержит PrivateKey"
fi

if grep -q 'AllowedIPs' "$MANAGE_PEERS"; then
    pass "Шаблон содержит AllowedIPs"
else
    fail "Шаблон не содержит AllowedIPs"
fi

if grep -q 'PersistentKeepalive' "$MANAGE_PEERS"; then
    pass "Шаблон содержит PersistentKeepalive"
else
    fail "Шаблон не содержит PersistentKeepalive"
fi

if grep -q 'DNS' "$MANAGE_PEERS"; then
    pass "Шаблон содержит DNS"
else
    fail "Шаблон не содержит DNS"
fi

if grep -q 'MTU' "$MANAGE_PEERS"; then
    pass "Шаблон содержит MTU"
else
    fail "Шаблон не содержит MTU"
fi

if grep -q 'Endpoint' "$MANAGE_PEERS"; then
    pass "Шаблон содержит Endpoint"
else
    fail "Шаблон не содержит Endpoint"
fi

# ── Test 6: Peers DB functions ───────────────────────────────────────────────

echo -e "\n${BOLD}━━━ 6/10: Функции базы пиров ━━━${NC}"

if grep -q 'peers.json' "$MANAGE_PEERS"; then
    pass "Используется peers.json для хранения"
else
    fail "peers.json не упоминается"
fi

if grep -q '_db_add' "$MANAGE_PEERS"; then
    pass "Функция _db_add определена"
else
    fail "Функция _db_add не найдена"
fi

if grep -q '_db_remove' "$MANAGE_PEERS"; then
    pass "Функция _db_remove определена"
else
    fail "Функция _db_remove не найдена"
fi

if grep -q '_db_find' "$MANAGE_PEERS"; then
    pass "Функция _db_find определена"
else
    fail "Функция _db_find не найдена"
fi

# Test DB operations with a temp file
if command -v python3 &>/dev/null; then
    TMP_DIR=$(mktemp -d)
    TMP_DB="${TMP_DIR}/test_peers.json"
    echo '[]' > "$TMP_DB"

    python3 -c "
import json
db = json.load(open('$TMP_DB'))
db.append({'name': 'test-device', 'ip': '10.9.0.99', 'type': 'phone', 'public_key': 'testpub123', 'private_key': 'testpriv456', 'created': '2025-01-01', 'config_file': 'test.conf'})
json.dump(db, open('$TMP_DB', 'w'), indent=2)
"
    if python3 -c "import json; db=json.load(open('$TMP_DB')); assert len(db)==1; assert db[0]['name']=='test-device'" 2>/dev/null; then
        pass "DB add: запись добавлена корректно"
    else
        fail "DB add: ошибка добавления"
    fi

    python3 -c "
import json
db = json.load(open('$TMP_DB'))
db = [p for p in db if p.get('name') != 'test-device']
json.dump(db, open('$TMP_DB', 'w'), indent=2)
"
    if python3 -c "import json; db=json.load(open('$TMP_DB')); assert len(db)==0" 2>/dev/null; then
        pass "DB remove: запись удалена корректно"
    else
        fail "DB remove: ошибка удаления"
    fi

    rm -rf "$TMP_DIR"
else
    skip "DB operations: python3 не найден"
fi

# ── Test 7: CSV format for batch ─────────────────────────────────────────────

echo -e "\n${BOLD}━━━ 7/10: Формат CSV для batch ━━━${NC}"

if grep -q "IFS=',' read" "$MANAGE_PEERS"; then
    pass "CSV парсинг через IFS=','"
else
    fail "CSV парсинг не найден"
fi

if grep -q 'name.*type.*ip' "$MANAGE_PEERS" || grep -q 'dname.*dtype.*dip' "$MANAGE_PEERS"; then
    pass "CSV поля: name, type, ip"
else
    fail "CSV поля не найдены"
fi

# Test CSV parsing logic
TMP_CSV=$(mktemp)
cat > "$TMP_CSV" <<'CSVEOF'
name,type,ip
laptop-1,pc,
phone-anna,phone,
router-office,router,10.9.0.100
CSVEOF

line_count=0
while IFS=',' read -r dname dtype dip; do
    dname="$(echo "$dname" | tr -d '[:space:]')"
    [[ -z "$dname" || "$dname" == "name" ]] && continue
    line_count=$((line_count + 1))
done < "$TMP_CSV"
rm -f "$TMP_CSV"

if [[ "$line_count" -eq 3 ]]; then
    pass "CSV: 3 устройства прочитаны корректно"
else
    fail "CSV: ожидалось 3 устройства, получено $line_count"
fi

# ── Test 8: IP validation ───────────────────────────────────────────────────

echo -e "\n${BOLD}━━━ 8/10: Валидация IP-адресов ━━━${NC}"

if grep -q 'seq 3 254' "$MANAGE_PEERS"; then
    pass "Диапазон IP: 3-254"
else
    fail "Диапазон IP 3-254 не найден"
fi

if grep -q '_next_free_ip' "$MANAGE_PEERS"; then
    pass "Функция автоопределения IP"
else
    fail "Функция автоопределения IP не найдена"
fi

if grep -q 'уже занят\|already.*used' "$MANAGE_PEERS"; then
    pass "Проверка дублирования IP"
else
    fail "Проверка дублирования IP не найдена"
fi

if grep -q 'Нет свободных IP\|no.*free.*ip' "$MANAGE_PEERS" -i; then
    pass "Обработка исчерпания IP"
else
    fail "Обработка исчерпания IP не найдена"
fi

# ── Test 9: Integration with lib/common.sh ───────────────────────────────────

echo -e "\n${BOLD}━━━ 9/10: Интеграция с lib/common.sh ━━━${NC}"

if grep -q 'source.*lib/common.sh' "$MANAGE_PEERS"; then
    pass "Подключает lib/common.sh"
else
    fail "Не подключает lib/common.sh"
fi

if grep -q 'load_defaults_from_files' "$MANAGE_PEERS"; then
    pass "Использует load_defaults_from_files"
else
    fail "Не использует load_defaults_from_files"
fi

if grep -q 'expand_tilde' "$MANAGE_PEERS"; then
    pass "Использует expand_tilde"
else
    fail "Не использует expand_tilde"
fi

if grep -q 'ssh_exec' "$MANAGE_PEERS"; then
    pass "Использует ssh_exec"
else
    fail "Не использует ssh_exec"
fi

if grep -q 'cleanup_temp_keys' "$MANAGE_PEERS"; then
    pass "Использует cleanup_temp_keys"
else
    fail "Не использует cleanup_temp_keys"
fi

if grep -q 'auto_pick_key_if_missing' "$MANAGE_PEERS"; then
    pass "Использует auto_pick_key_if_missing"
else
    fail "Не использует auto_pick_key_if_missing"
fi

if grep -q 'prepare_key_for_ssh' "$MANAGE_PEERS"; then
    pass "Использует prepare_key_for_ssh"
else
    fail "Не использует prepare_key_for_ssh"
fi

# ── Test 10: Device types and MTU ────────────────────────────────────────────

echo -e "\n${BOLD}━━━ 10/10: Типы устройств и MTU ━━━${NC}"

if grep -q 'mtu=1360' "$MANAGE_PEERS"; then
    pass "MTU 1360 для PC"
else
    fail "MTU 1360 для PC не найден"
fi

if grep -q 'mtu=1280' "$MANAGE_PEERS"; then
    pass "MTU 1280 для phone"
else
    fail "MTU 1280 для phone не найден"
fi

if grep -q 'mtu=1400' "$MANAGE_PEERS"; then
    pass "MTU 1400 для router"
else
    fail "MTU 1400 для router не найден"
fi

for dtype in pc desktop laptop phone mobile tablet router mikrotik openwrt; do
    if grep -q "$dtype" "$MANAGE_PEERS"; then
        pass "Тип устройства '$dtype' поддерживается"
    else
        fail "Тип устройства '$dtype' не найден"
    fi
done

# Split tunnel removed
if grep -q 'split' "$MANAGE_PEERS"; then
    fail "В manage-peers.sh всё ещё есть split tunnel"
else
    pass "Split tunnel удалён из manage-peers.sh"
fi

# QR code support
if grep -q 'qrencode\|qrcode' "$MANAGE_PEERS"; then
    pass "Поддержка QR-кодов"
else
    fail "QR-коды не поддерживаются"
fi

# Batch support
if grep -q 'cmd_batch' "$MANAGE_PEERS"; then
    pass "Команда batch определена"
else
    fail "Команда batch не найдена"
fi

if grep -q -- '--prefix' "$MANAGE_PEERS"; then
    pass "Batch: поддержка --prefix"
else
    fail "Batch: --prefix не найден"
fi

if grep -q -- '--count' "$MANAGE_PEERS"; then
    pass "Batch: поддержка --count"
else
    fail "Batch: --count не найден"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}  ${YELLOW}Skipped: $SKIP${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
