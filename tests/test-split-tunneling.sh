#!/usr/bin/env bash
# =============================================================================
# test-split-tunneling.sh — статические тесты артефактов split tunneling
#
# Проверяет:
#   - Наличие всех файлов
#   - Синтаксис bash-скриптов
#   - Корректность конфигов dnsmasq и systemd
#   - Наличие критичных команд/директив (CONNMARK, ipset, fwmark, etc.)
#   - Идемпотентность паттернов (-C проверка перед -A/-I)
#   - Zero-downtime последовательность в apply.sh
#   - Полный список удалений в rollback.sh
#
# Интеграционные тесты с реальным VPS — отдельно через --dry-run в
# setup-split-tunneling.sh (требует SSH-доступа).
#
# Использование:
#   bash tests/test-split-tunneling.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS_DIR="${PROJECT_ROOT}/scripts/deploy/split-tunneling"
SETUP_SCRIPT="${PROJECT_ROOT}/scripts/deploy/setup-split-tunneling.sh"

PASS=0; FAIL=0

pass() { PASS=$((PASS + 1)); echo -e "\033[0;32m  ✓ $*\033[0m"; }
fail() { FAIL=$((FAIL + 1)); echo -e "\033[0;31m  ✗ $*\033[0m"; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   test-split-tunneling.sh — статические тесты split tunneling ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── 1. Существование артефактов ─────────────────────────────────────────────
echo ""
echo "── 1. Наличие артефактов ──"

for f in \
    "scripts/deploy/setup-split-tunneling.sh" \
    "scripts/deploy/split-tunneling/dnsmasq-vpn.conf" \
    "scripts/deploy/split-tunneling/dnsmasq.service.d/override.conf" \
    "scripts/deploy/split-tunneling/split-tunnel-apply.sh" \
    "scripts/deploy/split-tunneling/split-tunnel-rollback.sh" \
    "scripts/deploy/split-tunneling/split-tunnel-restore.service" \
    "scripts/deploy/split-tunneling/restore-vpn-routing.sh"; do
    if [[ -f "${PROJECT_ROOT}/${f}" ]]; then
        pass "exists: $f"
    else
        fail "MISSING: $f"
    fi
done

# ── 2. Bash-скрипты: синтаксис и executable ─────────────────────────────────
echo ""
echo "── 2. Синтаксис bash-скриптов ──"

check_bash_syntax() {
    local f="$1"
    if bash -n "$f" 2>/dev/null; then
        pass "syntax OK: $(basename "$f")"
    else
        fail "syntax FAIL: $(basename "$f")"
        bash -n "$f" 2>&1 | head -5 | sed 's/^/      /'
    fi
}

check_executable() {
    local f="$1"
    if [[ -x "$f" ]]; then
        pass "executable: $(basename "$f")"
    else
        fail "NOT executable: $(basename "$f") (run: chmod +x $f)"
    fi
}

check_bash_syntax "${SETUP_SCRIPT}"
check_bash_syntax "${ARTIFACTS_DIR}/split-tunnel-apply.sh"
check_bash_syntax "${ARTIFACTS_DIR}/split-tunnel-rollback.sh"
check_bash_syntax "${ARTIFACTS_DIR}/restore-vpn-routing.sh"

check_executable "${SETUP_SCRIPT}"
check_executable "${ARTIFACTS_DIR}/split-tunnel-apply.sh"
check_executable "${ARTIFACTS_DIR}/split-tunnel-rollback.sh"
check_executable "${ARTIFACTS_DIR}/restore-vpn-routing.sh"

# ── 3. dnsmasq-vpn.conf — критичные директивы ───────────────────────────────
echo ""
echo "── 3. dnsmasq-vpn.conf ──"

DNSMASQ_CONF="${ARTIFACTS_DIR}/dnsmasq-vpn.conf"

check_in_file() {
    local file="$1" pattern="$2" desc="$3"
    if grep -qE -- "$pattern" "$file" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc — отсутствует (pattern: $pattern)"
    fi
}

check_in_file "$DNSMASQ_CONF" '^listen-address=10\.9\.0\.1$' "listen-address=10.9.0.1"
check_in_file "$DNSMASQ_CONF" '^bind-dynamic$'                "bind-dynamic (выживает перезапуск awg1)"
check_in_file "$DNSMASQ_CONF" '^no-resolv$'                   "no-resolv (не использовать /etc/resolv.conf)"
check_in_file "$DNSMASQ_CONF" '^server=10\.8\.0\.2$'          "upstream server=10.8.0.2 (AdGuard на VPS2)"
check_in_file "$DNSMASQ_CONF" '^ipset=/\.ru/\.xn--p1ai/\.su/ru_subnets$' "ipset для .ru/.рф (xn--p1ai)/.su → ru_subnets"

# ── 4. systemd drop-in для dnsmasq ──────────────────────────────────────────
echo ""
echo "── 4. dnsmasq.service.d/override.conf ──"

OVERRIDE_CONF="${ARTIFACTS_DIR}/dnsmasq.service.d/override.conf"

check_in_file "$OVERRIDE_CONF" '^After=.*awg-quick@awg1\.service'  "After awg-quick@awg1"
check_in_file "$OVERRIDE_CONF" '^Wants=.*awg-quick@awg1\.service'  "Wants awg-quick@awg1"
check_in_file "$OVERRIDE_CONF" '^Restart=always$'                  "Restart=always"

# ── 5. split-tunnel-restore.service ─────────────────────────────────────────
echo ""
echo "── 5. split-tunnel-restore.service ──"

RESTORE_SVC="${ARTIFACTS_DIR}/split-tunnel-restore.service"

check_in_file "$RESTORE_SVC" '^After=.*awg-quick@awg1'  "After awg-quick@awg1"
check_in_file "$RESTORE_SVC" '^After=.*dnsmasq'         "After dnsmasq"
check_in_file "$RESTORE_SVC" '^Type=oneshot$'           "Type=oneshot"
check_in_file "$RESTORE_SVC" 'ExecStart=.*split-tunnel-apply\.sh'   "ExecStart→apply.sh"
check_in_file "$RESTORE_SVC" '^WantedBy=multi-user\.target$'        "WantedBy=multi-user.target"

# ── 6. split-tunnel-apply.sh — критичные паттерны ───────────────────────────
echo ""
echo "── 6. split-tunnel-apply.sh ──"

APPLY_SH="${ARTIFACTS_DIR}/split-tunnel-apply.sh"

check_in_file "$APPLY_SH" 'set -euo pipefail'                   "set -euo pipefail"
check_in_file "$APPLY_SH" 'ipset create -.\s|ipset create.*hash:ip' "ipset create (hash:ip)"
check_in_file "$APPLY_SH" 'timeout 604800'                       "ipset timeout 604800 (7d)"
check_in_file "$APPLY_SH" 'rp_filter=2'                          "rp_filter=2 (loose mode)"
check_in_file "$APPLY_SH" 'CONNMARK --restore-mark'              "CONNMARK --restore-mark (для ESTABLISHED)"
check_in_file "$APPLY_SH" 'CONNMARK --save-mark'                 "CONNMARK --save-mark (для NEW)"
check_in_file "$APPLY_SH" 'ctstate ESTABLISHED'                  "match ESTABLISHED"
check_in_file "$APPLY_SH" 'ctstate NEW'                          "match NEW"
check_in_file "$APPLY_SH" '--match-set.*IPSET_NAME.*dst'         "match ipset (по dst через переменную IPSET_NAME)"
check_in_file "$APPLY_SH" 'IPSET_NAME=\\\$\\\{IPSET_NAME:-ru_subnets\\\}|IPSET_NAME:-ru_subnets' "default IPSET_NAME=ru_subnets"
check_in_file "$APPLY_SH" 'MARK --set-mark'                      "MARK --set-mark"
check_in_file "$APPLY_SH" 'ip rule add fwmark'                   "ip rule add fwmark"
check_in_file "$APPLY_SH" 'ip route replace default'             "ip route replace default (table 100)"
check_in_file "$APPLY_SH" 'POSTROUTING.*MASQUERADE'              "MASQUERADE на основном интерфейсе"
check_in_file "$APPLY_SH" 'ipt_ensure_top nat PREROUTING.*dport 53.*DNAT' "INSERT в начало (zero-downtime через ipt_ensure_top)"
check_in_file "$APPLY_SH" 'ipt_ensure_top\(\)|^ipt_ensure_top\(\)'  "helper-функция ipt_ensure_top определена"
check_in_file "$APPLY_SH" 'ipt_ensure\(\)|^ipt_ensure\(\)'          "helper-функция ipt_ensure определена"
check_in_file "$APPLY_SH" 'DNAT --to-destination'                "DNAT для DNS"
check_in_file "$APPLY_SH" 'systemctl is-active --quiet dnsmasq'  "healthcheck: systemctl is-active dnsmasq перед dig"
check_in_file "$APPLY_SH" 'logger -t split-tunnel-apply'         "logger в journald"
check_in_file "$APPLY_SH" 'EXISTING_RULES.*lookup \$\{ROUTE_TABLE\}|EXISTING_RULES.*lookup.*ROUTE_TABLE' "pre-flight: проверка занятости table"
check_in_file "$APPLY_SH" 'EXISTING_FWMARK'                      "pre-flight: проверка занятости fwmark"
check_in_file "$APPLY_SH" 'sysctl -w.*rp_filter.*\|\| true|rp_filter=2.*>/dev/null 2>&1 \|\| true' "rp_filter в loose mode с || true (защита от hot-remove)"

# Idempotency: правила добавляются через helper-функции, которые делают -C → -A/-I.
# Проверяем что не осталось прямых вызовов iptables -A/-I в hot path (обход helper).
echo ""
echo "── 6a. apply.sh: идемпотентность (через helper'ы ipt_ensure*) ──"

DIRECT_A=$(grep -cE '^\s*iptables.*-A (PREROUTING|POSTROUTING)' "$APPLY_SH" || true)
DIRECT_I=$(grep -cE '^\s*iptables.*-I (PREROUTING|POSTROUTING) 1' "$APPLY_SH" || true)
HELPER_USES=$(grep -cE '^\s*ipt_ensure(_top)? ' "$APPLY_SH" || true)

if [[ "$DIRECT_A" -eq 0 && "$DIRECT_I" -eq 0 && "$HELPER_USES" -ge 5 ]]; then
    pass "Idempotency: все iptables-правила через helper (${HELPER_USES} вызовов ipt_ensure*, прямых -A/-I в hot path нет)"
else
    fail "Idempotency: есть прямые iptables -A/-I в обход helper (A=$DIRECT_A, I=$DIRECT_I) или helper не используется (uses=$HELPER_USES)"
fi

# Zero-downtime: -I должен быть ДО удаления старых правил
echo ""
echo "── 6b. apply.sh: zero-downtime последовательность ──"

I_LINE=$(grep -nE 'ipt_ensure_top nat PREROUTING.*dport 53' "$APPLY_SH" | head -1 | cut -d: -f1)
D_LINE=$(grep -nE 'iptables.*-D PREROUTING.*ADGUARD_IP.*53' "$APPLY_SH" | head -1 | cut -d: -f1)
HEALTHCHECK_LINE=$(grep -nE 'DNS_OK=1|dig.*DNSMASQ_IP' "$APPLY_SH" | head -1 | cut -d: -f1)

if [[ -n "$I_LINE" && -n "$D_LINE" && "$I_LINE" -lt "$D_LINE" ]]; then
    pass "zero-downtime: INSERT нового DNAT (стр. $I_LINE) ДО DELETE старого (стр. $D_LINE)"
else
    fail "zero-downtime: INSERT не предшествует DELETE (I=$I_LINE D=$D_LINE)"
fi

if [[ -n "$HEALTHCHECK_LINE" && -n "$D_LINE" && "$HEALTHCHECK_LINE" -lt "$D_LINE" ]]; then
    pass "zero-downtime: healthcheck dnsmasq (стр. $HEALTHCHECK_LINE) ДО удаления старого DNAT (стр. $D_LINE)"
else
    fail "zero-downtime: healthcheck не предшествует удалению (HC=$HEALTHCHECK_LINE D=$D_LINE)"
fi

# ── 7. split-tunnel-rollback.sh — полнота отката ────────────────────────────
echo ""
echo "── 7. split-tunnel-rollback.sh ──"

ROLLBACK_SH="${ARTIFACTS_DIR}/split-tunnel-rollback.sh"

check_in_file "$ROLLBACK_SH" 'set -uo pipefail'                       "set -uo pipefail"
check_in_file "$ROLLBACK_SH" 'iptables.*-I PREROUTING 1.*ADGUARD_IP'  "восстанавливает старый DNAT на AdGuard (insert)"
check_in_file "$ROLLBACK_SH" 'ipt_drop_all nat PREROUTING.*dport 53.*DNSMASQ_IP' "удаляет новый DNAT на dnsmasq (через helper)"
check_in_file "$ROLLBACK_SH" 'systemctl stop dnsmasq'                 "останавливает dnsmasq"
check_in_file "$ROLLBACK_SH" 'ipt_drop_all mangle PREROUTING.*CONNMARK --restore-mark' "удаляет CONNMARK --restore-mark (через helper)"
check_in_file "$ROLLBACK_SH" 'ipt_drop_all mangle PREROUTING.*CONNMARK --save-mark'    "удаляет CONNMARK --save-mark (через helper)"
check_in_file "$ROLLBACK_SH" 'ipt_drop_all mangle PREROUTING.*MARK --set-mark'         "удаляет MARK --set-mark (через helper)"
check_in_file "$ROLLBACK_SH" 'ip rule del fwmark'                     "удаляет ip rule fwmark"
check_in_file "$ROLLBACK_SH" 'ip route flush table'                   "очищает таблицу маршрутизации"
check_in_file "$ROLLBACK_SH" 'ipt_drop_all nat POSTROUTING.*MASQUERADE' "удаляет MASQUERADE (через helper)"
check_in_file "$ROLLBACK_SH" 'ipset destroy'                          "удаляет ipset"
check_in_file "$ROLLBACK_SH" 'ipt_drop_all\(\)'                       "helper-функция ipt_drop_all определена"
check_in_file "$ROLLBACK_SH" 'logger -t split-tunnel-rollback'        "logger в journald"

# ── 8. setup-split-tunneling.sh — точки входа ───────────────────────────────
echo ""
echo "── 8. setup-split-tunneling.sh ──"

check_in_file "$SETUP_SCRIPT" 'lib/common\.sh'                  "source lib/common.sh"
check_in_file "$SETUP_SCRIPT" 'load_defaults_from_files'        "load_defaults_from_files"
check_in_file "$SETUP_SCRIPT" '--dry-run'                       "флаг --dry-run"
check_in_file "$SETUP_SCRIPT" '--rollback'                      "флаг --rollback"
check_in_file "$SETUP_SCRIPT" 'apt-get install -y -qq dnsmasq ipset'  "установка dnsmasq+ipset"
check_in_file "$SETUP_SCRIPT" 'upload "\$\{ARTIFACTS_DIR\}/split-tunnel-apply\.sh"' "upload apply.sh (через wrapper)"
check_in_file "$SETUP_SCRIPT" 'upload "\$\{ARTIFACTS_DIR\}/split-tunnel-rollback\.sh"' "upload rollback.sh (через wrapper)"
check_in_file "$SETUP_SCRIPT" 'upload "\$\{ARTIFACTS_DIR\}/split-tunnel-restore\.service"' "upload restore.service (через wrapper)"
check_in_file "$SETUP_SCRIPT" '^upload\(\)|^remote\(\)|^remote_script\(\)'      "локальные wrapper-функции (upload/remote/remote_script)"
check_in_file "$SETUP_SCRIPT" 'dnsmasq\.conf\.bak\.pre-split-tunneling'   "бэкап оригинального dnsmasq.conf"
check_in_file "$SETUP_SCRIPT" 'systemctl enable split-tunnel-restore'     "enable автостарт"
check_in_file "$SETUP_SCRIPT" 'systemctl mask dnsmasq'                    "mask dnsmasq до раскладки конфигов"
check_in_file "$SETUP_SCRIPT" 'systemctl unmask dnsmasq'                  "unmask dnsmasq перед запуском"
check_in_file "$SETUP_SCRIPT" '\[\[ -f /etc/dnsmasq\.conf \]\]'           "явный test -f /etc/dnsmasq.conf"

# ── 8a. restore-vpn-routing.sh — выделенный скрипт восстановления маршрутов ─
echo ""
echo "── 8a. restore-vpn-routing.sh (вынесен из inline-блока) ──"

RESTORE_VPN_SH="${ARTIFACTS_DIR}/restore-vpn-routing.sh"

check_in_file "$RESTORE_VPN_SH" 'set \+e'                              "set +e (best-effort, не падать на ошибках)"
check_in_file "$RESTORE_VPN_SH" 'CLIENT_NET=.*10\.9\.0|CLIENT_NET:-10\.9\.0' "default CLIENT_NET=10.9.0 (параметризация)"
check_in_file "$RESTORE_VPN_SH" 'TUN_NET=.*10\.8\.0|TUN_NET:-10\.8\.0' "default TUN_NET=10.8.0 (параметризация)"
check_in_file "$RESTORE_VPN_SH" 'MARK_HEX=.*0x100|MARK_HEX:-0x100'    "default MARK_HEX=0x100 (параметризация)"
check_in_file "$RESTORE_VPN_SH" 'ROUTE_TABLE=.*100|ROUTE_TABLE:-100'  "default ROUTE_TABLE=100 (параметризация)"
check_in_file "$RESTORE_VPN_SH" 'MAIN_TABLE=.*200|MAIN_TABLE:-200'    "default MAIN_TABLE=200 (параметризация)"
check_in_file "$RESTORE_VPN_SH" 'from "\$CLIENT_CIDR" table "\$MAIN_TABLE"' "восстанавливает ip rule через переменные"
check_in_file "$RESTORE_VPN_SH" 'default via "\$ADGUARD_IP" dev awg0 table "\$MAIN_TABLE"' "восстанавливает route через переменные"
check_in_file "$RESTORE_VPN_SH" 'fwmark "\$MARK_HEX" table "\$ROUTE_TABLE"' "восстанавливает fwmark rule через переменные"
check_in_file "$RESTORE_VPN_SH" 'ipset list ru_subnets'                "проверяет наличие split-tunneling"
check_in_file "$RESTORE_VPN_SH" 'logger -t vpn-routing'                "logger в journald"

# ── 8b. restore.service: ExecStop НЕ должен быть (избегаем surprise rollback) ─
echo ""
echo "── 8b. split-tunnel-restore.service: безопасный systemctl stop ──"

if grep -q '^ExecStop=' "$RESTORE_SVC" 2>/dev/null; then
    fail "ExecStop в restore.service — systemctl stop сделает rollback и сломает DNS у клиентов"
else
    pass "Нет ExecStop в restore.service — systemctl stop безопасен"
fi

# ── 9. Никаких изменений в клиентских конфигах ──────────────────────────────
echo ""
echo "── 9. Гарантия сохранности клиентских конфигов ──"

if ! grep -q "AllowedIPs" "${ARTIFACTS_DIR}"/*.sh "${ARTIFACTS_DIR}"/*.conf 2>/dev/null; then
    pass "AllowedIPs нигде не упоминается (конфиги клиентов не трогаются)"
else
    fail "Найдено упоминание AllowedIPs — это подозрительно для split tunneling"
fi

if ! grep -E "PrivateKey|PresharedKey" "${ARTIFACTS_DIR}"/*.sh "${ARTIFACTS_DIR}"/*.conf 2>/dev/null; then
    pass "Никаких манипуляций с ключами (PrivateKey/PresharedKey не упоминаются)"
else
    fail "Найдено упоминание ключей — split tunneling не должен трогать криптографию"
fi

# ── 10. Гарантия сохранности VPS2 ───────────────────────────────────────────
echo ""
echo "── 10. Гарантия сохранности VPS2 ──"

if ! grep -qE "VPS2_IP|deploy-vps2|10\.8\.0\.2.*ssh|ssh.*VPS2" "${ARTIFACTS_DIR}"/*.sh "$SETUP_SCRIPT" 2>/dev/null; then
    pass "Никаких SSH-команд на VPS2 (только VPS1)"
else
    if grep -qE "ssh.*VPS2|VPS2.*ssh" "${ARTIFACTS_DIR}"/*.sh "$SETUP_SCRIPT" 2>/dev/null; then
        fail "SSH-команды на VPS2 найдены — VPS2 не должен трогаться"
    else
        pass "10.8.0.2 упоминается как upstream DNS, но без SSH-команд на VPS2"
    fi
fi

# ── Итоги ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                          Итоги                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Пройдено: $PASS"
echo "  Провалено: $FAIL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    echo -e "\033[0;31m✗ Тесты провалены\033[0m"
    exit 1
else
    echo -e "\033[0;32m✓ Все статические тесты пройдены\033[0m"
    echo ""
    echo "Для интеграционной проверки на реальном VPS1:"
    echo "  bash scripts/deploy/setup-split-tunneling.sh --dry-run"
    exit 0
fi
