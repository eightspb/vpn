#!/usr/bin/env bash
set -euo pipefail

PROJECT_SRC=/tmp/vpn-deploy
PROJECT_DST=/opt/vpn
SERVICE_NAME=vpn-admin
ADMIN_USER=slava
ADMIN_PORT=8443
CERT_DIR=/opt/vpn/scripts/admin/certs
CERT_FILE=${CERT_DIR}/admin.crt
KEY_FILE=${CERT_DIR}/admin.key
ENV_FILE=/opt/vpn/.env
ADMIN_PORT="${ADMIN_PORT//$'\r'/}"

if [[ ! -d "$PROJECT_SRC" ]]; then
  echo "Source not found: $PROJECT_SRC" >&2
  exit 1
fi

sudo apt-get update -qq
sudo apt-get install -y -qq python3 openssl curl rsync ca-certificates >/dev/null

# Preserve persistent data (database, certs, .env) across deploys
ADMIN_DB="${PROJECT_DST}/scripts/admin/admin.db"
PRESERVE_DIR="/tmp/vpn-preserve-$$"
if [[ -d "$PROJECT_DST" ]]; then
  mkdir -p "$PRESERVE_DIR"
  # Save files that must survive redeploy
  [[ -f "$ADMIN_DB" ]] && cp -p "$ADMIN_DB" "$PRESERVE_DIR/admin.db"
  [[ -d "${PROJECT_DST}/scripts/admin/certs" ]] && cp -rp "${PROJECT_DST}/scripts/admin/certs" "$PRESERVE_DIR/certs"
  [[ -f "${PROJECT_DST}/.env" ]] && cp -p "${PROJECT_DST}/.env" "$PRESERVE_DIR/.env"

  ts=$(date +%Y%m%d-%H%M%S)
  sudo mv "$PROJECT_DST" "${PROJECT_DST}.backup-${ts}"
fi
sudo mkdir -p "$PROJECT_DST"
sudo rsync -a --delete "$PROJECT_SRC"/ "$PROJECT_DST"/
sudo chown -R ${ADMIN_USER}:${ADMIN_USER} "$PROJECT_DST"

# Restore preserved data
if [[ -d "$PRESERVE_DIR" ]]; then
  [[ -f "$PRESERVE_DIR/admin.db" ]] && cp -p "$PRESERVE_DIR/admin.db" "$ADMIN_DB"
  [[ -d "$PRESERVE_DIR/certs" ]] && cp -rp "$PRESERVE_DIR/certs" "${PROJECT_DST}/scripts/admin/certs"
  [[ -f "$PRESERVE_DIR/.env" ]] && cp -p "$PRESERVE_DIR/.env" "${PROJECT_DST}/.env"
  sudo chown -R ${ADMIN_USER}:${ADMIN_USER} "$PROJECT_DST"
  rm -rf "$PRESERVE_DIR"
fi

# Fix SSH key permissions — SSH refuses keys with group/other access.
if [[ -d "${PROJECT_DST}/.ssh" ]]; then
  sudo chmod 700 "${PROJECT_DST}/.ssh"
  sudo find "${PROJECT_DST}/.ssh" -type f -name '*.pub' -exec chmod 644 {} \;
  sudo find "${PROJECT_DST}/.ssh" -type f ! -name '*.pub' -exec chmod 600 {} \;
fi

sudo -u "$ADMIN_USER" bash -lc '
set -euo pipefail
UV_BIN="${HOME}/.local/bin/uv"
if [[ ! -x "$UV_BIN" ]]; then
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
fi
"$UV_BIN" --version >/dev/null
cd "'"$PROJECT_DST"'"
"$UV_BIN" venv --python python3 scripts/admin/.venv >/dev/null
"$UV_BIN" pip install --python scripts/admin/.venv/bin/python -r scripts/admin/requirements.txt >/dev/null
'

if ! sudo grep -q '^ADMIN_SECRET_KEY=' "$ENV_FILE"; then
  SECRET=$(openssl rand -hex 32)
  echo "ADMIN_SECRET_KEY=$SECRET" | sudo tee -a "$ENV_FILE" >/dev/null
fi

sudo mkdir -p "$CERT_DIR"
if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
  VPS1_IP=$(sudo awk -F= '/^VPS1_IP=/{print $2}' "$ENV_FILE" | tr -d ' \r\n')
  if [[ -z "$VPS1_IP" ]]; then VPS1_IP="127.0.0.1"; fi
  sudo openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/CN=${VPS1_IP}" >/dev/null 2>&1
fi
sudo chown -R ${ADMIN_USER}:${ADMIN_USER} "$CERT_DIR"
sudo chmod 600 "$KEY_FILE"
sudo chmod 644 "$CERT_FILE"

sudo -u "$ADMIN_USER" bash -lc '
set -e
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/known_hosts
chmod 600 ~/.ssh/known_hosts
VPS1_IP=$(awk -F= "/^VPS1_IP=/{print \$2}" /opt/vpn/.env | tr -d " \\r\\n")
if [[ -n "$VPS1_IP" ]]; then
  ssh-keygen -F "$VPS1_IP" >/dev/null || ssh-keyscan -H "$VPS1_IP" >> ~/.ssh/known_hosts 2>/dev/null || true
fi
'

sudo tee /etc/systemd/system/${SERVICE_NAME}.service >/dev/null <<UNIT
[Unit]
Description=VPN Admin Panel (Flask)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${ADMIN_USER}
Group=${ADMIN_USER}
WorkingDirectory=${PROJECT_DST}
ExecStart=${PROJECT_DST}/scripts/admin/.venv/bin/python ${PROJECT_DST}/scripts/admin/admin-server.py --prod --host 0.0.0.0 --port ${ADMIN_PORT} --cert ${CERT_FILE} --key ${KEY_FILE}
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable ${SERVICE_NAME} >/dev/null
sudo systemctl restart ${SERVICE_NAME}
sleep 2
sudo systemctl --no-pager --full status ${SERVICE_NAME} | sed -n '1,16p'

if sudo command -v ufw >/dev/null 2>&1; then
  if sudo ufw status | grep -q "Status: active"; then
    sudo ufw allow ${ADMIN_PORT}/tcp >/dev/null || true
  fi
fi

if sudo command -v iptables >/dev/null 2>&1; then
  sudo iptables -C INPUT -p tcp --dport ${ADMIN_PORT} -j ACCEPT 2>/dev/null || sudo iptables -I INPUT 1 -p tcp --dport ${ADMIN_PORT} -j ACCEPT
  if sudo command -v netfilter-persistent >/dev/null 2>&1; then
    sudo netfilter-persistent save >/dev/null 2>&1 || true
  fi
fi

curl -kfsS "https://127.0.0.1:${ADMIN_PORT}/api/health"
