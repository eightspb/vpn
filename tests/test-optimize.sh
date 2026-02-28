#!/usr/bin/env bash
# tests/test-optimize.sh — проверки скриптов оптимизации и split tunneling
# Запуск: bash tests/test-optimize.sh

set -u

PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "=== Тесты оптимизации VPN (scripts/tools/optimize-vpn.sh, scripts/tools/benchmark.sh, split tunneling) ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Наличие файлов
# ---------------------------------------------------------------------------
echo "--- 1. Файлы присутствуют ---"

for f in scripts/tools/optimize-vpn.sh scripts/tools/benchmark.sh; do
    if [[ -f "$f" ]]; then
        ok "$f существует"
    else
        fail "$f отсутствует"
    fi
done

for f in vpn-output/client-split.conf vpn-output/phone-split.conf; do
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

for f in scripts/tools/optimize-vpn.sh scripts/tools/benchmark.sh; do
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
# 3. Скрипты подключают lib/common.sh
# ---------------------------------------------------------------------------
echo ""
echo "--- 3. Скрипты подключают lib/common.sh ---"

for f in scripts/tools/optimize-vpn.sh scripts/tools/benchmark.sh; do
    if grep -q 'source.*lib/common\.sh' "$f" 2>/dev/null; then
        ok "$f: source lib/common.sh найден"
    else
        fail "$f: source lib/common.sh не найден"
    fi
done

# ---------------------------------------------------------------------------
# 4. scripts/tools/optimize-vpn.sh содержит флаг --benchmark-only
# ---------------------------------------------------------------------------
echo ""
echo "--- 4. scripts/tools/optimize-vpn.sh: флаг --benchmark-only ---"

if grep -q '\-\-benchmark-only' scripts/tools/optimize-vpn.sh 2>/dev/null; then
    ok "scripts/tools/optimize-vpn.sh: --benchmark-only найден"
else
    fail "scripts/tools/optimize-vpn.sh: --benchmark-only не найден"
fi

if grep -q 'BENCHMARK_ONLY' scripts/tools/optimize-vpn.sh 2>/dev/null; then
    ok "scripts/tools/optimize-vpn.sh: переменная BENCHMARK_ONLY найдена"
else
    fail "scripts/tools/optimize-vpn.sh: переменная BENCHMARK_ONLY не найдена"
fi

# ---------------------------------------------------------------------------
# 5. scripts/tools/optimize-vpn.sh содержит ключевые sysctl параметры
# ---------------------------------------------------------------------------
echo ""
echo "--- 5. scripts/tools/optimize-vpn.sh: sysctl параметры ---"

check_sysctl() {
    local param="$1"
    if grep -q "$param" scripts/tools/optimize-vpn.sh 2>/dev/null; then
        ok "scripts/tools/optimize-vpn.sh: содержит ${param}"
    else
        fail "scripts/tools/optimize-vpn.sh: не содержит ${param}"
    fi
}

check_sysctl "tcp_slow_start_after_idle"
check_sysctl "nf_conntrack_max=524288"
check_sysctl "rmem_max=67108864"
check_sysctl "wmem_max=67108864"
check_sysctl "tcp_congestion_control=bbr"
check_sysctl "default_qdisc=fq"
check_sysctl "tcp_fastopen=3"
check_sysctl "nf_conntrack_tcp_timeout_established"
check_sysctl "99-vpn.conf"

# ---------------------------------------------------------------------------
# 6. scripts/tools/optimize-vpn.sh содержит MTU значения
# ---------------------------------------------------------------------------
echo ""
echo "--- 6. scripts/tools/optimize-vpn.sh: MTU значения ---"

if grep -q '1420' scripts/tools/optimize-vpn.sh 2>/dev/null; then
    ok "scripts/tools/optimize-vpn.sh: MTU 1420 найден"
else
    fail "scripts/tools/optimize-vpn.sh: MTU 1420 не найден"
fi

if grep -q '1360' scripts/tools/optimize-vpn.sh 2>/dev/null; then
    ok "scripts/tools/optimize-vpn.sh: MTU 1360 найден"
else
    fail "scripts/tools/optimize-vpn.sh: MTU 1360 не найден"
fi

# ---------------------------------------------------------------------------
# 7. scripts/tools/optimize-vpn.sh содержит MSS 1320
# ---------------------------------------------------------------------------
echo ""
echo "--- 7. scripts/tools/optimize-vpn.sh: MSS clamp ---"

if grep -q 'set-mss 1320' scripts/tools/optimize-vpn.sh 2>/dev/null; then
    ok "scripts/tools/optimize-vpn.sh: MSS 1320 найден"
else
    fail "scripts/tools/optimize-vpn.sh: MSS 1320 не найден"
fi

if grep -q 'TCPMSS' scripts/tools/optimize-vpn.sh 2>/dev/null; then
    ok "scripts/tools/optimize-vpn.sh: TCPMSS найден"
else
    fail "scripts/tools/optimize-vpn.sh: TCPMSS не найден"
fi

# ---------------------------------------------------------------------------
# 8. scripts/tools/optimize-vpn.sh содержит PersistentKeepalive
# ---------------------------------------------------------------------------
echo ""
echo "--- 8. scripts/tools/optimize-vpn.sh: PersistentKeepalive ---"

if grep -q 'PersistentKeepalive = 60' scripts/tools/optimize-vpn.sh 2>/dev/null; then
    ok "scripts/tools/optimize-vpn.sh: PersistentKeepalive = 60 найден"
else
    fail "scripts/tools/optimize-vpn.sh: PersistentKeepalive = 60 не найден"
fi

# ---------------------------------------------------------------------------
# 9. scripts/tools/optimize-vpn.sh содержит Junk параметры
# ---------------------------------------------------------------------------
echo ""
echo "--- 9. scripts/tools/optimize-vpn.sh: Junk параметры ---"

for param in "Jc   = 2" "Jmin = 20" "Jmax = 200" "S1   = 15" "S2   = 20"; do
    if grep -q "$param" scripts/tools/optimize-vpn.sh 2>/dev/null; then
        ok "scripts/tools/optimize-vpn.sh: '${param}' найден"
    else
        fail "scripts/tools/optimize-vpn.sh: '${param}' не найден"
    fi
done

# ---------------------------------------------------------------------------
# 10. Split tunneling конфиги: AllowedIPs не содержат 0.0.0.0/0
# ---------------------------------------------------------------------------
echo ""
echo "--- 10. Split tunneling конфиги: AllowedIPs ---"

for f in vpn-output/client-split.conf vpn-output/phone-split.conf; do
    if [[ ! -f "$f" ]]; then
        fail "$f: файл отсутствует"
        continue
    fi

    if grep -q 'AllowedIPs' "$f" 2>/dev/null; then
        ok "$f: AllowedIPs найден"
    else
        fail "$f: AllowedIPs не найден"
    fi

    if ! grep -E '^AllowedIPs\s*=\s*0\.0\.0\.0/0\s*$' "$f" 2>/dev/null | grep -q .; then
        ok "$f: AllowedIPs не равен 0.0.0.0/0 (split tunneling активен)"
    else
        fail "$f: AllowedIPs = 0.0.0.0/0 (split tunneling не настроен)"
    fi

    if grep -q '0\.0\.0\.0/1' "$f" 2>/dev/null; then
        ok "$f: содержит 0.0.0.0/1 (публичный трафик через VPN)"
    else
        fail "$f: не содержит 0.0.0.0/1"
    fi
done

# ---------------------------------------------------------------------------
# 11. Оригинальные конфиги содержат комментарий о split tunneling
# ---------------------------------------------------------------------------
echo ""
echo "--- 11. Оригинальные конфиги: комментарий о split tunneling ---"

for f in vpn-output/client.conf vpn-output/phone.conf; do
    if [[ ! -f "$f" ]]; then
        fail "$f: файл отсутствует"
        continue
    fi
    if grep -q 'split' "$f" 2>/dev/null; then
        ok "$f: комментарий о split tunneling найден"
    else
        fail "$f: комментарий о split tunneling не найден"
    fi
done

# ---------------------------------------------------------------------------
# 12. scripts/tools/benchmark.sh содержит ключевые метрики
# ---------------------------------------------------------------------------
echo ""
echo "--- 12. scripts/tools/benchmark.sh: ключевые метрики ---"

for metric in "ping" "speed_download" "mtu" "handshakes" "rmem_max" "tcp_congestion_control" "10.8.0.2"; do
    if grep -qi "$metric" scripts/tools/benchmark.sh 2>/dev/null; then
        ok "scripts/tools/benchmark.sh: содержит метрику '${metric}'"
    else
        fail "scripts/tools/benchmark.sh: не содержит метрику '${metric}'"
    fi
done

# ---------------------------------------------------------------------------
# 13. scripts/tools/optimize-vpn.sh содержит флаги --vps1-only и --vps2-only
# ---------------------------------------------------------------------------
echo ""
echo "--- 13. scripts/tools/optimize-vpn.sh: флаги --vps1-only и --vps2-only ---"

for flag in 'vps1-only' 'vps2-only'; do
    if grep -q -- "$flag" scripts/tools/optimize-vpn.sh 2>/dev/null; then
        ok "scripts/tools/optimize-vpn.sh: --${flag} найден"
    else
        fail "scripts/tools/optimize-vpn.sh: --${flag} не найден"
    fi
done

# ---------------------------------------------------------------------------
# 14. scripts/tools/optimize-vpn.sh использует ssh_run_script из lib/common.sh
# ---------------------------------------------------------------------------
echo ""
echo "--- 14. scripts/tools/optimize-vpn.sh: использует SSH-хелперы ---"

for fn in "ssh_run_script" "ssh_exec" "load_defaults_from_files" "prepare_key_for_ssh" "cleanup_temp_keys"; do
    if grep -q "$fn" scripts/tools/optimize-vpn.sh 2>/dev/null; then
        ok "scripts/tools/optimize-vpn.sh: вызывает ${fn}"
    else
        fail "scripts/tools/optimize-vpn.sh: не вызывает ${fn}"
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
