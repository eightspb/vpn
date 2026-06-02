#!/usr/bin/env bash
# Static tests for deploy-snapshot-rollback.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0

ok() { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }

SCRIPT="scripts/deploy/deploy-snapshot-rollback.sh"

echo ""
echo "=== deploy-snapshot-rollback.sh tests ==="

if [[ -f "$SCRIPT" ]]; then
    ok "$SCRIPT exists"
else
    fail "$SCRIPT missing"
fi

if [[ -x "$SCRIPT" ]]; then
    ok "$SCRIPT executable"
else
    fail "$SCRIPT not executable"
fi

if bash -n "$SCRIPT"; then
    ok "$SCRIPT bash syntax valid"
else
    fail "$SCRIPT bash syntax invalid"
fi

for token in 'snapshot)' 'rollback)' 'status)' 'snapshot_local()' 'restore_local()' 'remote_snapshot_script()' 'remote_rollback_script()' 'restore_adguard_service()'; do
    if grep -q "$token" "$SCRIPT"; then
        ok "contains $token"
    else
        fail "missing $token"
    fi
done

for token in 'iptables-save' 'iptables-restore' 'ipset save' 'ipset restore' 'ip rule show' 'ip route show table all'; do
    if grep -q "$token" "$SCRIPT"; then
        ok "firewall/routing snapshot includes $token"
    else
        fail "firewall/routing snapshot missing $token"
    fi
done

for token in 'AdGuardHome' 'youtube-proxy' 'dnsmasq' 'ssh' 'sshd' 'fail2ban' 'split-tunnel-apply.sh' 'split-tunnel-rollback.sh' 'awg-quick@awg0' 'awg-quick@awg1'; do
    if grep -q "$token" "$SCRIPT"; then
        ok "service/split coverage includes $token"
    else
        fail "service/split coverage missing $token"
    fi
done

for token in 'cleanup_split_runtime_state_if_absent()' 'snapshot_split_active' 'fwmark 0x100 table 100' 'ip route flush table 100' 'ipset destroy ru_subnets'; do
    if grep -Fq -- "$token" "$SCRIPT"; then
        ok "split runtime rollback includes $token"
    else
        fail "split runtime rollback missing $token"
    fi
done

if grep -Fq '[ "\$ROLE" = "vps1" ] || return 0' "$SCRIPT"; then
    ok "split runtime cleanup is limited to VPS1"
else
    fail "split runtime cleanup must be limited to VPS1"
fi

if grep -Fq '[ "\$snapshot_split_active" = "1" ] && return 0' "$SCRIPT"; then
    ok "active split snapshot is preserved during runtime cleanup"
else
    fail "active split snapshot must bypass split runtime cleanup"
fi

for token in 'local-vpn-output.tar.gz' 'vpn-output.before-rollback' 'tar --exclude' 'tar -C / -czf' 'tar -C / -xzf'; do
    if grep -q -- "$token" "$SCRIPT"; then
        ok "local/filesystem rollback includes $token"
    else
        fail "local/filesystem rollback missing $token"
    fi
done

for token in 'file-list.managed-remove-if-absent' 'rm -rf "/\$p"' 'etc/systemd/system/AdGuardHome.service' 'etc/dnsmasq.d/vpn.conf'; do
    if grep -Fq -- "$token" "$SCRIPT"; then
        ok "managed absent cleanup includes $token"
    else
        fail "managed absent cleanup missing $token"
    fi
done

for token in 'etc/resolv.conf' 'etc/hosts' 'reload_ssh_runtime()' 'sshd -t' 'restore_service fail2ban'; do
    if grep -Fq -- "$token" "$SCRIPT"; then
        ok "system rollback coverage includes $token"
    else
        fail "system rollback coverage missing $token"
    fi
done

service_line="$(grep -n 'restoring service states' "$SCRIPT" | tail -1 | cut -d: -f1)"
firewall_line="$(grep -n 'restoring final IPv4 firewall state' "$SCRIPT" | tail -1 | cut -d: -f1)"
if [[ -n "$service_line" && -n "$firewall_line" && "$service_line" -lt "$firewall_line" ]]; then
    ok "final firewall restore happens after service restore"
else
    fail "final firewall restore must happen after service restore"
fi

if bash "$SCRIPT" status >/tmp/deploy-snapshot-rollback-status.out 2>&1; then
    ok "status works without remote SSH"
else
    fail "status should not require remote SSH credentials"
fi
rm -f /tmp/deploy-snapshot-rollback-status.out

if bash "$SCRIPT" snapshot --snapshot-id >/tmp/deploy-snapshot-rollback-missing-arg.out 2>&1; then
    fail "missing option value should fail"
elif grep -q -- '--snapshot-id requires a value' /tmp/deploy-snapshot-rollback-missing-arg.out; then
    ok "missing option value returns explicit error"
else
    fail "missing option value error is not explicit"
fi
rm -f /tmp/deploy-snapshot-rollback-missing-arg.out

if bash "$SCRIPT" rollback >/tmp/deploy-snapshot-rollback-missing-id.out 2>&1; then
    fail "rollback without snapshot id should fail"
elif grep -q -- 'rollback requires --snapshot-id' /tmp/deploy-snapshot-rollback-missing-id.out; then
    ok "rollback without snapshot id returns explicit error"
else
    fail "rollback without snapshot id error is not explicit"
fi
rm -f /tmp/deploy-snapshot-rollback-missing-id.out

if bash "$SCRIPT" rollback --snapshot-id .. >/tmp/deploy-snapshot-rollback-bad-id.out 2>&1; then
    fail "path-traversal snapshot id should fail"
elif grep -q -- 'Invalid --snapshot-id' /tmp/deploy-snapshot-rollback-bad-id.out; then
    ok "path-traversal snapshot id is rejected"
else
    fail "path-traversal snapshot id error is not explicit"
fi
rm -f /tmp/deploy-snapshot-rollback-bad-id.out

if bash "$SCRIPT" rollback --snapshot-id TEST --snapshot-root '/root/bad root' >/tmp/deploy-snapshot-rollback-bad-root.out 2>&1; then
    fail "unsafe snapshot root should fail"
elif grep -q -- '--snapshot-root may contain only' /tmp/deploy-snapshot-rollback-bad-root.out; then
    ok "unsafe snapshot root is rejected"
else
    fail "unsafe snapshot root error is not explicit"
fi
rm -f /tmp/deploy-snapshot-rollback-bad-root.out

if grep -q '^vpn-output\.before-rollback\.\*$' .gitignore; then
    ok "local rollback backup directory is gitignored"
else
    fail "local rollback backup directory must be gitignored"
fi

if grep -q 'Does not roll back OS package versions' "$SCRIPT" && grep -q 'apt' README.md; then
    ok "documents apt package rollback limitation"
else
    fail "missing apt package rollback limitation"
fi

for token in \
    'deploy-snapshot-rollback.sh' \
    'snapshot --snapshot-id "$snapshot_id"' \
    'rollback --snapshot-id "$snapshot_id"' \
    'Deploy failed with exit code' \
    'set +e'; do
    if grep -Fq -- "$token" manage.sh; then
        ok "manage.sh auto rollback integration includes $token"
    else
        fail "manage.sh auto rollback integration missing $token"
    fi
done

if grep -Fq 'при ошибке deploy запускается auto rollback' README.md; then
    ok "README documents automatic deploy rollback"
else
    fail "README missing automatic deploy rollback"
fi

echo ""
echo "=============================="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "=============================="

[[ "$FAIL" -eq 0 ]]
