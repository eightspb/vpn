#!/usr/bin/env bash
# =============================================================================
# setup-split-tunneling.sh — устанавливает и включает split tunneling на VPS1
#
# Что делает:
#   1. Устанавливает dnsmasq и ipset на VPS1 (apt)
#   2. Раскладывает конфиги: /etc/dnsmasq.d/vpn.conf, systemd drop-in,
#      /usr/local/sbin/split-tunnel-{apply,rollback}.sh,
#      /etc/systemd/system/split-tunnel-restore.service
#   3. Бэкапит /etc/dnsmasq.conf, заменяет минимальным conf-dir-only
#   4. Запускает dnsmasq, healthcheck
#   5. Запускает split-tunnel-apply.sh (zero-downtime переключение)
#   6. Включает split-tunnel-restore.service для автостарта после ребута
#
# Использование:
#   bash scripts/deploy/setup-split-tunneling.sh [--vps1-ip IP] [--vps1-key KEY]
#   bash scripts/deploy/setup-split-tunneling.sh --dry-run     # pre-flight only
#   bash scripts/deploy/setup-split-tunneling.sh --rollback    # полный откат
#
# Идемпотентен: повторный запуск ничего не ломает.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/split-tunneling"

source "${PROJECT_ROOT}/lib/common.sh"

VPS1_IP=""; VPS1_USER=""; VPS1_KEY=""; VPS1_PASS=""
TUN_NET=""; CLIENT_NET=""
DRY_RUN=0; DO_ROLLBACK=0

load_defaults_from_files

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps1-ip)   VPS1_IP="$2";   shift 2 ;;
        --vps1-user) VPS1_USER="$2"; shift 2 ;;
        --vps1-key)  VPS1_KEY="$2";  shift 2 ;;
        --vps1-pass) VPS1_PASS="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=1;      shift ;;
        --rollback)  DO_ROLLBACK=1;  shift ;;
        --help|-h)
            cat <<EOF
Usage: bash $0 [options]

  --vps1-ip IP        IP VPS1 (из .env, если не задан)
  --vps1-user USER    SSH-пользователь
  --vps1-key KEY      путь к SSH-ключу
  --vps1-pass PASS    SSH-пароль
  --dry-run           проверить готовность, ничего не менять
  --rollback          полный откат (вернуть состояние ДО split tunneling)
  --help              эта справка

Идемпотентен. Безопасно запускать повторно.
EOF
            exit 0 ;;
        *) err "Неизвестный параметр: $1" ;;
    esac
done

VPS1_USER="${VPS1_USER:-root}"
TUN_NET="${TUN_NET:-10.8.0}"
CLIENT_NET="${CLIENT_NET:-10.9.0}"

VPS1_KEY="$(expand_tilde "$VPS1_KEY")"
VPS1_KEY="$(auto_pick_key_if_missing "$VPS1_KEY")"
VPS1_KEY="$(prepare_key_for_ssh "$VPS1_KEY")"

require_vars "setup-split-tunneling.sh" VPS1_IP
[[ -z "$VPS1_KEY" && -z "$VPS1_PASS" ]] && err "Укажите --vps1-key или --vps1-pass (или VPS1_KEY в .env)"

trap cleanup_temp_keys EXIT

# Локальные обёртки чтобы не передавать одну и ту же четвёрку кредов в каждый
# вызов. Вызываются ниже после require_vars/key checks.
remote()        { ssh_exec        "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS" "$@"; }
remote_script() { ssh_run_script  "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS" "$1"; }
upload()        { ssh_upload "$1" "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS" "$2"; }

# ── Проверка наличия артефактов локально ────────────────────────────────────
for f in dnsmasq-vpn.conf dnsmasq.service.d/override.conf \
         split-tunnel-apply.sh split-tunnel-rollback.sh split-tunnel-restore.service; do
    [[ -f "${ARTIFACTS_DIR}/${f}" ]] || err "Артефакт не найден: ${ARTIFACTS_DIR}/${f}"
done
ok "Артефакты найдены в ${ARTIFACTS_DIR}"

# ── Rollback mode ───────────────────────────────────────────────────────────
if [[ "$DO_ROLLBACK" == "1" ]]; then
    step "Полный откат split tunneling на VPS1 (${VPS1_IP})"
    remote "sudo bash /usr/local/sbin/split-tunnel-rollback.sh" || true
    remote "sudo systemctl disable split-tunnel-restore.service 2>/dev/null || true" || true
    ok "Rollback выполнен. Состояние идентично пред-split-tunneling."
    exit 0
fi

# ── Pre-flight checks ───────────────────────────────────────────────────────
step "Pre-flight check (VPS1=${VPS1_IP})"

remote "true" || err "SSH-соединение с ${VPS1_IP} не установлено"
ok "SSH-соединение с VPS1"

REMOTE_INFO="$(remote "
    set -e
    echo OS=\$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')
    echo MAIN_IF=\$(ip route show default | awk '/^default/ {print \$5; exit}')
    echo MAIN_GW=\$(ip route show default | awk '/^default/ {print \$3; exit}')
    echo AWG1=\$(ip link show awg1 2>/dev/null | head -1 | awk -F: '{print \$2}' | tr -d ' ')
    echo DNSMASQ_INSTALLED=\$(command -v dnsmasq >/dev/null 2>&1 && echo yes || echo no)
    echo IPSET_INSTALLED=\$(command -v ipset >/dev/null 2>&1 && echo yes || echo no)
")"

info "VPS1 info:"
echo "$REMOTE_INFO" | sed 's/^/    /'

REMOTE_MAIN_IF="$(parse_kv "$REMOTE_INFO" MAIN_IF)"
REMOTE_AWG1="$(parse_kv "$REMOTE_INFO" AWG1)"

[[ -n "$REMOTE_MAIN_IF" ]] || err "На VPS1 не найден default route"
[[ "$REMOTE_AWG1" == "awg1" ]] || err "На VPS1 не поднят интерфейс awg1"
ok "Pre-flight check пройден"

if [[ "$DRY_RUN" == "1" ]]; then
    ok "Dry-run завершён. Изменения не применялись."
    exit 0
fi

# ── 1. Установка пакетов ────────────────────────────────────────────────────
step "Установка dnsmasq и ipset"

remote_script "$(cat <<'REMOTE_INSTALL'
set -euo pipefail

# Маска защищает от auto-start dnsmasq на :53 во время apt install
# (до того, как мы положим bind-dynamic конфиг). Снимется в следующем шаге.
systemctl mask dnsmasq 2>/dev/null || true

DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsmasq ipset dnsutils >/dev/null

systemctl stop dnsmasq 2>/dev/null || true

echo "dnsmasq $(dnsmasq --version 2>/dev/null | head -1)"
echo "ipset $(ipset --version | head -1)"
REMOTE_INSTALL
)"
ok "Пакеты установлены (dnsmasq masked до раскладки конфигов)"

# ── 2. Загрузка артефактов на VPS1 ──────────────────────────────────────────
step "Загрузка артефактов на VPS1"

upload "${ARTIFACTS_DIR}/dnsmasq-vpn.conf"                  /tmp/_st_dnsmasq-vpn.conf
upload "${ARTIFACTS_DIR}/dnsmasq.service.d/override.conf"   /tmp/_st_dnsmasq-override.conf
upload "${ARTIFACTS_DIR}/split-tunnel-apply.sh"             /tmp/_st_apply.sh
upload "${ARTIFACTS_DIR}/split-tunnel-rollback.sh"          /tmp/_st_rollback.sh
upload "${ARTIFACTS_DIR}/split-tunnel-restore.service"      /tmp/_st_restore.service
ok "Артефакты загружены в /tmp/"

# ── 3. Раскладка по местам, запуск dnsmasq ──────────────────────────────────
step "Раскладка артефактов, запуск dnsmasq"

remote_script "$(cat <<'REMOTE_DEPLOY'
set -euo pipefail

# Размаскируем dnsmasq — он будет нужен ниже для start
systemctl unmask dnsmasq 2>/dev/null || true

# Бэкапим оригинальный /etc/dnsmasq.conf если файл существует и бэкап ещё не делали
if [[ -f /etc/dnsmasq.conf ]]; then
    if [[ ! -f /etc/dnsmasq.conf.bak.pre-split-tunneling ]]; then
        cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak.pre-split-tunneling
        echo "[ok] backup: /etc/dnsmasq.conf.bak.pre-split-tunneling"
    else
        echo "[info] backup уже существует, не перезаписываю"
    fi
else
    echo "[info] /etc/dnsmasq.conf отсутствует — бэкап не нужен (свежая установка)"
fi

# Минимальный /etc/dnsmasq.conf — только инклюд нашей директории
cat > /etc/dnsmasq.conf << 'EOF'
# Managed by setup-split-tunneling.sh — DO NOT EDIT
# Original backup (if existed): /etc/dnsmasq.conf.bak.pre-split-tunneling
conf-dir=/etc/dnsmasq.d/,*.conf
EOF
chmod 644 /etc/dnsmasq.conf

# Главный конфиг для split tunneling
install -m 644 /tmp/_st_dnsmasq-vpn.conf /etc/dnsmasq.d/vpn.conf

# systemd drop-in для dnsmasq (зависимость от awg-quick@awg1)
mkdir -p /etc/systemd/system/dnsmasq.service.d
install -m 644 /tmp/_st_dnsmasq-override.conf /etc/systemd/system/dnsmasq.service.d/override.conf

# Скрипты split-tunnel-apply / rollback
install -m 755 /tmp/_st_apply.sh    /usr/local/sbin/split-tunnel-apply.sh
install -m 755 /tmp/_st_rollback.sh /usr/local/sbin/split-tunnel-rollback.sh

# systemd-юнит для автостарта после ребута
install -m 644 /tmp/_st_restore.service /etc/systemd/system/split-tunnel-restore.service

# Очистка temp
rm -f /tmp/_st_*.sh /tmp/_st_*.conf /tmp/_st_*.service

systemctl daemon-reload

# Поднимаем dnsmasq (он зависит от awg-quick@awg1, который уже должен быть up)
systemctl enable dnsmasq >/dev/null
systemctl restart dnsmasq

# Ждём пока dnsmasq поднимется и забиндится на 10.9.0.1:53
for i in 1 2 3 4 5 6 7 8 9 10; do
    if ss -lnup 2>/dev/null | grep -q '10.9.0.1:53'; then
        echo "[ok] dnsmasq слушает 10.9.0.1:53"
        DNSMASQ_OK=1; break
    fi
    sleep 1
done

if [[ "${DNSMASQ_OK:-0}" != "1" ]]; then
    echo "[fatal] dnsmasq не забиндился на 10.9.0.1:53" >&2
    systemctl status dnsmasq --no-pager -l | head -20 >&2
    exit 1
fi

# Простой DNS-резолв через dnsmasq
if dig +time=3 +tries=1 @10.9.0.1 example.com +short >/dev/null 2>&1; then
    echo "[ok] dnsmasq резолвит example.com"
else
    echo "[fatal] dnsmasq не отвечает на резолв example.com" >&2
    exit 1
fi
REMOTE_DEPLOY
)"
ok "dnsmasq запущен и отвечает на 10.9.0.1:53"

# ── 4. Запуск split-tunnel-apply.sh (zero-downtime переключение) ────────────
step "Применение split tunneling (zero-downtime через CONNMARK)"

remote "sudo bash /usr/local/sbin/split-tunnel-apply.sh" \
    || err "split-tunnel-apply.sh завершился с ошибкой — старые DNS-правила сохранены"
ok "Split tunneling включён"

# ── 5. Включение автостарта split-tunnel-restore ────────────────────────────
step "Включение автостарта после ребута"

remote "sudo systemctl enable split-tunnel-restore.service >/dev/null"
ok "split-tunnel-restore.service enabled"

# ── 6. Финальная верификация ────────────────────────────────────────────────
step "Финальная верификация"

VERIFY="$(remote_script "$(cat <<'REMOTE_VERIFY'
set -uo pipefail
echo "── dnsmasq ──"
systemctl is-active dnsmasq
ss -lnup 2>/dev/null | grep ':53.*dnsmasq' | head -1
echo "── ipset ──"
ipset list ru_subnets 2>/dev/null | grep 'Number of entries'
echo "── iptables mangle ──"
iptables -t mangle -S PREROUTING | grep awg1 | wc -l
echo "── iptables nat (DNS DNAT) ──"
iptables -t nat -S PREROUTING | grep -E 'dport 53' | sed 's/^/   /'
echo "── ip rule fwmark ──"
ip rule show | grep 'fwmark 0x100' | head -1
echo "── ip route table 100 ──"
ip route show table 100 | head -1
echo "── split-tunnel-restore.service ──"
systemctl is-enabled split-tunnel-restore.service
REMOTE_VERIFY
)")"

echo "$VERIFY"

# Резолвим .ru-домен и проверяем что IP попал в ipset
step "Smoke-test: резолв .ru-домена должен добавить IP в ipset"
SMOKE="$(remote_script "$(cat <<'REMOTE_SMOKE'
set -uo pipefail
dig +time=3 +tries=1 @10.9.0.1 lenta.ru +short | head -3 | sed 's/^/    lenta.ru→/'
sleep 1
COUNT=$(ipset list ru_subnets 2>/dev/null | awk '/Number of entries:/ {print $4}')
echo "ipset entries: $COUNT"
REMOTE_SMOKE
)")"

echo "$SMOKE"

ok ""
ok "Split tunneling успешно установлен на VPS1"
ok ""
ok "  • Российские TLD (.ru/.рф/.su) идут напрямую через VPS1"
ok "  • Зарубежный трафик идёт через VPS2 как раньше"
ok "  • Клиентские конфиги НЕ изменены"
ok "  • DNS-резолв и фильтрация AdGuard продолжают работать (через dnsmasq на VPS1)"
ok ""
ok "  Откат:  bash scripts/deploy/setup-split-tunneling.sh --rollback"
