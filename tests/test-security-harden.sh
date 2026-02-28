#!/bin/bash
# =============================================================================
# test-security-harden.sh — тесты для security-harden.sh и security-изменений
#
# Проверяет:
#   1. security-harden.sh существует и валиден (bash -n)
#   2. Все deploy-скрипты используют StrictHostKeyChecking=accept-new
#   3. Нет захардкоженного пароля admin123 как дефолта
#   4. Нет fallback bcrypt-хэша admin123
#   5. AdGuard Home bind не на 0.0.0.0
#   6. security-harden.sh содержит все компоненты hardening
#   7. lib/common.sh использует accept-new
#   8. deploy-proxy.sh использует accept-new
#   9. deploy.sh требует --adguard-pass (нет дефолта)
#  10. security-harden.sh принимает параметры --role, --vpn-port и т.д.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo "  ✗ $1"; }

check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

check_not() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$desc"
    else
        pass "$desc"
    fi
}

echo ""
echo "━━━ Security Hardening Tests ━━━"
echo ""

# ── 1. security-harden.sh exists and is valid ───────────────────────────────
echo "1. security-harden.sh:"
HARDEN="$PROJECT_DIR/scripts/deploy/security-harden.sh"

check "File exists" test -f "$HARDEN"
check "Bash syntax valid" bash -n "$HARDEN"
check "Contains fail2ban setup" grep -q "fail2ban" "$HARDEN"
check "Contains unattended-upgrades" grep -q "unattended-upgrades" "$HARDEN"
check "Contains SSH hardening" grep -q "PermitRootLogin" "$HARDEN"
check "Contains iptables DROP policy" grep -q 'iptables -P INPUT DROP' "$HARDEN"
check "Contains rkhunter" grep -q "rkhunter" "$HARDEN"
check "Contains CPU watchdog" grep -q "cpu-watchdog" "$HARDEN"
check "Contains kernel hardening sysctl" grep -q "tcp_syncookies" "$HARDEN"
check "Contains log rotation" grep -q "logrotate" "$HARDEN"
check "Accepts --role parameter" grep -q "\-\-role" "$HARDEN"
check "Accepts --vpn-port parameter" grep -q "\-\-vpn-port" "$HARDEN"
check "Accepts --adguard-bind parameter" grep -q "\-\-adguard-bind" "$HARDEN"
check "Contains PasswordAuthentication no" grep -q "PasswordAuthentication no" "$HARDEN"
check "Contains MaxAuthTries" grep -q "MaxAuthTries" "$HARDEN"
check "Contains persistent iptables save" grep -q "iptables-save" "$HARDEN"
check "Contains SSH rate limiting" grep -q "recent.*SSH" "$HARDEN"
check "Contains DROP logging" grep -q "IPT_DROP" "$HARDEN"

echo ""

# ── 2. SSH StrictHostKeyChecking=accept-new ──────────────────────────────────
echo "2. SSH host key verification (accept-new instead of no):"

for script in deploy.sh deploy-vps1.sh deploy-vps2.sh deploy-proxy.sh; do
    FILE="$PROJECT_DIR/scripts/deploy/$script"
    if [[ -f "$FILE" ]]; then
        check "$script uses accept-new" grep -q "StrictHostKeyChecking=accept-new" "$FILE"
        check_not "$script has no StrictHostKeyChecking=no" grep -q "StrictHostKeyChecking=no" "$FILE"
    else
        fail "$script not found"
    fi
done

FILE="$PROJECT_DIR/lib/common.sh"
if [[ -f "$FILE" ]]; then
    check "lib/common.sh uses accept-new" grep -q "StrictHostKeyChecking=accept-new" "$FILE"
    check_not "lib/common.sh has no StrictHostKeyChecking=no" grep -q "StrictHostKeyChecking=no" "$FILE"
fi

# Stage 3: operational scripts should also use accept-new and keep known_hosts.
for file in \
    "$PROJECT_DIR/scripts/monitor/monitor-web.sh" \
    "$PROJECT_DIR/scripts/monitor/monitor-realtime.sh" \
    "$PROJECT_DIR/scripts/tools/diagnose.sh" \
    "$PROJECT_DIR/scripts/tools/add_phone_peer.sh" \
    "$PROJECT_DIR/scripts/tools/repair-vps1.sh" \
    "$PROJECT_DIR/scripts/tools/generate-all-configs.sh" \
    "$PROJECT_DIR/scripts/windows/repair-local-configs.ps1"; do
    if [[ -f "$file" ]]; then
        fname="$(basename "$file")"
        check "$fname uses accept-new" grep -q "StrictHostKeyChecking=accept-new" "$file"
        check_not "$fname has no StrictHostKeyChecking=no" grep -q "StrictHostKeyChecking=no" "$file"
        check_not "$fname has no UserKnownHostsFile=/dev/null" grep -q "UserKnownHostsFile=/dev/null" "$file"
    else
        fail "$(basename "$file") not found"
    fi
done

echo ""

# ── 3. No hardcoded admin123 default ─────────────────────────────────────────
echo "3. No hardcoded weak passwords:"

for script in deploy.sh deploy-vps2.sh; do
    FILE="$PROJECT_DIR/scripts/deploy/$script"
    if [[ -f "$FILE" ]]; then
        check_not "$script has no ADGUARD_PASS=\"admin123\" default" grep -q 'ADGUARD_PASS="admin123"' "$FILE"
    fi
done

echo ""

# ── 4. No fallback bcrypt hash ───────────────────────────────────────────────
echo "4. No fallback bcrypt hash for admin123:"

for script in deploy.sh deploy-vps2.sh; do
    FILE="$PROJECT_DIR/scripts/deploy/$script"
    if [[ -f "$FILE" ]]; then
        check_not "$script has no hardcoded bcrypt hash" grep -q 'cs5qBaGHMHBqXMnMIzNQxuGsGfSr5pFGELMXe2WpJeJGPBmvJIXXi' "$FILE"
    fi
done

echo ""

# ── 5. AdGuard Home not bound to 0.0.0.0 ────────────────────────────────────
echo "5. AdGuard Home bind address:"

for script in deploy.sh deploy-vps2.sh; do
    FILE="$PROJECT_DIR/scripts/deploy/$script"
    if [[ -f "$FILE" ]]; then
        check_not "$script AdGuard HTTP not on 0.0.0.0:3000" grep -q "address: 0.0.0.0:3000" "$FILE"
        check_not "$script AdGuard DNS not on 0.0.0.0" grep -q "    - 0.0.0.0" "$FILE"
    fi
done

echo ""

# ── 6. Deploy scripts integrate security-harden.sh ──────────────────────────
echo "6. Security hardening integration in deploy scripts:"

for script in deploy.sh deploy-vps1.sh deploy-vps2.sh; do
    FILE="$PROJECT_DIR/scripts/deploy/$script"
    if [[ -f "$FILE" ]]; then
        check "$script references security-harden.sh" grep -q "security-harden" "$FILE"
        check "$script has SECURITY_HARDEN_SCRIPT variable" grep -q "SECURITY_HARDEN_SCRIPT" "$FILE"
    fi
done

echo ""

# ── 7. Deploy scripts require strong adguard password ────────────────────────
echo "7. Password validation:"

for script in deploy.sh deploy-vps2.sh; do
    FILE="$PROJECT_DIR/scripts/deploy/$script"
    if [[ -f "$FILE" ]]; then
        check "$script validates adguard password is not empty" grep -q 'ADGUARD_PASS.*err' "$FILE"
        check "$script rejects admin123" grep -q 'admin123.*err\|admin123.*слабый' "$FILE"
    fi
done

echo ""

# ── 8. All deploy scripts have valid bash syntax ────────────────────────────
echo "8. Bash syntax validation:"

for script in deploy.sh deploy-vps1.sh deploy-vps2.sh deploy-proxy.sh security-update.sh security-harden.sh; do
    FILE="$PROJECT_DIR/scripts/deploy/$script"
    if [[ -f "$FILE" ]]; then
        check "$script syntax OK" bash -n "$FILE"
    fi
done

check "lib/common.sh syntax OK" bash -n "$PROJECT_DIR/lib/common.sh"

echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $FAIL -gt 0 ]]; then
    echo "  SOME TESTS FAILED"
    exit 1
else
    echo "  ALL TESTS PASSED"
    exit 0
fi
