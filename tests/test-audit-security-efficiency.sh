#!/usr/bin/env bash
# =============================================================================
# test-audit-security-efficiency.sh — тесты для audit-security-efficiency.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

echo ""
echo "━━━ Audit Script Tests ━━━"
echo ""

AUDIT_SCRIPT="${PROJECT_DIR}/scripts/tools/audit-security-efficiency.sh"
TMP_REPORT="${PROJECT_DIR}/vpn-output/.tmp-audit-report.txt"

check "Audit script exists" test -f "$AUDIT_SCRIPT"
check "Audit script syntax valid" bash -n "$AUDIT_SCRIPT"

mkdir -p "${PROJECT_DIR}/vpn-output"
if bash "$AUDIT_SCRIPT" --output "$TMP_REPORT" >/dev/null 2>&1; then
    pass "Audit script runs in quick mode"
else
    fail "Audit script runs in quick mode"
fi

check "Audit output file created" test -f "$TMP_REPORT"
check "Audit report has summary section" grep -q "^Summary:" "$TMP_REPORT"
check "Audit report includes severity counters" grep -q "^- critical:" "$TMP_REPORT"
check "Audit report includes total counter" grep -q "^- total:" "$TMP_REPORT"

rm -f "$TMP_REPORT"

check "manage.sh has audit command" grep -q "audit" "${PROJECT_DIR}/manage.sh"

echo ""
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
