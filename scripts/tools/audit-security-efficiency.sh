#!/usr/bin/env bash
# =============================================================================
# audit-security-efficiency.sh — статический аудит безопасности и эффективности
#
# Цель:
#   - Быстро проверить репозиторий на известные risky-patterns
#   - Подсветить узкие места по безопасности и операционной эффективности
#   - (Опционально) выполнить read-only проверки состояния серверов по SSH
#
# Использование:
#   bash scripts/tools/audit-security-efficiency.sh
#   bash scripts/tools/audit-security-efficiency.sh --strict
#   bash scripts/tools/audit-security-efficiency.sh --with-servers
#   bash scripts/tools/audit-security-efficiency.sh --output ./vpn-output/audit-report.txt
#
# Параметры:
#   --strict        вернуть exit 1, если найдены critical/high
#   --with-servers  добавить read-only server checks через SSH
#   --output FILE   сохранить отчёт в файл
#   --help          показать справку
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

STRICT=false
WITH_SERVERS=false
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --strict) STRICT=true; shift ;;
        --with-servers) WITH_SERVERS=true; shift ;;
        --output) OUTPUT_FILE="${2:-}"; shift 2 ;;
        --help|-h)
            sed -n '2,24p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) err "Неизвестный параметр: $1" ;;
    esac
done

check_deps

PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

REPORT=""
CRITICAL=0
HIGH=0
MEDIUM=0
LOW=0
TOTAL=0

append() { REPORT+="$*"$'\n'; }

add_finding() {
    local severity="$1" title="$2" evidence="$3" fix="$4"
    TOTAL=$((TOTAL + 1))
    case "$severity" in
        critical) CRITICAL=$((CRITICAL + 1)) ;;
        high) HIGH=$((HIGH + 1)) ;;
        medium) MEDIUM=$((MEDIUM + 1)) ;;
        low) LOW=$((LOW + 1)) ;;
    esac
    append "- [${severity^^}] ${title}"
    append "  - Evidence: ${evidence}"
    append "  - Fix: ${fix}"
}

grep_hits() {
    local pattern="$1" target="$2"
    grep -RInE -- "$pattern" "$target" 2>/dev/null || true
}

append "Security/Efficiency Audit Report"
append "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
append "Root: ${PROJECT_ROOT}"
append ""

# -----------------------------------------------------------------------------
# Static checks
# -----------------------------------------------------------------------------

admin_server="${PROJECT_ROOT}/scripts/admin/admin-server.py"
admin_html="${PROJECT_ROOT}/scripts/admin/admin.html"

if grep -q 'dev-admin-secret-key-do-not-use-in-production' "$admin_server"; then
    add_finding \
        "critical" \
        "Default JWT secret fallback in admin server" \
        "scripts/admin/admin-server.py contains hardcoded fallback secret" \
        "Require ADMIN_SECRET_KEY in prod and fail fast if missing."
fi

if grep -q 'CORS(app, resources={r"/api/\*": {"origins": "\*"}})' "$admin_server"; then
    add_finding \
        "high" \
        "Wildcard CORS on admin API" \
        "scripts/admin/admin-server.py allows origins='*' for /api/*" \
        "Whitelist explicit origins via env (dev/prod split)."
fi

if grep -q 'AutoAddPolicy' "$admin_server"; then
    add_finding \
        "high" \
        "Paramiko auto-accept host keys" \
        "scripts/admin/admin-server.py uses paramiko.AutoAddPolicy()" \
        "Use RejectPolicy/known_hosts and fail on host key mismatch."
fi

if grep -q "localStorage.getItem('admin_token')" "$admin_html"; then
    add_finding \
        "high" \
        "Admin token persisted in localStorage" \
        "scripts/admin/admin.html reads admin_token from localStorage" \
        "Move to HttpOnly cookie-only session; remove token persistence in JS."
fi

eval_hits="$(grep_hits 'eval "\$\(ssh_cmd' "${PROJECT_ROOT}/scripts/deploy")"
if [[ -n "$eval_hits" ]]; then
    add_finding \
        "high" \
        "eval usage in deploy SSH wrappers" \
        "$(echo "$eval_hits" | head -3 | tr '\n' '; ')" \
        "Refactor to array-based ssh/scp invocation without eval."
fi

strict_no_hits="$(grep_hits 'StrictHostKeyChecking=no' "${PROJECT_ROOT}/scripts" | grep -v '/tests/' || true)"
if [[ -n "$strict_no_hits" ]]; then
    add_finding \
        "high" \
        "Insecure SSH host key checking in scripts" \
        "$(echo "$strict_no_hits" | head -4 | tr '\n' '; ')" \
        "Replace with StrictHostKeyChecking=accept-new and known_hosts strategy."
fi

localhost_bypass_count="$(grep -c '@auth_required_or_local' "$admin_server" || true)"
if [[ "${localhost_bypass_count}" -gt 2 ]]; then
    add_finding \
        "critical" \
        "Auth bypass decorator used broadly in admin API" \
        "scripts/admin/admin-server.py: @auth_required_or_local count=${localhost_bypass_count}" \
        "Restrict bypass to read-only monitoring endpoints only."
fi

if grep -q 'upstreamURL := fmt.Sprintf("https://%s%s", host, r.RequestURI)' "${PROJECT_ROOT}/youtube-proxy/internal/proxy/proxy.go"; then
    add_finding \
        "medium" \
        "Proxy upstream host depends on request Host header" \
        "youtube-proxy/internal/proxy/proxy.go builds upstream URL from incoming host" \
        "Enforce strict allowlist or always use configured upstream_host."
fi

if grep -q '^INTERVAL=2' "${PROJECT_ROOT}/scripts/monitor/monitor-web.sh"; then
    add_finding \
        "medium" \
        "Aggressive monitor polling interval" \
        "scripts/monitor/monitor-web.sh default INTERVAL=2" \
        "Use 5-10s default and separate fast vs heavy probes."
fi

# -----------------------------------------------------------------------------
# Optional server checks (read-only)
# -----------------------------------------------------------------------------

if [[ "$WITH_SERVERS" == "true" ]]; then
    append ""
    append "Server Checks (read-only):"
    load_defaults_from_files

    VPS1_USER="${VPS1_USER:-root}"
    VPS2_USER="${VPS2_USER:-root}"
    VPS1_KEY="$(prepare_key_for_ssh "$(expand_tilde "${VPS1_KEY:-}")")"
    VPS2_KEY="$(prepare_key_for_ssh "$(expand_tilde "${VPS2_KEY:-}")")"
    trap cleanup_temp_keys EXIT

    if [[ -n "${VPS1_IP:-}" && ( -n "${VPS1_KEY:-}" || -n "${VPS1_PASS:-}" ) ]]; then
        out1="$(ssh_exec "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "${VPS1_PASS:-}" "uname -sr && systemctl is-active awg-quick@awg0 || true && systemctl is-active awg-quick@awg1 || true" 20 2>/dev/null || true)"
        append "- VPS1: $(echo "$out1" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
    else
        append "- VPS1: skipped (missing VPS1_IP/key/pass in .env)"
    fi

    if [[ -n "${VPS2_IP:-}" && ( -n "${VPS2_KEY:-}" || -n "${VPS2_PASS:-}" ) ]]; then
        out2="$(ssh_exec "$VPS2_IP" "$VPS2_USER" "$VPS2_KEY" "${VPS2_PASS:-}" "uname -sr && systemctl is-active awg-quick@awg0 || true && systemctl is-active youtube-proxy || true" 20 2>/dev/null || true)"
        append "- VPS2: $(echo "$out2" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
    else
        append "- VPS2: skipped (missing VPS2_IP/key/pass in .env)"
    fi
fi

append ""
append "Summary:"
append "- total: ${TOTAL}"
append "- critical: ${CRITICAL}"
append "- high: ${HIGH}"
append "- medium: ${MEDIUM}"
append "- low: ${LOW}"

echo "${REPORT}"

if [[ -n "$OUTPUT_FILE" ]]; then
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    printf "%s" "$REPORT" > "$OUTPUT_FILE"
    ok "Отчёт сохранён в ${OUTPUT_FILE}"
fi

if [[ "$STRICT" == "true" && ( "$CRITICAL" -gt 0 || "$HIGH" -gt 0 ) ]]; then
    err "Strict mode: найдены критичные/высокие риски (critical=${CRITICAL}, high=${HIGH})"
fi

ok "Аудит завершён (critical=${CRITICAL}, high=${HIGH}, medium=${MEDIUM}, low=${LOW})"
