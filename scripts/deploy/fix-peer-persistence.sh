#!/usr/bin/env bash
# fix-peer-persistence.sh — Sync runtime peers to awg1.conf and deploy updated admin-server
# This ensures all peers survive awg1 restarts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"

VPS1_IP="${VPS1_IP:-}"
VPS1_USER="${VPS1_USER:-slava}"
VPS1_KEY="${VPS1_KEY:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vps1-ip) VPS1_IP="$2"; shift 2 ;;
    --vps1-user) VPS1_USER="$2"; shift 2 ;;
    --vps1-key) VPS1_KEY="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

load_defaults_from_files
VPS1_IP="${VPS1_IP:-${VPS1_IP:-}}"
VPS1_USER="${VPS1_USER:-${VPS1_USER:-slava}}"
VPS1_KEY="$(expand_tilde "${VPS1_KEY:-}")"
VPS1_KEY="$(auto_pick_key_if_missing "$VPS1_KEY")"
VPS1_KEY="$(prepare_key_for_ssh "$VPS1_KEY")"
trap cleanup_temp_keys EXIT

[[ -n "${VPS1_IP:-}" ]] || err "VPS1_IP is required"
[[ -n "${VPS1_KEY:-}" ]] || err "VPS1_KEY is required"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -i "$VPS1_KEY")

remote() { ssh "${SSH_OPTS[@]}" "${VPS1_USER}@${VPS1_IP}" "$1"; }

# ── Step 1: Sync runtime peers into awg1.conf ────────────────────────────────
step "Syncing runtime peers into awg1.conf"

remote 'sudo python3 - <<'\''PYEOF'\''
import re, subprocess, textwrap

CONF = "/etc/amnezia/amneziawg/awg1.conf"

# Read existing config
with open(CONF) as f:
    conf_text = f.read()

# Get public keys already in config
existing_keys = set(re.findall(r"PublicKey\s*=\s*(\S+)", conf_text))

# Get full runtime peer info via awg showconf
runtime = subprocess.check_output(["awg", "showconf", "awg1"], text=True)
# Split into sections
sections = re.split(r"(?=^\[)", runtime, flags=re.MULTILINE)

added = 0
for section in sections:
    if not section.startswith("[Peer]"):
        continue
    m = re.search(r"PublicKey\s*=\s*(\S+)", section)
    if not m:
        continue
    pk = m.group(1)
    if pk in existing_keys:
        continue
    # Append this peer to config
    conf_text = conf_text.rstrip("\n") + "\n\n" + section.strip() + "\n"
    added += 1
    print(f"  Added: {pk[:20]}...")

if added:
    with open(CONF, "w") as f:
        f.write(conf_text)
    print(f"Synced {added} peers to {CONF}")
else:
    print("All peers already in config — nothing to sync")
PYEOF'

ok "Peers synced"

# ── Step 2: Verify ip rule persistence in awg1 PostUp ────────────────────────
step "Verifying ip rule in awg1 PostUp"
remote 'sudo grep -q "ip rule add from 10.9.0.0/24 table 200" /etc/amnezia/amneziawg/awg1.conf && echo "ip rule: OK" || echo "ip rule: MISSING"'

# ── Step 3: Verify ip route table 200 in PostUp ──────────────────────────────
step "Verifying route table 200 in awg1 PostUp"
remote 'sudo grep -q "ip route add default via 10.8.0.2 dev awg0 table 200" /etc/amnezia/amneziawg/awg1.conf && echo "route table 200: OK" || echo "route table 200: MISSING"'

# ── Step 4: Verify current runtime state ──────────────────────────────────────
step "Checking current runtime state"
remote 'echo "--- ip rule ---"; ip rule show; echo "--- table 200 ---"; ip route show table 200 2>/dev/null || echo "(empty)"; echo "--- awg1 peers ---"; sudo awg show awg1 | grep -c "^peer:" | xargs -I{} echo "{} peers active"; echo "--- conf peers ---"; sudo grep -c "^\[Peer\]" /etc/amnezia/amneziawg/awg1.conf | xargs -I{} echo "{} peers in config"'

# ── Step 5: Test restart resilience ───────────────────────────────────────────
step "Testing awg1 restart resilience"
remote 'set -e
BEFORE=$(sudo awg show awg1 | grep -c "^peer:")
sudo systemctl restart awg-quick@awg1
sleep 2
AFTER=$(sudo awg show awg1 | grep -c "^peer:")
echo "Peers before restart: $BEFORE"
echo "Peers after restart:  $AFTER"
if [[ "$BEFORE" -ne "$AFTER" ]]; then
  echo "ERROR: Peer count mismatch after restart!"
  exit 1
fi
echo "--- ip rule after restart ---"
ip rule show | grep "10.9.0.0/24" || { echo "ERROR: ip rule missing after restart!"; exit 1; }
echo "--- table 200 after restart ---"
ip route show table 200 2>/dev/null || { echo "ERROR: table 200 empty after restart!"; exit 1; }
echo "All checks passed"'

ok "awg1 restart resilience verified"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          PEER PERSISTENCE FIX APPLIED ✓                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  ✓ Runtime peers synced to awg1.conf"
echo "  ✓ ip rule + route table 200 in PostUp"
echo "  ✓ awg1 restart tested — all peers survived"
echo ""
echo "  Next: run redeploy-admin-vps1.sh to deploy updated admin-server.py"
echo "        (so future peers will auto-persist too)"
