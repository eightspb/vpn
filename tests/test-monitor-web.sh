#!/usr/bin/env bash
# tests/test-monitor-web.sh — проверки monitor-web.sh и dashboard.html
# Запуск: bash tests/test-monitor-web.sh

set -u

PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "=== Тесты monitor-web.sh и dashboard.html ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Наличие файлов
# ---------------------------------------------------------------------------
echo "--- 1. Файлы присутствуют ---"

for f in monitor-web.sh dashboard.html; do
    if [[ -f "$f" ]]; then
        ok "$f существует"
    else
        fail "$f отсутствует"
    fi
done

# ---------------------------------------------------------------------------
# 2. Синтаксис bash
# ---------------------------------------------------------------------------
echo ""
echo "--- 2. Синтаксис bash корректен ---"

if bash -n <(tr -d '\r' < monitor-web.sh) 2>/dev/null; then
    ok "monitor-web.sh: синтаксис bash корректен"
else
    fail "monitor-web.sh: ошибка синтаксиса bash"
fi

# ---------------------------------------------------------------------------
# 3. Критические исправления в monitor-web.sh
# ---------------------------------------------------------------------------
echo ""
echo "--- 3. Исправления SSH, ping и параллельный сбор данных ---"

# ssh_bin определяется динамически, не хардкодится ssh.exe
if grep -q 'ssh_bin="ssh"' monitor-web.sh; then
    ok "monitor-web.sh: ssh_bin определяется динамически (нет хардкода ssh.exe)"
else
    fail "monitor-web.sh: ssh_bin не определяется динамически"
fi

# Нет прямого вызова ssh.exe (только через переменную ssh_bin)
if grep -qE 'timeout.*ssh\.exe' monitor-web.sh; then
    fail "monitor-web.sh: прямой вызов ssh.exe найден (должен использоваться \$ssh_bin)"
else
    ok "monitor-web.sh: прямой вызов ssh.exe отсутствует"
fi

# ping_host функция присутствует
if grep -q '^ping_host()' monitor-web.sh; then
    ok "monitor-web.sh: функция ping_host() присутствует"
else
    fail "monitor-web.sh: функция ping_host() отсутствует"
fi

# ping_host использует timeout
if grep -A5 '^ping_host()' monitor-web.sh | grep -q 'timeout 2'; then
    ok "monitor-web.sh: ping_host использует timeout 2"
else
    fail "monitor-web.sh: ping_host не использует timeout"
fi

# check_internal_ips использует ping_host
if grep -A15 '^check_internal_ips()' monitor-web.sh | grep -q 'ping_host'; then
    ok "monitor-web.sh: check_internal_ips использует ping_host()"
else
    fail "monitor-web.sh: check_internal_ips не использует ping_host()"
fi

# Для дашборда считается число активных awg1 peers по всем handshake
if grep -q 'A1_ACTIVE' monitor-web.sh && grep -q 'active_peers_awg1' monitor-web.sh; then
    ok "monitor-web.sh: считает active_peers_awg1 по всем latest-handshakes"
else
    fail "monitor-web.sh: нет расчёта active_peers_awg1 (dashboard может занижать Active VPN)"
fi

# VPS2 всегда использует публичный IP (SSH не слушает на туннельном 10.8.0.2)
if grep -A15 '^check_internal_ips()' monitor-web.sh | grep -q 'CURRENT_VPS2_IP="\$VPS2_IP"'; then
    ok "monitor-web.sh: VPS2 всегда использует публичный IP для SSH"
else
    fail "monitor-web.sh: VPS2 должен всегда использовать публичный IP (не туннельный 10.8.0.2)"
fi

# ---------------------------------------------------------------------------
# 4. Python HTTP-сервер: кросс-платформенный ping
# ---------------------------------------------------------------------------
echo ""
echo "--- 4. Python HTTP-сервер: кросс-платформенный ping ---"

if grep -q 'IS_WIN' monitor-web.sh; then
    ok "monitor-web.sh: Python-сервер определяет ОС (IS_WIN)"
else
    fail "monitor-web.sh: Python-сервер не определяет ОС"
fi

if grep -q "import.*platform" monitor-web.sh; then
    ok "monitor-web.sh: Python-сервер импортирует platform"
else
    fail "monitor-web.sh: Python-сервер не импортирует platform"
fi

if grep -q "ping.*-n.*3.*-w.*2000" monitor-web.sh; then
    ok "monitor-web.sh: Python-сервер использует Windows-синтаксис ping (-n 3 -w 2000)"
else
    fail "monitor-web.sh: Python-сервер не поддерживает Windows-синтаксис ping"
fi

if grep -q "Average.*ms" monitor-web.sh; then
    ok "monitor-web.sh: Python-сервер парсит Windows-вывод ping (Average)"
else
    fail "monitor-web.sh: Python-сервер не парсит Windows-вывод ping"
fi

if grep -q 'PYTHON_CMD=' monitor-web.sh && \
   grep -q 'command -v python3' monitor-web.sh && \
   grep -q 'command -v python' monitor-web.sh && \
   grep -q 'command -v py' monitor-web.sh; then
    ok "monitor-web.sh: есть fallback Python runtime (python3/python/py -3)"
else
    fail "monitor-web.sh: нет fallback Python runtime"
fi

# ---------------------------------------------------------------------------
# 5. dashboard.html: правильный путь к data.json
# ---------------------------------------------------------------------------
echo ""
echo "--- 5. dashboard.html: правильный путь к data.json ---"

if grep -q "vpn-output/data.json" dashboard.html; then
    ok "dashboard.html: DATA_URL указывает на vpn-output/data.json"
else
    fail "dashboard.html: DATA_URL не содержит vpn-output/data.json"
fi

# Убедимся, что нет старого неправильного пути
if grep -qE "DATA_URL\s*=\s*'data\.json'" dashboard.html; then
    fail "dashboard.html: DATA_URL всё ещё указывает на data.json (без vpn-output/)"
else
    ok "dashboard.html: DATA_URL не содержит старый путь 'data.json'"
fi

# ---------------------------------------------------------------------------
# 6. dashboard.html: Ping API включён
# ---------------------------------------------------------------------------
echo ""
echo "--- 6. dashboard.html: Ping API включён ---"

if grep -q '/api/ping' dashboard.html; then
    ok "dashboard.html: вызов /api/ping присутствует"
else
    fail "dashboard.html: вызов /api/ping отсутствует"
fi

if grep -q 'active_peers_awg1' dashboard.html; then
    ok "dashboard.html: Active VPN использует active_peers_awg1"
else
    fail "dashboard.html: Active VPN не использует active_peers_awg1"
fi

if grep -q 'Ping недоступен в статическом режиме' dashboard.html; then
    fail "dashboard.html: Ping API заглушён (статический режим)"
else
    ok "dashboard.html: Ping API не заглушён"
fi

# ---------------------------------------------------------------------------
# 7. monitor-web.sh: обязательные параметры
# ---------------------------------------------------------------------------
echo ""
echo "--- 7. monitor-web.sh: обязательные параметры и переменные ---"

for var in VPS1_IP VPS2_IP VPS1_INTERNAL VPS2_INTERNAL INTERVAL HTTP_PORT SSH_TIMEOUT JSON_FILE LOG_FILE; do
    if grep -q "${var}=" monitor-web.sh; then
        ok "monitor-web.sh: переменная ${var} определена"
    else
        fail "monitor-web.sh: переменная ${var} отсутствует"
    fi
done

# ---------------------------------------------------------------------------
# 8. monitor-web.sh: функции присутствуют
# ---------------------------------------------------------------------------
echo ""
echo "--- 8. monitor-web.sh: ключевые функции ---"

for func in clean_value read_kv load_defaults_from_files expand_tilde ssh_exec collect_vps1 collect_vps2 write_json start_http_server check_internal_ips ping_host; do
    if grep -qE "^${func}\(\)" monitor-web.sh; then
        ok "monitor-web.sh: функция ${func}()"
    else
        fail "monitor-web.sh: функция ${func}() отсутствует"
    fi
done

# ---------------------------------------------------------------------------
# 9. monitor-web.sh: JSON_FILE путь корректен
# ---------------------------------------------------------------------------
echo ""
echo "--- 9. monitor-web.sh: пути к файлам ---"

if grep -q 'JSON_FILE="./vpn-output/data.json"' monitor-web.sh; then
    ok "monitor-web.sh: JSON_FILE=./vpn-output/data.json"
else
    fail "monitor-web.sh: JSON_FILE не указывает на ./vpn-output/data.json"
fi

# HTTP-сервер стартует из pwd (директория проекта), значит
# vpn-output/data.json доступен как vpn-output/data.json по HTTP
if grep -q '"$(pwd)"' monitor-web.sh || grep -q '$(pwd)' monitor-web.sh; then
    ok "monitor-web.sh: HTTP-сервер запускается из pwd"
else
    fail "monitor-web.sh: HTTP-сервер не использует pwd"
fi

# ---------------------------------------------------------------------------
# 9b. monitor-web.sh: параллельный сбор и AddressFamily=inet
# ---------------------------------------------------------------------------

if grep -q 'AddressFamily=inet' monitor-web.sh; then
    ok "monitor-web.sh: SSH использует AddressFamily=inet (нет зависания на IPv6 DNS)"
else
    fail "monitor-web.sh: AddressFamily=inet не задан"
fi

if grep -q 'ServerAliveInterval' monitor-web.sh; then
    ok "monitor-web.sh: SSH использует ServerAliveInterval (быстрое обнаружение обрыва)"
else
    fail "monitor-web.sh: ServerAliveInterval не задан"
fi

if grep -q 'collect_vps1.*&' monitor-web.sh && grep -q 'collect_vps2.*&' monitor-web.sh; then
    ok "monitor-web.sh: сбор данных с VPS1 и VPS2 параллельный (&)"
else
    fail "monitor-web.sh: сбор данных не параллельный — один зависший сервер блокирует другой"
fi

if grep -q 'hard_timeout\|wait_deadline' monitor-web.sh; then
    ok "monitor-web.sh: жёсткий таймаут на параллельный сбор"
else
    fail "monitor-web.sh: нет жёсткого таймаута на сбор данных"
fi

# ---------------------------------------------------------------------------
# 10. install-ca.ps1 присутствует и корректен
# ---------------------------------------------------------------------------
echo ""
echo "--- 10. install-ca.ps1: скрипт установки CA-сертификата ---"

if [[ -f "install-ca.ps1" ]]; then
    ok "install-ca.ps1 существует"
else
    fail "install-ca.ps1 отсутствует"
fi

if grep -q '10.8.0.2:8080/ca.crt' install-ca.ps1 2>/dev/null; then
    ok "install-ca.ps1: URL CA-сертификата корректен (10.8.0.2:8080/ca.crt)"
else
    fail "install-ca.ps1: URL CA-сертификата не найден"
fi

if grep -q 'Test-Connection.*10.9.0.1' install-ca.ps1 2>/dev/null; then
    ok "install-ca.ps1: проверяет подключение к VPN (10.9.0.1)"
else
    fail "install-ca.ps1: не проверяет подключение к VPN"
fi

if grep -q 'StoreName.*Root\|StoreName]::Root' install-ca.ps1 2>/dev/null && \
   grep -q 'LocalMachine' install-ca.ps1 2>/dev/null; then
    ok "install-ca.ps1: устанавливает в Trusted Root CAs (LocalMachine)"
else
    fail "install-ca.ps1: не устанавливает в Trusted Root CAs"
fi

# ---------------------------------------------------------------------------
# 11. deploy-proxy.sh: AdGuard Home останавливается принудительно
# ---------------------------------------------------------------------------
echo ""
echo "--- 11. deploy-proxy.sh: конфликт портов AdGuard/youtube-proxy ---"

if [[ -f "deploy-proxy.sh" ]]; then
    ok "deploy-proxy.sh существует"
else
    fail "deploy-proxy.sh отсутствует"
fi

if grep -q 'systemctl stop AdGuardHome' deploy-proxy.sh 2>/dev/null; then
    ok "deploy-proxy.sh: AdGuard Home останавливается"
else
    fail "deploy-proxy.sh: AdGuard Home не останавливается"
fi

if grep -q 'systemctl disable AdGuardHome' deploy-proxy.sh 2>/dev/null; then
    ok "deploy-proxy.sh: AdGuard Home отключается из автозапуска"
else
    fail "deploy-proxy.sh: AdGuard Home не отключается из автозапуска"
fi

if grep -q '10.9.0.0/24.*ACCEPT' deploy-proxy.sh 2>/dev/null; then
    ok "deploy-proxy.sh: SSH разрешён из VPN-сети (10.9.0.0/24)"
else
    fail "deploy-proxy.sh: SSH из VPN-сети не разрешён"
fi

if grep -q 'tcp.*443.*awg0.*ACCEPT\|443.*awg0' deploy-proxy.sh 2>/dev/null; then
    ok "deploy-proxy.sh: TCP 443 с awg0 разрешён (YouTube HTTPS прокси)"
else
    fail "deploy-proxy.sh: TCP 443 с awg0 не разрешён — YouTube прокси может не работать"
fi

if grep -q 'install-ca.ps1' deploy-proxy.sh 2>/dev/null; then
    ok "deploy-proxy.sh: упоминает install-ca.ps1 в инструкции"
else
    fail "deploy-proxy.sh: не упоминает install-ca.ps1"
fi

# ---------------------------------------------------------------------------
# 12. diagnose.sh присутствует и корректен
# ---------------------------------------------------------------------------
echo ""
echo "--- 12. diagnose.sh: скрипт диагностики ---"

if [[ -f "diagnose.sh" ]]; then
    ok "diagnose.sh существует"
else
    fail "diagnose.sh отсутствует"
fi

if bash -n <(tr -d '\r' < diagnose.sh) 2>/dev/null; then
    ok "diagnose.sh: синтаксис bash корректен"
else
    fail "diagnose.sh: ошибка синтаксиса bash"
fi

for check in 'youtube-proxy' 'AdGuardHome' 'MASQUERADE' 'awg0' 'port53' '--fix'; do
    if grep -q "$check" diagnose.sh 2>/dev/null; then
        ok "diagnose.sh: проверяет '$check'"
    else
        fail "diagnose.sh: не проверяет '$check'"
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
