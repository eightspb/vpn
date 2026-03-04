#!/usr/bin/env bash
# diagnose-dashboard.sh — Quick diagnostic for admin dashboard issues.
# Usage: bash scripts/tools/diagnose-dashboard.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}   $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }

echo "=== Dashboard Diagnostic ==="
echo ""

# 1. Check .env
echo "--- .env Configuration ---"
ENV_FILE="$PROJECT_ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
  ok ".env exists"
  VPS1_IP=$(grep -E '^VPS1_IP=' "$ENV_FILE" | cut -d= -f2)
  VPS1_USER=$(grep -E '^VPS1_USER=' "$ENV_FILE" | cut -d= -f2)
  VPS1_KEY=$(grep -E '^VPS1_KEY=' "$ENV_FILE" | cut -d= -f2)
  VPS2_IP=$(grep -E '^VPS2_IP=' "$ENV_FILE" | cut -d= -f2)
  SECRET_KEY=$(grep -E '^ADMIN_SECRET_KEY=' "$ENV_FILE" | cut -d= -f2)
  [[ -n "$VPS1_IP" ]] && ok "VPS1_IP=$VPS1_IP" || fail "VPS1_IP is empty"
  [[ -n "$VPS1_USER" ]] && ok "VPS1_USER=$VPS1_USER" || warn "VPS1_USER is empty (defaults to root)"
  [[ -n "$VPS2_IP" ]] && ok "VPS2_IP=$VPS2_IP" || fail "VPS2_IP is empty"
  [[ -n "$SECRET_KEY" ]] && ok "ADMIN_SECRET_KEY is set" || warn "ADMIN_SECRET_KEY is empty (sessions won't survive restart)"
else
  fail ".env not found at $ENV_FILE"
fi

# 2. Check SSH key
echo ""
echo "--- SSH Key ---"
if [[ -n "${VPS1_KEY:-}" ]]; then
  RESOLVED=""
  for candidate in \
    "$PROJECT_ROOT/$VPS1_KEY" \
    "$HOME/.ssh/$(basename "$VPS1_KEY")" \
    "$VPS1_KEY"; do
    if [[ -f "$candidate" ]]; then
      RESOLVED="$candidate"
      break
    fi
  done
  if [[ -n "$RESOLVED" ]]; then
    ok "SSH key found: $RESOLVED"
  else
    fail "SSH key not found for VPS1_KEY=$VPS1_KEY"
  fi
fi

# 3. Check SSH connectivity
echo ""
echo "--- SSH Connectivity ---"
SSH_KEY_ARG=""
if [[ -n "${RESOLVED:-}" ]]; then
  SSH_KEY_ARG="-i $RESOLVED"
fi
for label_ip_user in "VPS1:${VPS1_IP:-}:${VPS1_USER:-root}" "VPS2:${VPS2_IP:-}:root"; do
  IFS=: read -r label ip user <<< "$label_ip_user"
  if [[ -z "$ip" ]]; then
    fail "$label: IP not configured"
    continue
  fi
  if timeout 10 ssh -F /dev/null -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
    -o BatchMode=yes $SSH_KEY_ARG "$user@$ip" "echo ok" >/dev/null 2>&1; then
    ok "$label ($user@$ip): SSH connection OK"
  else
    fail "$label ($user@$ip): SSH connection FAILED (timeout or auth error)"
  fi
done

# 4. Check data.json freshness
echo ""
echo "--- Monitor Data ---"
for dj in "$PROJECT_ROOT/scripts/monitor/vpn-output/data.json" "$PROJECT_ROOT/vpn-output/data.json"; do
  if [[ -f "$dj" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$dj" 2>/dev/null || stat -f %m "$dj" 2>/dev/null || echo 0) ))
    if [[ $age -lt 90 ]]; then
      ok "$(basename "$(dirname "$dj")")/data.json: fresh (${age}s old)"
    else
      warn "$(basename "$(dirname "$dj")")/data.json: STALE (${age}s old, threshold=90s)"
    fi
  else
    warn "$(basename "$(dirname "$dj")")/data.json: not found"
  fi
done

# 5. Check if admin-server is running
echo ""
echo "--- Admin Server ---"
if curl -sf http://127.0.0.1:8081/api/health 2>/dev/null; then
  echo ""
  ok "Admin server is running on port 8081"
  HEALTH=$(curl -sf http://127.0.0.1:8081/api/health 2>/dev/null || echo '{}')
  MON_RUNNING=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('monitor_running','?'))" 2>/dev/null || echo "?")
  MON_AGE=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('monitor_data_age_sec','?'))" 2>/dev/null || echo "?")
  echo "  Monitor running: $MON_RUNNING, data age: ${MON_AGE}s"
else
  warn "Admin server NOT running on port 8081"
fi

# 6. Check localStorage hint
echo ""
echo "--- Browser Hints ---"
warn "If login works but dashboard shows nothing:"
warn "  1. Open browser DevTools → Console"
warn "  2. Run: localStorage.removeItem('admin_api_mode')"
warn "  3. Reload the page"
warn "  This clears the v1 API mode that was causing 404 errors."

echo ""
echo "=== Done ==="
