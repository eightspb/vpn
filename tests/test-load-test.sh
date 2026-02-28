#!/usr/bin/env bash
# tests/test-scripts/tools/load-test.sh — проверки скрипта нагрузочного тестирования
# Запуск: bash tests/test-scripts/tools/load-test.sh

set -u

PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "=== Тесты нагрузочного тестирования (scripts/tools/load-test.sh) ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Файл существует
# ---------------------------------------------------------------------------
echo "--- 1. Файл присутствует ---"

if [[ -f "scripts/tools/load-test.sh" ]]; then
    ok "scripts/tools/load-test.sh существует"
else
    fail "scripts/tools/load-test.sh отсутствует"
fi

# ---------------------------------------------------------------------------
# 2. Синтаксис bash корректен
# ---------------------------------------------------------------------------
echo ""
echo "--- 2. Синтаксис bash ---"

if [[ -f "scripts/tools/load-test.sh" ]]; then
    if bash -n <(tr -d '\r' < "scripts/tools/load-test.sh") 2>/dev/null; then
        ok "scripts/tools/load-test.sh: синтаксис bash корректен"
    else
        fail "scripts/tools/load-test.sh: ошибка синтаксиса bash"
    fi
else
    fail "scripts/tools/load-test.sh: файл отсутствует"
fi

# ---------------------------------------------------------------------------
# 3. Подключает lib/common.sh
# ---------------------------------------------------------------------------
echo ""
echo "--- 3. Подключает lib/common.sh ---"

if grep -q 'source.*lib/common\.sh' scripts/tools/load-test.sh 2>/dev/null; then
    ok "scripts/tools/load-test.sh: source lib/common.sh найден"
else
    fail "scripts/tools/load-test.sh: source lib/common.sh не найден"
fi

# ---------------------------------------------------------------------------
# 4. Содержит ключевые флаги CLI
# ---------------------------------------------------------------------------
echo ""
echo "--- 4. Флаги CLI ---"

for flag in '--vps1-only' '--vps2-only' '--max-connections' '--step' '--duration' \
            '--bandwidth-only' '--connections-only' '--quick' '--output' '--help'; do
    if grep -q -- "$flag" scripts/tools/load-test.sh 2>/dev/null; then
        ok "scripts/tools/load-test.sh: флаг ${flag} найден"
    else
        fail "scripts/tools/load-test.sh: флаг ${flag} не найден"
    fi
done

# ---------------------------------------------------------------------------
# 5. Содержит ключевые тестовые функции
# ---------------------------------------------------------------------------
echo ""
echo "--- 5. Тестовые функции ---"

for fn in 'test_bandwidth' 'test_connections' 'test_conntrack' \
          'test_tunnel_latency' 'test_wireguard_throughput' \
          'collect_system_metrics' 'full_server_report' 'install_load_tools'; do
    if grep -q "$fn" scripts/tools/load-test.sh 2>/dev/null; then
        ok "scripts/tools/load-test.sh: функция ${fn} найдена"
    else
        fail "scripts/tools/load-test.sh: функция ${fn} не найдена"
    fi
done

# ---------------------------------------------------------------------------
# 6. Собирает метрики CPU, RAM, диска
# ---------------------------------------------------------------------------
echo ""
echo "--- 6. Метрики системы ---"

for metric in 'CPU_COUNT' 'CPU_LOAD' 'CPU_USAGE' 'MEM_TOTAL' 'MEM_USED' \
              'MEM_AVAILABLE' 'SWAP_USED' 'DISK_USAGE' 'CONNTRACK_COUNT' \
              'CONNTRACK_MAX' 'AWG_PEERS'; do
    if grep -q "$metric" scripts/tools/load-test.sh 2>/dev/null; then
        ok "scripts/tools/load-test.sh: метрика ${metric} найдена"
    else
        fail "scripts/tools/load-test.sh: метрика ${metric} не найдена"
    fi
done

# ---------------------------------------------------------------------------
# 7. Использует SSH-хелперы из lib/common.sh
# ---------------------------------------------------------------------------
echo ""
echo "--- 7. Использует SSH-хелперы ---"

for fn in 'ssh_exec' 'ssh_run_script' 'load_defaults_from_files' \
          'prepare_key_for_ssh' 'cleanup_temp_keys' 'check_deps'; do
    if grep -q "$fn" scripts/tools/load-test.sh 2>/dev/null; then
        ok "scripts/tools/load-test.sh: вызывает ${fn}"
    else
        fail "scripts/tools/load-test.sh: не вызывает ${fn}"
    fi
done

# ---------------------------------------------------------------------------
# 8. Содержит тест пропускной способности (bandwidth)
# ---------------------------------------------------------------------------
echo ""
echo "--- 8. Тест bandwidth ---"

if grep -q 'cloudflare' scripts/tools/load-test.sh 2>/dev/null; then
    ok "scripts/tools/load-test.sh: использует Cloudflare для теста скорости"
else
    fail "scripts/tools/load-test.sh: не использует Cloudflare для теста скорости"
fi

if grep -q 'speed_download' scripts/tools/load-test.sh 2>/dev/null; then
    ok "scripts/tools/load-test.sh: замеряет speed_download"
else
    fail "scripts/tools/load-test.sh: не замеряет speed_download"
fi

if grep -q 'speed_upload' scripts/tools/load-test.sh 2>/dev/null; then
    ok "scripts/tools/load-test.sh: замеряет speed_upload"
else
    fail "scripts/tools/load-test.sh: не замеряет speed_upload"
fi

# ---------------------------------------------------------------------------
# 9. Содержит тест масштабирования соединений
# ---------------------------------------------------------------------------
echo ""
echo "--- 9. Тест соединений ---"

if grep -q 'ab -n' scripts/tools/load-test.sh 2>/dev/null; then
    ok "scripts/tools/load-test.sh: использует Apache Bench (ab) для теста соединений"
else
    fail "scripts/tools/load-test.sh: не использует Apache Bench (ab)"
fi

if grep -q 'degradation' scripts/tools/load-test.sh 2>/dev/null || grep -qi 'деградац' scripts/tools/load-test.sh 2>/dev/null; then
    ok "scripts/tools/load-test.sh: определяет деградацию latency"
else
    fail "scripts/tools/load-test.sh: не определяет деградацию latency"
fi

# ---------------------------------------------------------------------------
# 10. Содержит тест conntrack
# ---------------------------------------------------------------------------
echo ""
echo "--- 10. Тест conntrack ---"

if grep -q 'nf_conntrack_max' scripts/tools/load-test.sh 2>/dev/null; then
    ok "scripts/tools/load-test.sh: проверяет nf_conntrack_max"
else
    fail "scripts/tools/load-test.sh: не проверяет nf_conntrack_max"
fi

if grep -q 'nf_conntrack_count' scripts/tools/load-test.sh 2>/dev/null; then
    ok "scripts/tools/load-test.sh: проверяет nf_conntrack_count"
else
    fail "scripts/tools/load-test.sh: не проверяет nf_conntrack_count"
fi

# ---------------------------------------------------------------------------
# 11. Содержит тест задержки туннеля
# ---------------------------------------------------------------------------
echo ""
echo "--- 11. Тест задержки туннеля ---"

if grep -q '10\.8\.0\.2' scripts/tools/load-test.sh 2>/dev/null; then
    ok "scripts/tools/load-test.sh: тестирует туннель к 10.8.0.2"
else
    fail "scripts/tools/load-test.sh: не тестирует туннель к 10.8.0.2"
fi

if grep -q 'baseline' scripts/tools/load-test.sh 2>/dev/null; then
    ok "scripts/tools/load-test.sh: замеряет baseline latency"
else
    fail "scripts/tools/load-test.sh: не замеряет baseline latency"
fi

# ---------------------------------------------------------------------------
# 12. Содержит WireGuard throughput
# ---------------------------------------------------------------------------
echo ""
echo "--- 12. WireGuard throughput ---"

if grep -q 'awg show all transfer' scripts/tools/load-test.sh 2>/dev/null; then
    ok "scripts/tools/load-test.sh: собирает WireGuard transfer stats"
else
    fail "scripts/tools/load-test.sh: не собирает WireGuard transfer stats"
fi

# ---------------------------------------------------------------------------
# 13. Поддерживает сохранение отчёта в файл
# ---------------------------------------------------------------------------
echo ""
echo "--- 13. Сохранение отчёта ---"

if grep -q 'OUTPUT_FILE' scripts/tools/load-test.sh 2>/dev/null; then
    ok "scripts/tools/load-test.sh: поддерживает --output (OUTPUT_FILE)"
else
    fail "scripts/tools/load-test.sh: не поддерживает --output"
fi

# ---------------------------------------------------------------------------
# 14. Устанавливает зависимости на сервере
# ---------------------------------------------------------------------------
echo ""
echo "--- 14. Установка зависимостей ---"

if grep -q 'iperf3' scripts/tools/load-test.sh 2>/dev/null; then
    ok "scripts/tools/load-test.sh: устанавливает iperf3"
else
    fail "scripts/tools/load-test.sh: не устанавливает iperf3"
fi

if grep -q 'apache2-utils' scripts/tools/load-test.sh 2>/dev/null; then
    ok "scripts/tools/load-test.sh: устанавливает apache2-utils (ab)"
else
    fail "scripts/tools/load-test.sh: не устанавливает apache2-utils"
fi

# ---------------------------------------------------------------------------
# 15. Режим --quick работает (параметры корректны)
# ---------------------------------------------------------------------------
echo ""
echo "--- 15. Режим --quick ---"

if grep -q 'MAX_CONNECTIONS=100' scripts/tools/load-test.sh 2>/dev/null; then
    ok "scripts/tools/load-test.sh: --quick устанавливает MAX_CONNECTIONS=100"
else
    fail "scripts/tools/load-test.sh: --quick не устанавливает MAX_CONNECTIONS=100"
fi

if grep -q 'STEP=25' scripts/tools/load-test.sh 2>/dev/null; then
    ok "scripts/tools/load-test.sh: --quick устанавливает STEP=25"
else
    fail "scripts/tools/load-test.sh: --quick не устанавливает STEP=25"
fi

if grep -q 'DURATION=5' scripts/tools/load-test.sh 2>/dev/null; then
    ok "scripts/tools/load-test.sh: --quick устанавливает DURATION=5"
else
    fail "scripts/tools/load-test.sh: --quick не устанавливает DURATION=5"
fi

# ---------------------------------------------------------------------------
# 16. Собирает метрики ДО и ПОСЛЕ нагрузки
# ---------------------------------------------------------------------------
echo ""
echo "--- 16. Метрики до/после нагрузки ---"

before_count=$(grep -c 'full_server_report' scripts/tools/load-test.sh 2>/dev/null || echo 0)
if [[ "$before_count" -ge 4 ]]; then
    ok "scripts/tools/load-test.sh: собирает метрики до и после нагрузки (${before_count} вызовов full_server_report)"
else
    fail "scripts/tools/load-test.sh: недостаточно вызовов full_server_report (${before_count}, ожидается >=4)"
fi

# ---------------------------------------------------------------------------
# 17. Помощь (--help) выводит описание
# ---------------------------------------------------------------------------
echo ""
echo "--- 17. Справка --help ---"

if grep -q '\-\-help' scripts/tools/load-test.sh 2>/dev/null; then
    ok "scripts/tools/load-test.sh: --help обработан"
else
    fail "scripts/tools/load-test.sh: --help не обработан"
fi

# ---------------------------------------------------------------------------
# Итог
# ---------------------------------------------------------------------------
echo ""
echo "================================="
echo "Итого: PASS=$PASS  FAIL=$FAIL"
echo "================================="
echo ""

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
