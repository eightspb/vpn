#!/usr/bin/env bash
# tests/test-scripts/monitor/monitor-web.sh — проверки scripts/monitor/monitor-web.sh и scripts/monitor/dashboard.html
# Запуск: bash tests/test-scripts/monitor/monitor-web.sh

set -u

PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "=== Тесты scripts/monitor/monitor-web.sh и scripts/monitor/dashboard.html ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Наличие файлов
# ---------------------------------------------------------------------------
echo "--- 1. Файлы присутствуют ---"

for f in scripts/monitor/monitor-web.sh scripts/monitor/dashboard.html; do
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

if bash -n <(tr -d '\r' < scripts/monitor/monitor-web.sh) 2>/dev/null; then
    ok "scripts/monitor/monitor-web.sh: синтаксис bash корректен"
else
    fail "scripts/monitor/monitor-web.sh: ошибка синтаксиса bash"
fi

# ---------------------------------------------------------------------------
# 3. Критические исправления в scripts/monitor/monitor-web.sh
# ---------------------------------------------------------------------------
echo ""
echo "--- 3. Исправления SSH, ping и параллельный сбор данных ---"

# ssh_bin определяется динамически, не хардкодится ssh.exe
if grep -q 'ssh_bin="ssh"' scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: ssh_bin определяется динамически (нет хардкода ssh.exe)"
else
    fail "scripts/monitor/monitor-web.sh: ssh_bin не определяется динамически"
fi

# Нет прямого вызова ssh.exe (только через переменную ssh_bin)
if grep -qE 'timeout.*ssh\.exe' scripts/monitor/monitor-web.sh; then
    fail "scripts/monitor/monitor-web.sh: прямой вызов ssh.exe найден (должен использоваться \$ssh_bin)"
else
    ok "scripts/monitor/monitor-web.sh: прямой вызов ssh.exe отсутствует"
fi

# ping_host функция присутствует
if grep -q '^ping_host()' scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: функция ping_host() присутствует"
else
    fail "scripts/monitor/monitor-web.sh: функция ping_host() отсутствует"
fi

# ping_host использует timeout
if grep -A5 '^ping_host()' scripts/monitor/monitor-web.sh | grep -q 'timeout 2'; then
    ok "scripts/monitor/monitor-web.sh: ping_host использует timeout 2"
else
    fail "scripts/monitor/monitor-web.sh: ping_host не использует timeout"
fi

# check_internal_ips использует ping_host
if grep -A15 '^check_internal_ips()' scripts/monitor/monitor-web.sh | grep -q 'ping_host'; then
    ok "scripts/monitor/monitor-web.sh: check_internal_ips использует ping_host()"
else
    fail "scripts/monitor/monitor-web.sh: check_internal_ips не использует ping_host()"
fi

# Для дашборда считается число активных awg1 peers по всем handshake
if grep -q 'A1_ACTIVE' scripts/monitor/monitor-web.sh && grep -q 'active_peers_awg1' scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: считает active_peers_awg1 по всем latest-handshakes"
else
    fail "scripts/monitor/monitor-web.sh: нет расчёта active_peers_awg1 (dashboard может занижать Active VPN)"
fi

# VPS2 всегда использует публичный IP (SSH не слушает на туннельном 10.8.0.2)
if grep -A15 '^check_internal_ips()' scripts/monitor/monitor-web.sh | grep -q 'CURRENT_VPS2_IP="\$VPS2_IP"'; then
    ok "scripts/monitor/monitor-web.sh: VPS2 всегда использует публичный IP для SSH"
else
    fail "scripts/monitor/monitor-web.sh: VPS2 должен всегда использовать публичный IP (не туннельный 10.8.0.2)"
fi

# ---------------------------------------------------------------------------
# 4. Python HTTP-сервер: кросс-платформенный ping
# ---------------------------------------------------------------------------
echo ""
echo "--- 4. Python HTTP-сервер: кросс-платформенный ping ---"

if grep -q 'IS_WIN' scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: Python-сервер определяет ОС (IS_WIN)"
else
    fail "scripts/monitor/monitor-web.sh: Python-сервер не определяет ОС"
fi

if grep -q "import.*platform" scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: Python-сервер импортирует platform"
else
    fail "scripts/monitor/monitor-web.sh: Python-сервер не импортирует platform"
fi

if grep -q "ping.*-n.*3.*-w.*2000" scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: Python-сервер использует Windows-синтаксис ping (-n 3 -w 2000)"
else
    fail "scripts/monitor/monitor-web.sh: Python-сервер не поддерживает Windows-синтаксис ping"
fi

if grep -q "Average.*ms" scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: Python-сервер парсит Windows-вывод ping (Average)"
else
    fail "scripts/monitor/monitor-web.sh: Python-сервер не парсит Windows-вывод ping"
fi

if grep -q 'PYTHON_CMD=' scripts/monitor/monitor-web.sh && \
   grep -q 'command -v python3' scripts/monitor/monitor-web.sh && \
   grep -q 'command -v python' scripts/monitor/monitor-web.sh && \
   grep -q 'command -v py' scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: есть fallback Python runtime (python3/python/py -3)"
else
    fail "scripts/monitor/monitor-web.sh: нет fallback Python runtime"
fi

# ---------------------------------------------------------------------------
# 4b. WSL→Windows Python: HTTP-сервер доступен из Windows-браузера
# ---------------------------------------------------------------------------
echo ""
echo "--- 4b. WSL→Windows Python: HTTP-сервер запускается через Windows Python ---"

if grep -q 'detect_http_python' scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: функция detect_http_python() присутствует"
else
    fail "scripts/monitor/monitor-web.sh: функция detect_http_python() отсутствует"
fi

if grep -q 'microsoft.*proc/version' scripts/monitor/monitor-web.sh && \
   grep -q 'python\.exe' scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: при WSL использует Windows python.exe для HTTP"
else
    fail "scripts/monitor/monitor-web.sh: нет WSL→Windows Python fallback для HTTP-сервера"
fi

if grep -q 'wsl_to_win_path' scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: конвертирует WSL-путь в Windows-путь для HTTP serve dir"
else
    fail "scripts/monitor/monitor-web.sh: нет конвертации WSL→Windows пути"
fi

# ---------------------------------------------------------------------------
# 5. scripts/monitor/dashboard.html: правильный путь к data.json
# ---------------------------------------------------------------------------
echo ""
echo "--- 5. scripts/monitor/dashboard.html: правильный путь к data.json ---"

if grep -q "vpn-output/data.json" scripts/monitor/dashboard.html; then
    ok "scripts/monitor/dashboard.html: DATA_URL указывает на vpn-output/data.json"
else
    fail "scripts/monitor/dashboard.html: DATA_URL не содержит vpn-output/data.json"
fi

# Убедимся, что нет старого неправильного пути
if grep -qE "DATA_URL\s*=\s*'data\.json'" scripts/monitor/dashboard.html; then
    fail "scripts/monitor/dashboard.html: DATA_URL всё ещё указывает на data.json (без vpn-output/)"
else
    ok "scripts/monitor/dashboard.html: DATA_URL не содержит старый путь 'data.json'"
fi

# ---------------------------------------------------------------------------
# 6. scripts/monitor/dashboard.html: Ping API включён
# ---------------------------------------------------------------------------
echo ""
echo "--- 6. scripts/monitor/dashboard.html: Ping API включён ---"

if grep -q '/api/ping' scripts/monitor/dashboard.html; then
    ok "scripts/monitor/dashboard.html: вызов /api/ping присутствует"
else
    fail "scripts/monitor/dashboard.html: вызов /api/ping отсутствует"
fi

if grep -q 'active_peers_awg1' scripts/monitor/dashboard.html; then
    ok "scripts/monitor/dashboard.html: Active VPN использует active_peers_awg1"
else
    fail "scripts/monitor/dashboard.html: Active VPN не использует active_peers_awg1"
fi

if grep -q 'Ping недоступен в статическом режиме' scripts/monitor/dashboard.html; then
    fail "scripts/monitor/dashboard.html: Ping API заглушён (статический режим)"
else
    ok "scripts/monitor/dashboard.html: Ping API не заглушён"
fi

# ---------------------------------------------------------------------------
# 7. scripts/monitor/monitor-web.sh: обязательные параметры
# ---------------------------------------------------------------------------
echo ""
echo "--- 7. scripts/monitor/monitor-web.sh: обязательные параметры и переменные ---"

for var in VPS1_IP VPS2_IP VPS1_INTERNAL VPS2_INTERNAL INTERVAL HTTP_PORT SSH_TIMEOUT JSON_FILE LOG_FILE; do
    if grep -q "${var}=" scripts/monitor/monitor-web.sh; then
        ok "scripts/monitor/monitor-web.sh: переменная ${var} определена"
    else
        fail "scripts/monitor/monitor-web.sh: переменная ${var} отсутствует"
    fi
done

# ---------------------------------------------------------------------------
# 7b. manage.sh monitor --web: копирование .env из корня в scripts/monitor
# ---------------------------------------------------------------------------
echo ""
echo "--- 7b. manage.sh: при monitor --web копируется .env в scripts/monitor ---"

if [[ -f "manage.sh" ]]; then
    if grep -q 'scripts/monitor/.env' manage.sh && grep -qE 'cp.*\.env.*scripts/monitor' manage.sh; then
        ok "manage.sh: при monitor --web копирует .env в scripts/monitor"
    else
        fail "manage.sh: при monitor --web должен копировать .env в scripts/monitor"
    fi
else
    fail "manage.sh отсутствует"
fi

# ---------------------------------------------------------------------------
# 8. scripts/monitor/monitor-web.sh: функции присутствуют
# ---------------------------------------------------------------------------
echo ""
echo "--- 8. scripts/monitor/monitor-web.sh: ключевые функции ---"

for func in clean_value read_kv load_defaults_from_files expand_tilde ssh_exec collect_vps1 collect_vps2 write_json start_http_server check_internal_ips ping_host; do
    if grep -qE "^${func}\(\)" scripts/monitor/monitor-web.sh; then
        ok "scripts/monitor/monitor-web.sh: функция ${func}()"
    else
        fail "scripts/monitor/monitor-web.sh: функция ${func}() отсутствует"
    fi
done

# ---------------------------------------------------------------------------
# 9. scripts/monitor/monitor-web.sh: JSON_FILE путь корректен
# ---------------------------------------------------------------------------
echo ""
echo "--- 9. scripts/monitor/monitor-web.sh: пути к файлам ---"

if grep -q 'JSON_FILE="./vpn-output/data.json"' scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: JSON_FILE=./vpn-output/data.json (локальный для HTTP-сервера)"
else
    fail "scripts/monitor/monitor-web.sh: JSON_FILE должен быть ./vpn-output/data.json (чтобы HTTP-сервер отдавал его)"
fi

# HTTP-сервер стартует из pwd (директория проекта), значит
# vpn-output/data.json доступен как vpn-output/data.json по HTTP
if grep -q '"$(pwd)"' scripts/monitor/monitor-web.sh || grep -q '$(pwd)' scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: HTTP-сервер запускается из pwd"
else
    fail "scripts/monitor/monitor-web.sh: HTTP-сервер не использует pwd"
fi

# ---------------------------------------------------------------------------
# 9b. scripts/monitor/monitor-web.sh: параллельный сбор и AddressFamily=inet
# ---------------------------------------------------------------------------

if grep -q 'AddressFamily=inet' scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: SSH использует AddressFamily=inet (нет зависания на IPv6 DNS)"
else
    fail "scripts/monitor/monitor-web.sh: AddressFamily=inet не задан"
fi

if grep -q 'ServerAliveInterval' scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: SSH использует ServerAliveInterval (быстрое обнаружение обрыва)"
else
    fail "scripts/monitor/monitor-web.sh: ServerAliveInterval не задан"
fi

if grep -q 'collect_vps1.*&' scripts/monitor/monitor-web.sh && grep -q 'collect_vps2.*&' scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: сбор данных с VPS1 и VPS2 параллельный (&)"
else
    fail "scripts/monitor/monitor-web.sh: сбор данных не параллельный — один зависший сервер блокирует другой"
fi

if grep -q 'hard_timeout\|wait_deadline' scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: жёсткий таймаут на параллельный сбор"
else
    fail "scripts/monitor/monitor-web.sh: нет жёсткого таймаута на сбор данных"
fi

# ---------------------------------------------------------------------------
# 9c. scripts/monitor/monitor-web.sh: новые метрики (трафик, память, процессы)
# ---------------------------------------------------------------------------
echo ""
echo "--- 9c. scripts/monitor/monitor-web.sh: расширенные метрики ---"

for field in RX_TOTAL TX_TOTAL MEM_AVAIL MEM_BUFFERS MEM_CACHED DISK_INODES PROC_COUNT OPEN_FILES; do
    if grep -q "${field}" scripts/monitor/monitor-web.sh; then
        ok "scripts/monitor/monitor-web.sh: метрика ${field} собирается"
    else
        fail "scripts/monitor/monitor-web.sh: метрика ${field} отсутствует"
    fi
done

for jfield in rx_total tx_total mem_avail_mb mem_buffers_mb mem_cached_mb disk_inodes proc_count open_files; do
    if grep -q "'${jfield}'" scripts/monitor/monitor-web.sh; then
        ok "scripts/monitor/monitor-web.sh: JSON-поле ${jfield} записывается"
    else
        fail "scripts/monitor/monitor-web.sh: JSON-поле ${jfield} не записывается"
    fi
done

# ---------------------------------------------------------------------------
# 9d. scripts/monitor/dashboard.html: расширенные метрики и округление
# ---------------------------------------------------------------------------
echo ""
echo "--- 9d. scripts/monitor/dashboard.html: расширенные метрики и округление ---"

if grep -q 'fmtBytesTotal' scripts/monitor/dashboard.html; then
    ok "scripts/monitor/dashboard.html: функция fmtBytesTotal() для общего трафика"
else
    fail "scripts/monitor/dashboard.html: функция fmtBytesTotal() отсутствует"
fi

if grep -q 'fmtMB' scripts/monitor/dashboard.html; then
    ok "scripts/monitor/dashboard.html: функция fmtMB() для округления памяти"
else
    fail "scripts/monitor/dashboard.html: функция fmtMB() отсутствует"
fi

if grep -q 'hdr-traffic' scripts/monitor/dashboard.html; then
    ok "scripts/monitor/dashboard.html: общий трафик в шапке (hdr-traffic)"
else
    fail "scripts/monitor/dashboard.html: общий трафик в шапке отсутствует"
fi

for elemid in rxtotal-v1 txtotal-v1 rxtotal-v2 txtotal-v2; do
    if grep -q "id=\"${elemid}\"" scripts/monitor/dashboard.html; then
        ok "scripts/monitor/dashboard.html: элемент ${elemid} присутствует"
    else
        fail "scripts/monitor/dashboard.html: элемент ${elemid} отсутствует"
    fi
done

if grep -q 'renderHdrTraffic' scripts/monitor/dashboard.html; then
    ok "scripts/monitor/dashboard.html: функция renderHdrTraffic() вызывается"
else
    fail "scripts/monitor/dashboard.html: функция renderHdrTraffic() не вызывается"
fi

if grep -q 'ringSvg' scripts/monitor/dashboard.html; then
    ok "scripts/monitor/dashboard.html: кольцевые диаграммы (ringSvg) для RAM/Disk"
else
    fail "scripts/monitor/dashboard.html: кольцевые диаграммы отсутствуют"
fi

if grep -q 'gauges-row' scripts/monitor/dashboard.html; then
    ok "scripts/monitor/dashboard.html: ряд gauge-диаграмм присутствует"
else
    fail "scripts/monitor/dashboard.html: ряд gauge-диаграмм отсутствует"
fi

if grep -q 'html\.light' scripts/monitor/dashboard.html; then
    ok "scripts/monitor/dashboard.html: светлая тема (html.light) присутствует"
else
    fail "scripts/monitor/dashboard.html: светлая тема отсутствует"
fi

if grep -q 'theme-btn' scripts/monitor/dashboard.html; then
    ok "scripts/monitor/dashboard.html: кнопка переключения темы присутствует"
else
    fail "scripts/monitor/dashboard.html: кнопка переключения темы отсутствует"
fi

if grep -q 'H=44' scripts/monitor/dashboard.html || grep -q 'height: 44px' scripts/monitor/dashboard.html; then
    ok "scripts/monitor/dashboard.html: увеличенная высота графика скорости"
else
    fail "scripts/monitor/dashboard.html: высота графика не увеличена"
fi

# ---------------------------------------------------------------------------
# 9e. Anti-flickering: dashboard merges previous data, server sends no-cache
# ---------------------------------------------------------------------------
echo ""
echo "--- 9e. Anti-flickering и Cache-Control ---"

if grep -q 'mergeVps' scripts/monitor/dashboard.html; then
    ok "scripts/monitor/dashboard.html: mergeVps() предотвращает мерцание нулевых значений"
else
    fail "scripts/monitor/dashboard.html: mergeVps() отсутствует — total-значения могут мерцать"
fi

if grep -q 'no-store.*no-cache\|no-cache.*no-store' scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: HTTP-сервер отправляет Cache-Control: no-store для data.json"
else
    fail "scripts/monitor/monitor-web.sh: HTTP-сервер не отправляет Cache-Control для data.json"
fi

if grep -q "data\.json" scripts/monitor/monitor-web.sh | head -1 && \
   grep -q '_no_cache' scripts/monitor/monitor-web.sh; then
    ok "scripts/monitor/monitor-web.sh: no-cache применяется только к data.json"
else
    fail "scripts/monitor/monitor-web.sh: нет выборочного no-cache для data.json"
fi

# ---------------------------------------------------------------------------
# 9f. Интервал обновления: backend <= 3s, frontend <= 3s
# ---------------------------------------------------------------------------
echo ""
echo "--- 9f. Интервал обновления ---"

backend_interval=$(grep -m1 '^INTERVAL=' scripts/monitor/monitor-web.sh | head -1 | sed 's/INTERVAL=//')
if [[ -n "$backend_interval" && "$backend_interval" -le 3 ]]; then
    ok "scripts/monitor/monitor-web.sh: INTERVAL=${backend_interval}s (<= 3s)"
else
    fail "scripts/monitor/monitor-web.sh: INTERVAL=${backend_interval:-?}s (должен быть <= 3s для быстрого обновления)"
fi

frontend_poll=$(grep -m1 'POLL_MS' scripts/monitor/dashboard.html | head -1 | grep -oE '[0-9]+')
if [[ -n "$frontend_poll" && "$frontend_poll" -le 3000 ]]; then
    ok "scripts/monitor/dashboard.html: POLL_MS=${frontend_poll}ms (<= 3000ms)"
else
    fail "scripts/monitor/dashboard.html: POLL_MS=${frontend_poll:-?}ms (должен быть <= 3000ms)"
fi

# ---------------------------------------------------------------------------
# 10. scripts/windows/install-ca.ps1 присутствует и корректен
# ---------------------------------------------------------------------------
echo ""
echo "--- 10. scripts/windows/install-ca.ps1: скрипт установки CA-сертификата ---"

if [[ -f "scripts/windows/install-ca.ps1" ]]; then
    ok "scripts/windows/install-ca.ps1 существует"
else
    fail "scripts/windows/install-ca.ps1 отсутствует"
fi

if grep -q '10.8.0.2:8080/ca.crt' scripts/windows/install-ca.ps1 2>/dev/null; then
    ok "scripts/windows/install-ca.ps1: URL CA-сертификата корректен (10.8.0.2:8080/ca.crt)"
else
    fail "scripts/windows/install-ca.ps1: URL CA-сертификата не найден"
fi

if grep -q 'Test-Connection.*10.9.0.1' scripts/windows/install-ca.ps1 2>/dev/null; then
    ok "scripts/windows/install-ca.ps1: проверяет подключение к VPN (10.9.0.1)"
else
    fail "scripts/windows/install-ca.ps1: не проверяет подключение к VPN"
fi

if grep -q 'StoreName.*Root\|StoreName]::Root' scripts/windows/install-ca.ps1 2>/dev/null && \
   grep -q 'LocalMachine' scripts/windows/install-ca.ps1 2>/dev/null; then
    ok "scripts/windows/install-ca.ps1: устанавливает в Trusted Root CAs (LocalMachine)"
else
    fail "scripts/windows/install-ca.ps1: не устанавливает в Trusted Root CAs"
fi

# ---------------------------------------------------------------------------
# 11. scripts/deploy/deploy-proxy.sh: AdGuard Home останавливается принудительно
# ---------------------------------------------------------------------------
echo ""
echo "--- 11. scripts/deploy/deploy-proxy.sh: конфликт портов AdGuard/youtube-proxy ---"

if [[ -f "scripts/deploy/deploy-proxy.sh" ]]; then
    ok "scripts/deploy/deploy-proxy.sh существует"
else
    fail "scripts/deploy/deploy-proxy.sh отсутствует"
fi

if grep -q 'systemctl stop AdGuardHome' scripts/deploy/deploy-proxy.sh 2>/dev/null; then
    ok "scripts/deploy/deploy-proxy.sh: AdGuard Home останавливается"
else
    fail "scripts/deploy/deploy-proxy.sh: AdGuard Home не останавливается"
fi

if grep -q 'systemctl disable AdGuardHome' scripts/deploy/deploy-proxy.sh 2>/dev/null; then
    ok "scripts/deploy/deploy-proxy.sh: AdGuard Home отключается из автозапуска"
else
    fail "scripts/deploy/deploy-proxy.sh: AdGuard Home не отключается из автозапуска"
fi

if grep -q '10.9.0.0/24.*ACCEPT' scripts/deploy/deploy-proxy.sh 2>/dev/null; then
    ok "scripts/deploy/deploy-proxy.sh: SSH разрешён из VPN-сети (10.9.0.0/24)"
else
    fail "scripts/deploy/deploy-proxy.sh: SSH из VPN-сети не разрешён"
fi

if grep -q 'tcp.*443.*awg0.*ACCEPT\|443.*awg0' scripts/deploy/deploy-proxy.sh 2>/dev/null; then
    ok "scripts/deploy/deploy-proxy.sh: TCP 443 с awg0 разрешён (YouTube HTTPS прокси)"
else
    fail "scripts/deploy/deploy-proxy.sh: TCP 443 с awg0 не разрешён — YouTube прокси может не работать"
fi

if grep -q 'scripts/windows/install-ca.ps1' scripts/deploy/deploy-proxy.sh 2>/dev/null; then
    ok "scripts/deploy/deploy-proxy.sh: упоминает scripts/windows/install-ca.ps1 в инструкции"
else
    fail "scripts/deploy/deploy-proxy.sh: не упоминает scripts/windows/install-ca.ps1"
fi

# ---------------------------------------------------------------------------
# 12. scripts/tools/diagnose.sh присутствует и корректен
# ---------------------------------------------------------------------------
echo ""
echo "--- 12. scripts/tools/diagnose.sh: скрипт диагностики ---"

if [[ -f "scripts/tools/diagnose.sh" ]]; then
    ok "scripts/tools/diagnose.sh существует"
else
    fail "scripts/tools/diagnose.sh отсутствует"
fi

if bash -n <(tr -d '\r' < scripts/tools/diagnose.sh) 2>/dev/null; then
    ok "scripts/tools/diagnose.sh: синтаксис bash корректен"
else
    fail "scripts/tools/diagnose.sh: ошибка синтаксиса bash"
fi

for check in 'youtube-proxy' 'AdGuardHome' 'MASQUERADE' 'awg0' 'port53' '--fix'; do
    if grep -q "$check" scripts/tools/diagnose.sh 2>/dev/null; then
        ok "scripts/tools/diagnose.sh: проверяет '$check'"
    else
        fail "scripts/tools/diagnose.sh: не проверяет '$check'"
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
