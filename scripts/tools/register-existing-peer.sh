#!/usr/bin/env bash
# register-existing-peer.sh — регистрирует существующий пир на VPS1 без пересоздания ключей
#
# Использование:
#   bash scripts/tools/register-existing-peer.sh --pub-key <KEY> --ip <IP> --name <NAME>
#
# Пример:
#   bash scripts/tools/register-existing-peer.sh \
#     --pub-key "2Key91qJLutpDiUoYcD/p0kC3Q87ayqzSuq8duP57kA=" \
#     --ip "10.9.0.3" --name "slava-phone"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Конвертируем Windows-путь в /mnt/ если нужно (Git Bash → WSL)
if [[ "$SCRIPT_DIR" =~ ^/[A-Za-z]/ ]]; then
    _drive=$(echo "$SCRIPT_DIR" | cut -c2 | tr '[:upper:]' '[:lower:]')
    _rest=$(echo "$SCRIPT_DIR" | cut -c3-)
    SCRIPT_DIR="/mnt/${_drive}${_rest}"
fi

source "${SCRIPT_DIR}/../../lib/common.sh"
trap cleanup_temp_keys EXIT

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*" >&2; exit 1; }
info() { echo -e "  ${CYAN}→${NC} $*"; }

# ── Парсинг аргументов ─────────────────────────────────────────────────────
PEER_PUB=""
PEER_IP=""
PEER_NAME="peer"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pub-key) PEER_PUB="$2"; shift 2 ;;
        --ip)      PEER_IP="$2";  shift 2 ;;
        --name)    PEER_NAME="$2"; shift 2 ;;
        *) echo "Неизвестный аргумент: $1"; exit 1 ;;
    esac
done

[[ -z "$PEER_PUB" ]] && { echo "Ошибка: --pub-key обязателен"; exit 1; }
[[ -z "$PEER_IP"  ]] && { echo "Ошибка: --ip обязателен"; exit 1; }

# ── Загрузка конфига ─────────────────────────────────────────────────────
load_defaults_from_files

VPS1_USER="${VPS1_USER:-root}"
VPS1_KEY="$(expand_tilde "$VPS1_KEY")"
VPS1_KEY="$(auto_pick_key_if_missing "$VPS1_KEY")"
VPS1_KEY="$(prepare_key_for_ssh "$VPS1_KEY")"

require_vars "register-existing-peer.sh" VPS1_IP
[[ -z "$VPS1_KEY" ]] && fail "VPS1_KEY не найден"

SSH_TIMEOUT="${SSH_TIMEOUT:-20}"
ssh1() { ssh_exec "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "${VPS1_PASS:-}" "$1" "$SSH_TIMEOUT"; }

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Регистрация пира на VPS1                          ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
info "Пир:   $PEER_NAME"
info "IP:    $PEER_IP/32"
info "Ключ:  ${PEER_PUB:0:20}..."
echo ""

# ── Проверка: не зарегистрирован ли уже? ───────────────────────────────
info "Проверяем текущие пиры awg1..."
existing=$(ssh1 "sudo awg show awg1 allowed-ips 2>/dev/null || true")
if echo "$existing" | grep -qF "${PEER_IP}/32"; then
    ok "Пир уже зарегистрирован на VPS1 (${PEER_IP}/32)"
    exit 0
fi

# ── Регистрация в живом демоне ──────────────────────────────────────────
info "Добавляем пир в awg1 (live)..."
ssh1 "sudo awg set awg1 peer '${PEER_PUB}' allowed-ips '${PEER_IP}/32'"
ok "Пир добавлен в awg1 (live)"

# ── Добавление в awg1.conf для сохранения после рестарта ───────────────
info "Добавляем пир в /etc/amnezia/amneziawg/awg1.conf..."
ssh1 "printf '\n# %s\n[Peer]\nPublicKey  = %s\nAllowedIPs = %s/32\n' '${PEER_NAME}' '${PEER_PUB}' '${PEER_IP}' | sudo tee -a /etc/amnezia/amneziawg/awg1.conf >/dev/null"
ok "Пир добавлен в awg1.conf"

# ── Проверка ───────────────────────────────────────────────────────────
info "Проверяем результат..."
result=$(ssh1 "sudo awg show awg1 allowed-ips 2>/dev/null || true")
if echo "$result" | grep -qF "${PEER_IP}/32"; then
    ok "Пир ${PEER_NAME} (${PEER_IP}/32) успешно зарегистрирован на VPS1"
else
    fail "Пир не появился в awg show awg1 — проверьте вручную"
fi

echo ""
echo "  Готово. Переподключи AmneziaVPN на телефоне."
echo ""
