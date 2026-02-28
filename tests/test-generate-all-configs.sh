#!/usr/bin/env bash
# =============================================================================
# test-generate-all-configs.sh — Тесты для generate-all-configs.sh
#
# Проверяет что сгенерированные конфиги корректны:
#   1. Все 4 файла существуют
#   2. Формат конфигов валиден (секции [Interface] и [Peer])
#   3. Ключи и параметры присутствуют
#   4. Split-конфиги содержат больше AllowedIPs чем full
#   5. Junk-параметры присутствуют во всех конфигах
#   6. Endpoint указывает на правильный IP
#   7. keys.env и keys.txt обновлены
#
# Использование:
#   bash tests/test-generate-all-configs.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
PASS=0; FAIL=0

pass() { echo -e "  ${GREEN}✓${NC} $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${NC} $*"; FAIL=$((FAIL+1)); }

assert_file_exists() {
    [[ -f "$1" ]] && pass "$2: файл существует" || fail "$2: файл НЕ найден ($1)"
}

assert_contains() {
    local file="$1" pattern="$2" desc="$3"
    grep -q "$pattern" "$file" 2>/dev/null && pass "$desc" || fail "$desc (pattern: $pattern)"
}

assert_not_empty() {
    local file="$1" desc="$2"
    [[ -s "$file" ]] && pass "$desc: не пустой" || fail "$desc: ПУСТОЙ"
}

OUTPUT="vpn-output"

echo ""
echo "=== Тесты для generate-all-configs.sh ==="
echo ""

# --- Test 1: Files exist ---
echo "--- 1. Проверка наличия файлов ---"
assert_file_exists "$OUTPUT/client.conf" "client.conf"
assert_file_exists "$OUTPUT/phone.conf" "phone.conf"
assert_file_exists "$OUTPUT/client-split.conf" "client-split.conf"
assert_file_exists "$OUTPUT/phone-split.conf" "phone-split.conf"
assert_file_exists "$OUTPUT/keys.env" "keys.env"
assert_file_exists "$OUTPUT/keys.txt" "keys.txt"

# --- Test 2: Config format ---
echo ""
echo "--- 2. Формат конфигов ---"
for conf in client.conf phone.conf client-split.conf phone-split.conf; do
    f="$OUTPUT/$conf"
    [[ ! -f "$f" ]] && continue
    assert_contains "$f" "\\[Interface\\]" "$conf: секция [Interface]"
    assert_contains "$f" "\\[Peer\\]" "$conf: секция [Peer]"
    assert_contains "$f" "PrivateKey" "$conf: PrivateKey"
    assert_contains "$f" "Address" "$conf: Address"
    assert_contains "$f" "DNS" "$conf: DNS"
    assert_contains "$f" "MTU" "$conf: MTU"
    assert_contains "$f" "PublicKey" "$conf: PublicKey"
    assert_contains "$f" "Endpoint" "$conf: Endpoint"
    assert_contains "$f" "AllowedIPs" "$conf: AllowedIPs"
    assert_contains "$f" "PersistentKeepalive" "$conf: PersistentKeepalive"
done

# --- Test 3: Junk parameters ---
echo ""
echo "--- 3. Junk-параметры ---"
for conf in client.conf phone.conf client-split.conf phone-split.conf; do
    f="$OUTPUT/$conf"
    [[ ! -f "$f" ]] && continue
    assert_contains "$f" "^Jc" "$conf: Jc"
    assert_contains "$f" "^H1" "$conf: H1"
    assert_contains "$f" "^H4" "$conf: H4"
    assert_contains "$f" "^S1" "$conf: S1"
done

# --- Test 4: Correct IPs ---
echo ""
echo "--- 4. IP-адреса ---"
if [[ -f "$OUTPUT/client.conf" ]]; then
    assert_contains "$OUTPUT/client.conf" "10.9.0.2" "client.conf: IP 10.9.0.2"
fi
if [[ -f "$OUTPUT/phone.conf" ]]; then
    assert_contains "$OUTPUT/phone.conf" "10.9.0.3" "phone.conf: IP 10.9.0.3"
fi

# --- Test 5: Endpoint matches .env ---
echo ""
echo "--- 5. Endpoint ---"
read_kv() {
    awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"",$0); gsub(/\r/,""); gsub(/^[ \t"'"'"']+|[ \t"'"'"']+$/,""); print; exit}' "$1" 2>/dev/null
}
VPS1_IP="$(read_kv .env VPS1_IP)"
for conf in client.conf phone.conf client-split.conf phone-split.conf; do
    f="$OUTPUT/$conf"
    [[ ! -f "$f" ]] && continue
    assert_contains "$f" "${VPS1_IP}:51820" "$conf: Endpoint=${VPS1_IP}:51820"
done

# --- Test 6: Split configs have more AllowedIPs ---
echo ""
echo "--- 6. Split vs Full AllowedIPs ---"
if [[ -f "$OUTPUT/client.conf" && -f "$OUTPUT/client-split.conf" ]]; then
    FULL_LEN=$(grep "AllowedIPs" "$OUTPUT/client.conf" | wc -c)
    SPLIT_LEN=$(grep "AllowedIPs" "$OUTPUT/client-split.conf" | wc -c)
    if [[ $SPLIT_LEN -gt $FULL_LEN ]]; then
        pass "client-split AllowedIPs длиннее full ($SPLIT_LEN > $FULL_LEN chars)"
    else
        fail "client-split AllowedIPs НЕ длиннее full"
    fi
fi

# --- Test 7: Different private keys ---
echo ""
echo "--- 7. Разные ключи для компьютера и телефона ---"
if [[ -f "$OUTPUT/client.conf" && -f "$OUTPUT/phone.conf" ]]; then
    CLIENT_KEY=$(grep "PrivateKey" "$OUTPUT/client.conf" | awk '{print $NF}')
    PHONE_KEY=$(grep "PrivateKey" "$OUTPUT/phone.conf" | awk '{print $NF}')
    if [[ "$CLIENT_KEY" != "$PHONE_KEY" && -n "$CLIENT_KEY" && -n "$PHONE_KEY" ]]; then
        pass "Ключи компьютера и телефона различаются"
    else
        fail "Ключи компьютера и телефона ОДИНАКОВЫЕ или пустые"
    fi
fi

# --- Test 8: Same server pub key in all configs ---
echo ""
echo "--- 8. Одинаковый серверный ключ ---"
PUBS=()
for conf in client.conf phone.conf client-split.conf phone-split.conf; do
    f="$OUTPUT/$conf"
    [[ ! -f "$f" ]] && continue
    PUB=$(awk '/^\[Peer\]/,0' "$f" | grep "PublicKey" | awk '{print $NF}')
    PUBS+=("$PUB")
done
if [[ ${#PUBS[@]} -ge 2 ]]; then
    ALL_SAME=true
    for p in "${PUBS[@]}"; do
        [[ "$p" != "${PUBS[0]}" ]] && ALL_SAME=false
    done
    if $ALL_SAME && [[ -n "${PUBS[0]}" ]]; then
        pass "Серверный PublicKey одинаковый во всех конфигах: ${PUBS[0]}"
    else
        fail "Серверный PublicKey различается между конфигами"
    fi
fi

# --- Test 9: MTU values ---
echo ""
echo "--- 9. MTU ---"
if [[ -f "$OUTPUT/client.conf" ]]; then
    assert_contains "$OUTPUT/client.conf" "MTU.*=.*1360" "client.conf: MTU=1360"
fi
if [[ -f "$OUTPUT/phone.conf" ]]; then
    assert_contains "$OUTPUT/phone.conf" "MTU.*=.*1280" "phone.conf: MTU=1280"
fi

# --- Test 10: keys.env has phone key ---
echo ""
echo "--- 10. keys.env содержит ключ телефона ---"
if [[ -f "$OUTPUT/keys.env" ]]; then
    assert_contains "$OUTPUT/keys.env" "PHONE_PRIV=" "keys.env: PHONE_PRIV"
    assert_contains "$OUTPUT/keys.env" "PHONE_PUB=" "keys.env: PHONE_PUB"
    assert_contains "$OUTPUT/keys.env" "CLIENT_PRIV=" "keys.env: CLIENT_PRIV"
fi

# --- Summary ---
echo ""
echo "==============================="
TOTAL=$((PASS+FAIL))
echo -e "  Всего: $TOTAL  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"
echo "==============================="
echo ""

exit $FAIL
