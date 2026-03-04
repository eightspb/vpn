#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"

VPS1_IP="${VPS1_IP:-}"
VPS1_USER="${VPS1_USER:-slava}"
VPS1_KEY="${VPS1_KEY:-}"
ADMIN_PASSWORD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vps1-ip) VPS1_IP="$2"; shift 2 ;;
    --vps1-user) VPS1_USER="$2"; shift 2 ;;
    --vps1-key) VPS1_KEY="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
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
ARCHIVE="${PROJECT_ROOT}/vpn-output/vps1-admin-redeploy.tar.gz"
SSH_BIN="${SSH_BIN:-ssh}"
SCP_BIN="${SCP_BIN:-scp}"

find_windows_ssh_bin() {
  for p in \
    "/c/Windows/System32/OpenSSH/ssh.exe" \
    "/mnt/c/Windows/System32/OpenSSH/ssh.exe"
  do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

find_windows_scp_bin() {
  for p in \
    "/c/Windows/System32/OpenSSH/scp.exe" \
    "/mnt/c/Windows/System32/OpenSSH/scp.exe"
  do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

ssh_connect_check() {
  local bin="$1"
  "$bin" -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -i "$VPS1_KEY" "${VPS1_USER}@${VPS1_IP}" "echo ok" >/dev/null 2>&1
}

# If bash ssh can't reach host but Windows OpenSSH can, auto-fallback.
if ! ssh_connect_check "$SSH_BIN"; then
  WIN_SSH_BIN="$(find_windows_ssh_bin || true)"
  WIN_SCP_BIN="$(find_windows_scp_bin || true)"
  if [[ -n "${WIN_SSH_BIN:-}" && -n "${WIN_SCP_BIN:-}" ]] && ssh_connect_check "$WIN_SSH_BIN"; then
    warn "bash ssh can't reach ${VPS1_IP}; switching to Windows OpenSSH fallback"
    SSH_BIN="$WIN_SSH_BIN"
    SCP_BIN="$WIN_SCP_BIN"
  fi
fi

step "Pulling latest code from GitHub"
if (cd "$PROJECT_ROOT" && git pull --ff-only 2>&1); then
  ok "Code updated from remote"
else
  warn "git pull failed — deploying current local code"
fi

step "Packing project snapshot"
mkdir -p "${PROJECT_ROOT}/vpn-output"
rm -f "$ARCHIVE"
tar -czf "$ARCHIVE" \
  --exclude=.git \
  --exclude=backend/.venv \
  --exclude=scripts/admin/.venv \
  --exclude=vpn-output/vps1-admin-redeploy.tar.gz \
  --exclude=node_modules \
  --exclude=__pycache__ \
  -C "$PROJECT_ROOT" .

step "Uploading snapshot to VPS1"
"$SCP_BIN" "${SSH_OPTS[@]}" "$ARCHIVE" "${VPS1_USER}@${VPS1_IP}:/tmp/vpn-deploy.tar.gz"

step "Deploying admin service on VPS1"
"$SSH_BIN" "${SSH_OPTS[@]}" "${VPS1_USER}@${VPS1_IP}" "set -e; rm -rf /tmp/vpn-deploy && mkdir -p /tmp/vpn-deploy && tar -xzf /tmp/vpn-deploy.tar.gz -C /tmp/vpn-deploy && sudo bash /tmp/vpn-deploy/scripts/deploy/deploy-admin-vps1-remote.sh"

step "Updating bot service code and restarting vpn-bot"
"$SSH_BIN" "${SSH_OPTS[@]}" "${VPS1_USER}@${VPS1_IP}" "set -e; \
if [[ ! -d /home/slava/vpn-bot/backend ]]; then \
  echo 'Bot source dir missing: /home/slava/vpn-bot/backend' >&2; \
  exit 1; \
fi; \
if [[ ! -d /opt/vpn/backend ]]; then \
  echo 'Fresh backend source missing: /opt/vpn/backend' >&2; \
  exit 1; \
fi; \
rsync -a /opt/vpn/backend/ /home/slava/vpn-bot/backend/; \
sudo systemctl restart vpn-bot.service; \
sleep 1; \
if ! sudo systemctl is-active --quiet vpn-bot.service; then \
  sudo systemctl --no-pager -l status vpn-bot.service || true; \
  sudo journalctl -u vpn-bot.service -n 120 --no-pager || true; \
  exit 1; \
fi"

if [[ -n "$ADMIN_PASSWORD" ]]; then
  step "Setting admin password"
  "$SSH_BIN" "${SSH_OPTS[@]}" "${VPS1_USER}@${VPS1_IP}" "sudo /opt/vpn/scripts/admin/.venv/bin/python - <<'PY'
import sqlite3, bcrypt
DB='/opt/vpn/scripts/admin/admin.db'
NEW=${ADMIN_PASSWORD@Q}
conn=sqlite3.connect(DB)
cur=conn.cursor()
cur.execute('UPDATE users SET password_hash=? WHERE username=?', (bcrypt.hashpw(NEW.encode(), bcrypt.gensalt(rounds=12)).decode(), 'admin'))
conn.commit()
print('rows', cur.rowcount)
conn.close()
PY"
fi

step "Smoke checks"
"$SSH_BIN" "${SSH_OPTS[@]}" "${VPS1_USER}@${VPS1_IP}" "set -e; \
curl -k -fsS https://127.0.0.1:8443/api/health >/dev/null; \
ADMIN_HTML=\$(curl -k -fsS https://127.0.0.1:8443/admin.html); \
printf '%s' \"\$ADMIN_HTML\" | grep -q 'Bot Control'; \
BOT_TOKEN=\$(grep -E '^BOT_INTERNAL_API_TOKEN=' /opt/vpn/.env | head -n1 | cut -d= -f2- | tr -d ' \r\n'); \
[ -n \"\$BOT_TOKEN\" ]; \
if ! curl -fsS -H \"X-Bot-Internal-Token: \$BOT_TOKEN\" http://127.0.0.1:8010/admin/bot/overview >/dev/null; then \
  sudo systemctl --no-pager -l status vpn-bot.service || true; \
  sudo journalctl -u vpn-bot.service -n 120 --no-pager || true; \
  exit 1; \
fi"

ok "Redeploy completed: admin + bot are updated on VPS1"
