#!/usr/bin/env bash
# =============================================================================
# split-tunnel-update-ru-domains.sh - generate dnsmasq ipset rules for RU sites
#
# Runs on VPS1. It expands v2fly/domain-list-community category-ru recursively
# and writes /etc/dnsmasq.d/vpn-ru-domains.conf.
#
# The generated rules complement the static TLD fallback in vpn.conf. DNS answers
# for these domains are placed into ru_subnets, then split-tunnel-apply.sh routes
# the resulting connections through VPS1's main interface.
# =============================================================================

set -euo pipefail

BASE_URL="${RU_DOMAINS_BASE_URL:-https://raw.githubusercontent.com/v2fly/domain-list-community/master/data}"
ROOT_LISTS="${RU_DOMAIN_ROOT_LISTS:-category-ru}"
OUTPUT="${RU_DOMAINS_OUTPUT:-/etc/dnsmasq.d/vpn-ru-domains.conf}"
IPSET_NAME="${IPSET_NAME:-ru_subnets}"
CACHE_DIR="${RU_DOMAINS_CACHE_DIR:-/var/lib/split-tunneling/domain-list-community}"
SEED_FILE="${RU_DOMAINS_SEED_FILE:-/usr/local/share/split-tunneling/ru-domain-seed.txt}"
RELOAD_DNSMASQ="${RELOAD_DNSMASQ:-1}"
DRY_RUN=0

usage() {
    cat <<EOF
Usage: sudo bash $0 [options]

Options:
  --output FILE       generated dnsmasq config path (default: $OUTPUT)
  --ipset NAME        target ipset name (default: $IPSET_NAME)
  --root LISTS        comma/space-separated root DLC lists (default: $ROOT_LISTS)
  --base-url URL      domain-list-community raw data base URL
  --seed-file FILE    local fallback domain list
  --no-reload         do not restart/reload dnsmasq after writing
  --dry-run           generate and validate without installing
  --help              show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT="$2"; shift 2 ;;
        --ipset) IPSET_NAME="$2"; shift 2 ;;
        --root) ROOT_LISTS="$2"; shift 2 ;;
        --base-url) BASE_URL="$2"; shift 2 ;;
        --seed-file) SEED_FILE="$2"; shift 2 ;;
        --no-reload) RELOAD_DNSMASQ=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

log() { echo "[ru-domains] $*" >&2; logger -t split-tunnel-ru-domains -- "$*" 2>/dev/null || true; }
warn() { echo "[ru-domains][warn] $*" >&2; logger -t split-tunnel-ru-domains -p user.warn -- "$*" 2>/dev/null || true; }
fail() { echo "[ru-domains][fatal] $*" >&2; logger -t split-tunnel-ru-domains -p user.err -- "$*" 2>/dev/null || true; exit 1; }

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || fail "missing command: $c"
    done
}

valid_list_name() {
    [[ "$1" =~ ^[A-Za-z0-9._+-]+$ ]]
}

normalize_domain() {
    local domain="$1"
    domain="${domain%%@*}"
    domain="${domain#full:}"
    domain="${domain#domain:}"
    domain="${domain#.}"
    if [[ "$domain" == \*.* ]]; then
        domain="${domain#\*.}"
    fi
    domain="${domain%/}"
    printf '%s' "${domain,,}"
}

valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-z0-9]([a-z0-9_-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9_-]*[a-z0-9])?)*$ ]]
}

dnsmasq_match_name() {
    local domain="$1"
    if [[ "$domain" == *.* ]]; then
        printf '%s' "$domain"
    else
        printf '.%s' "$domain"
    fi
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/lists"

require_cmd awk sort sed
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    fail "missing command: curl or wget"
fi

declare -A SEEN_LISTS=()
declare -A DOMAINS=()
FETCH_ERRORS=0
REMOTE_LISTS=0
SKIPPED_RULES=0

fetch_url() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 "$url" -o "$dest"
    else
        wget -q -T 30 -O "$dest" "$url"
    fi
}

fetch_list() {
    local name="$1" dest="$2" cached="${CACHE_DIR}/${name}"
    local url="${BASE_URL%/}/${name}"

    if fetch_url "$url" "$dest"; then
        REMOTE_LISTS=$((REMOTE_LISTS + 1))
        if mkdir -p "$CACHE_DIR" 2>/dev/null; then
            cp "$dest" "$cached" 2>/dev/null || true
        fi
        return 0
    fi

    if [[ -f "$cached" ]]; then
        cp "$cached" "$dest"
        warn "using cached DLC list: $name"
        return 0
    fi

    warn "cannot fetch DLC list and no cache exists: $name"
    FETCH_ERRORS=$((FETCH_ERRORS + 1))
    return 1
}

add_domain() {
    local raw="$1" domain
    domain="$(normalize_domain "$raw")"
    [[ -n "$domain" ]] || return 0

    case "$domain" in
        include:*|regexp:*|keyword:*|ext:*|attrs:*|@*) return 0 ;;
    esac

    if valid_domain "$domain"; then
        DOMAINS["$domain"]=1
    else
        SKIPPED_RULES=$((SKIPPED_RULES + 1))
    fi
}

parse_tokens_file() {
    local file="$1"
    local line token

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        for token in $line; do
            token="${token%%@*}"
            [[ -n "$token" && "$token" != @* ]] || continue
            case "$token" in
                include:*)
                    parse_list "${token#include:}"
                    ;;
                regexp:*|keyword:*|ext:*|attrs:*)
                    SKIPPED_RULES=$((SKIPPED_RULES + 1))
                    ;;
                *)
                    add_domain "$token"
                    ;;
            esac
        done
    done < "$file"
}

parse_list() {
    local name="$1" dest
    name="${name%%@*}"
    [[ -n "$name" ]] || return 0
    valid_list_name "$name" || { warn "skip invalid DLC list name: $name"; return 0; }
    [[ -z "${SEEN_LISTS[$name]:-}" ]] || return 0
    SEEN_LISTS["$name"]=1

    dest="$WORK_DIR/lists/$name"
    if fetch_list "$name" "$dest"; then
        parse_tokens_file "$dest"
    fi
}

load_seed() {
    if [[ -f "$SEED_FILE" ]]; then
        log "loading local seed: $SEED_FILE"
        parse_tokens_file "$SEED_FILE"
    else
        warn "local seed file is missing: $SEED_FILE"
    fi
}

write_output() {
    local tmp="$WORK_DIR/vpn-ru-domains.conf"
    local domain count

    count="${#DOMAINS[@]}"
    [[ "$count" -gt 0 ]] || fail "no RU domains collected"

    {
        echo "# Managed by split-tunnel-update-ru-domains.sh - DO NOT EDIT"
        echo "# Source: v2fly/domain-list-community roots: ${ROOT_LISTS}"
        echo "# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "# Entries: ${count}; remote_lists: ${REMOTE_LISTS}; fetch_errors: ${FETCH_ERRORS}; skipped_rules: ${SKIPPED_RULES}"
        echo
        for domain in "${!DOMAINS[@]}"; do
            printf '%s\n' "$domain"
        done | sort -u | while IFS= read -r domain; do
            printf 'ipset=/%s/%s\n' "$(dnsmasq_match_name "$domain")" "$IPSET_NAME"
        done
    } > "$tmp"

    if command -v dnsmasq >/dev/null 2>&1; then
        dnsmasq --test --conf-file="$tmp" >/dev/null
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        cat "$tmp"
        return 0
    fi

    [[ $EUID -eq 0 ]] || fail "run as root to install $OUTPUT"
    install -d -m 755 "$(dirname "$OUTPUT")"
    install -m 644 "$tmp" "$OUTPUT"
    log "installed $OUTPUT with $count domains"
}

for root in $(printf '%s\n' "$ROOT_LISTS" | tr ',' ' '); do
    parse_list "$root"
done
load_seed
write_output

if [[ "$DRY_RUN" != "1" && "$RELOAD_DNSMASQ" == "1" ]]; then
    if systemctl is-active --quiet dnsmasq 2>/dev/null; then
        systemctl restart dnsmasq
        log "dnsmasq restarted"
    else
        log "dnsmasq is not active; generated rules will load on next start"
    fi
fi

if [[ "$FETCH_ERRORS" -gt 0 ]]; then
    warn "completed with $FETCH_ERRORS fetch errors; generated rules include cache/seed data"
fi
