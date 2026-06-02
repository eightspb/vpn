#!/usr/bin/env bash
# Static tests for maintenance deploy key/config preservation.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0

ok() { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }

DEPLOY="scripts/deploy/deploy.sh"
DEPLOY_VPS2="scripts/deploy/deploy-vps2.sh"

echo ""
echo "=== deploy.sh key/config preservation tests ==="

if bash -n "$DEPLOY"; then
    ok "deploy.sh bash syntax valid"
else
    fail "deploy.sh bash syntax invalid"
fi

for token in \
    'read_interface_private_key()' \
    'read_first_peer_public_key()' \
    'ensure_key_pair()' \
    '[preserve] ${name}_priv' \
    'from existing config' \
    'VPS2_EXISTING_TUNNEL_PUB=' \
    'awg/wg is unavailable to derive its public key' \
    'VPS2 peer from existing VPS2 awg0.conf; vps2_tunnel_priv unavailable on VPS1' \
    'VPS2_TUNNEL_PRIV_OUT=' \
    'VPS2 peer from existing awg0.conf; vps2_tunnel_priv unavailable'; do
    if grep -Fq "$token" "$DEPLOY"; then
        ok "key preservation includes $token"
    else
        fail "key preservation missing $token"
    fi
done

for token in \
    'sub(/^[^=]*=/, "", $0)' \
    'sub(/^[^=]*=/, "", line)'; do
    if grep -Fq "$token" "$DEPLOY"; then
        ok "base64 key parsing preserves equals padding via $token"
    else
        fail "base64 key parsing may strip equals padding: missing $token"
    fi
done

if ! grep -Fq 'for name in vps1_tunnel vps2_tunnel vps1_client client_spb' "$DEPLOY"; then
    ok "old unconditional key rotation loop is absent"
else
    fail "old unconditional key rotation loop still exists"
fi

for token in \
    '/etc/amnezia/amneziawg/awg0.conf already exists; not rewriting keys/peers' \
    '/etc/amnezia/amneziawg/awg1.conf already exists; not rewriting keys/peers' \
    'Missing VPS2_TUNNEL_PRIV; refusing to create new VPS2 awg0.conf with an empty key' \
    'if [[ -f /etc/amnezia/amneziawg/awg0.conf ]]' \
    'if [[ -f /etc/amnezia/amneziawg/awg1.conf ]]'; do
    if grep -Fq "$token" "$DEPLOY"; then
        ok "server config preservation includes $token"
    else
        fail "server config preservation missing $token"
    fi
done

for token in \
    'if [[ -f "$CLIENT_CONF" ]]' \
    'Клиентский конфиг уже существует и сохранён без изменений' \
    'if [[ -f "${OUTPUT_DIR}/keys.txt" ]]' \
    'Файл ключей уже существует и сохранён без изменений'; do
    if grep -Fq "$token" "$DEPLOY"; then
        ok "local output preservation includes $token"
    else
        fail "local output preservation missing $token"
    fi
done

for token in \
    'ADGUARD_CONFIG_EXISTED=0' \
    '/opt/AdGuardHome/AdGuardHome.yaml already exists; not rewriting AdGuard config' \
    '/etc/systemd/resolved.conf.d/adguard.conf unchanged; not restarting systemd-resolved' \
    'AdGuard Home bind already restricted to ${ADGUARD_BIND}; not restarting'; do
    if grep -Fq "$token" "$DEPLOY" scripts/deploy/security-harden.sh; then
        ok "AdGuard maintenance deploy preservation includes $token"
    else
        fail "AdGuard maintenance deploy preservation missing $token"
    fi
done

for file in "$DEPLOY" "$DEPLOY_VPS2"; do
    if ! grep -Fq 'AGH_PASS_HASH=$(python3' "$file" && \
       ! grep -Fq 'pip3 install bcrypt' "$file" && \
       grep -Fq 'ADGUARD_PASS_SHELL="$(printf' "$file" && \
       grep -Fq 'generate_adguard_hash()' "$file" && \
       grep -Fq 'apache2-utils' "$file" && \
       grep -Fq "password: '\\\${AGH_PASS_HASH}'" "$file"; then
        ok "$(basename "$file") generates AdGuard bcrypt hash remotely"
    else
        fail "$(basename "$file") may still require local python3-bcrypt"
    fi
done

if grep -Fq 'существующие WG-ключи' README.md && \
   grep -Fq 'автоматически создаёт rollback snapshot' README.md && \
   grep -Fq 'существующий `/opt/AdGuardHome/AdGuardHome.yaml`' README.md && \
   ! grep -Fq '| `bash manage.sh deploy` (полный деплой) | Полная пересоздача WG-ключей' README.md; then
    ok "README documents maintenance deploy semantics"
else
    fail "README still documents full deploy as key rotation"
fi

echo ""
echo "=============================="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "=============================="

[[ "$FAIL" -eq 0 ]]
