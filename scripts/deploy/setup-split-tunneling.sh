#!/usr/bin/env bash
# =============================================================================
# setup-split-tunneling.sh — устанавливает и включает split tunneling на VPS1
#
# Что делает:
#   1. Устанавливает dnsmasq и ipset на VPS1 (apt)
#   2. Раскладывает конфиги: /etc/dnsmasq.d/vpn.conf, systemd drop-in,
#      /usr/local/sbin/split-tunnel-{apply,rollback}.sh,
#      /etc/systemd/system/split-tunnel-restore.service
#   3. Генерирует dnsmasq rules из v2fly category-ru (+ локальный Ozon seed)
#   4. Бэкапит /etc/dnsmasq.conf, заменяет минимальным conf-dir-only
#   5. Запускает dnsmasq, healthcheck
#   6. Запускает split-tunnel-apply.sh (zero-downtime переключение)
#   7. Включает split-tunnel-restore.service для автостарта после ребута
#
# Использование:
#   bash scripts/deploy/setup-split-tunneling.sh [--vps1-ip IP] [--vps1-key KEY]
#   bash scripts/deploy/setup-split-tunneling.sh --dry-run     # pre-flight only
#   bash scripts/deploy/setup-split-tunneling.sh --rollback    # полный откат
#   bash scripts/deploy/setup-split-tunneling.sh --guard-timeout 300
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
GUARD_TIMEOUT=300
WATCHDOG_UNIT="split-tunnel-auto-rollback"
GENERATED_RU_DOMAINS_CONF=""

load_defaults_from_files

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps1-ip)   VPS1_IP="$2";   shift 2 ;;
        --vps1-user) VPS1_USER="$2"; shift 2 ;;
        --vps1-key)  VPS1_KEY="$2";  shift 2 ;;
        --vps1-pass) VPS1_PASS="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=1;      shift ;;
        --rollback)  DO_ROLLBACK=1;  shift ;;
        --guard-timeout) GUARD_TIMEOUT="$2"; shift 2 ;;
        --help|-h)
            cat <<EOF
Usage: bash $0 [options]

  --vps1-ip IP        IP VPS1 (из .env, если не задан)
  --vps1-user USER    SSH-пользователь
  --vps1-key KEY      путь к SSH-ключу
  --vps1-pass PASS    SSH-пароль
  --dry-run           проверить готовность, ничего не менять
  --rollback          полный откат (вернуть состояние ДО split tunneling)
  --guard-timeout SEC  автооткат через SEC секунд, если canary не прошли (default: 300)
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

[[ "$GUARD_TIMEOUT" =~ ^[0-9]+$ ]] || err "--guard-timeout должен быть числом секунд"
[[ "$GUARD_TIMEOUT" -ge 60 ]] || err "--guard-timeout должен быть >= 60 секунд"

VPS1_KEY="$(expand_tilde "$VPS1_KEY")"
VPS1_KEY="$(auto_pick_key_if_missing "$VPS1_KEY")"
VPS1_KEY="$(prepare_key_for_ssh "$VPS1_KEY")"

require_vars "setup-split-tunneling.sh" VPS1_IP
[[ -z "$VPS1_KEY" && -z "$VPS1_PASS" ]] && err "Укажите --vps1-key или --vps1-pass (или VPS1_KEY в .env)"

cleanup() {
    cleanup_temp_keys
    if [[ -n "${GENERATED_RU_DOMAINS_CONF:-}" ]]; then
        rm -f "$GENERATED_RU_DOMAINS_CONF"
    fi
    return 0
}

trap cleanup EXIT

# Локальные обёртки чтобы не передавать одну и ту же четвёрку кредов в каждый
# вызов. Вызываются ниже после require_vars/key checks.
remote()        { ssh_exec        "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS" "$@"; }
remote_script() { ssh_run_script  "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS" "$1"; }
upload()        { ssh_upload "$1" "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS" "$2"; }

GUARD_ACTIVE=0

schedule_watchdog() {
    step "Постановка watchdog rollback (${GUARD_TIMEOUT}s)"
    remote "sudo systemctl stop ${WATCHDOG_UNIT}.timer 2>/dev/null || true; \
sudo systemctl reset-failed ${WATCHDOG_UNIT}.timer ${WATCHDOG_UNIT}.service 2>/dev/null || true; \
sudo systemd-run --unit=${WATCHDOG_UNIT} --on-active=${GUARD_TIMEOUT} --description='Auto rollback split tunneling if setup canary fails' /usr/local/sbin/split-tunnel-rollback.sh >/dev/null"
    GUARD_ACTIVE=1
    ok "Watchdog активен: ${WATCHDOG_UNIT}.timer"
}

cancel_watchdog() {
    [[ "$GUARD_ACTIVE" == "1" ]] || return 0
    step "Отмена watchdog rollback"
    remote "sudo systemctl stop ${WATCHDOG_UNIT}.timer 2>/dev/null || true; \
sudo systemctl reset-failed ${WATCHDOG_UNIT}.timer ${WATCHDOG_UNIT}.service 2>/dev/null || true; \
if sudo systemctl is-active --quiet ${WATCHDOG_UNIT}.timer 2>/dev/null; then exit 1; fi" \
        || fail_guarded "Не удалось отменить watchdog rollback; состояние небезопасно"
    GUARD_ACTIVE=0
    ok "Watchdog отменён"
}

rollback_now() {
    warn "Запускаю немедленный rollback split tunneling на VPS1..."
    remote "sudo bash /usr/local/sbin/split-tunnel-rollback.sh" || true
}

fail_guarded() {
    local msg="$1"
    if [[ "$GUARD_ACTIVE" == "1" ]]; then
        rollback_now
    fi
    err "$msg"
}

# ── Проверка наличия артефактов локально ────────────────────────────────────
for f in dnsmasq-vpn.conf dnsmasq.service.d/override.conf \
         split-tunnel-apply.sh split-tunnel-rollback.sh split-tunnel-restore.service \
         split-tunnel-update-ru-domains.sh ru-domain-seed.txt; do
    [[ -f "${ARTIFACTS_DIR}/${f}" ]] || err "Артефакт не найден: ${ARTIFACTS_DIR}/${f}"
done
ok "Артефакты найдены в ${ARTIFACTS_DIR}"

# ── Rollback mode ───────────────────────────────────────────────────────────
if [[ "$DO_ROLLBACK" == "1" ]]; then
    rollback_script="${SCRIPT_DIR}/rollback-split-tunneling.sh"
    [[ -f "$rollback_script" ]] || err "Не найден аварийный rollback script: $rollback_script"
    rollback_args=(--vps1-ip "$VPS1_IP" --vps1-user "$VPS1_USER")
    [[ -n "$VPS1_KEY" ]] && rollback_args+=(--vps1-key "$VPS1_KEY")
    [[ -n "$VPS1_PASS" ]] && rollback_args+=(--vps1-pass "$VPS1_PASS")
    bash "$rollback_script" "${rollback_args[@]}"
    exit $?
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

# ── 0. Локальная генерация RU domain rules ─────────────────────────────────
# Делаем это до любых изменений на VPS1. Так remote deploy step остаётся
# коротким и не упирается в 30s timeout ssh_run_script.
step "Локальная генерация RU domain rules (category-ru + seed)"

GENERATED_RU_DOMAINS_CONF="$(mktemp /tmp/vpn-ru-domains.XXXXXX.conf)"
RU_DOMAINS_CACHE_DIR="${TMPDIR:-/tmp}/vpn-split-domain-list-cache" \
    bash "${ARTIFACTS_DIR}/split-tunnel-update-ru-domains.sh" \
        --dry-run \
        --seed-file "${ARTIFACTS_DIR}/ru-domain-seed.txt" \
        > "$GENERATED_RU_DOMAINS_CONF"

grep -q '^ipset=/ozon\.com/ru_subnets$' "$GENERATED_RU_DOMAINS_CONF" \
    || err "Generated RU rules missing ozon.com"
grep -q '^ipset=/gosuslugi\.ru/ru_subnets$' "$GENERATED_RU_DOMAINS_CONF" \
    || err "Generated RU rules missing gosuslugi.ru"
RULE_COUNT="$(grep -c '^ipset=/' "$GENERATED_RU_DOMAINS_CONF" || true)"
[[ "$RULE_COUNT" =~ ^[0-9]+$ && "$RULE_COUNT" -gt 0 ]] \
    || err "Generated RU rules are empty"
ok "Generated RU domain rules: ${RULE_COUNT} ipset directives"

# ── 0. Ранняя установка rollback-скрипта ───────────────────────────────────
step "Ранняя установка rollback-скрипта на VPS1"

upload "${ARTIFACTS_DIR}/split-tunnel-rollback.sh" /tmp/_st_rollback.sh
remote_script "$(cat <<'REMOTE_ROLLBACK_INSTALL'
set -euo pipefail
install -m 755 /tmp/_st_rollback.sh /usr/local/sbin/split-tunnel-rollback.sh
rm -f /tmp/_st_rollback.sh
echo "[ok] /usr/local/sbin/split-tunnel-rollback.sh installed"
REMOTE_ROLLBACK_INSTALL
)"
ok "Rollback-скрипт установлен до изменения DNS/маршрутов"

# ── 0a. Pre-state snapshot ─────────────────────────────────────────────────
step "Snapshot текущего состояния VPS1"

PRE_STATE="$(remote "
    set +e
    echo '── services ──'
    systemctl is-active awg-quick@awg0 awg-quick@awg1 dnsmasq split-tunnel-restore.service 2>/dev/null
    echo '── ip rule ──'
    ip rule show
    echo '── table 100 ──'
    ip route show table 100 2>/dev/null
    echo '── table 200 ──'
    ip route show table 200 2>/dev/null
    echo '── DNS DNAT ──'
    sudo iptables -t nat -S PREROUTING | grep -E -- '--dport 53' || true
    echo '── FORWARD split candidates ──'
    sudo iptables -S FORWARD | grep -E 'awg1|mark' || true
    echo '── ipset ru_subnets ──'
    sudo ipset list ru_subnets 2>/dev/null | head -8 || true
")"
echo "$PRE_STATE"

# ── 1. Установка пакетов ────────────────────────────────────────────────────
step "Установка dnsmasq и ipset"

remote_script "$(cat <<'REMOTE_INSTALL'
set -euo pipefail

# Маска защищает от auto-start dnsmasq на :53 во время apt install
# (до того, как мы положим bind-dynamic конфиг). Снимется в следующем шаге.
systemctl mask dnsmasq 2>/dev/null || true

DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsmasq ipset dnsutils curl ca-certificates >/dev/null

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
upload "${ARTIFACTS_DIR}/split-tunnel-update-ru-domains.sh" /tmp/_st_update_ru_domains.sh
upload "${ARTIFACTS_DIR}/split-tunnel-restore.service"      /tmp/_st_restore.service
upload "${ARTIFACTS_DIR}/ru-domain-seed.txt"                /tmp/_st_ru_domain_seed.txt
upload "$GENERATED_RU_DOMAINS_CONF"                         /tmp/_st_vpn_ru_domains.conf
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

# dnsmasq стартует с директивой ipset=.../ru_subnets, поэтому set должен
# существовать ДО запуска сервиса.
if ! ipset list ru_subnets >/dev/null 2>&1; then
    ipset create ru_subnets hash:ip family inet hashsize 4096 maxelem 131072 timeout 604800
    echo "[ok] ipset ru_subnets создан до запуска dnsmasq"
else
    echo "[info] ipset ru_subnets уже существует"
fi

# systemd drop-in для dnsmasq (зависимость от awg-quick@awg1)
mkdir -p /etc/systemd/system/dnsmasq.service.d
install -m 644 /tmp/_st_dnsmasq-override.conf /etc/systemd/system/dnsmasq.service.d/override.conf

# Скрипты split-tunnel-apply / rollback
install -m 755 /tmp/_st_apply.sh    /usr/local/sbin/split-tunnel-apply.sh
install -m 755 /tmp/_st_rollback.sh /usr/local/sbin/split-tunnel-rollback.sh
install -m 755 /tmp/_st_update_ru_domains.sh /usr/local/sbin/split-tunnel-update-ru-domains.sh

# Локальный fallback для российских доменов с не-.ru TLD (например Ozon).
mkdir -p /usr/local/share/split-tunneling
install -m 644 /tmp/_st_ru_domain_seed.txt /usr/local/share/split-tunneling/ru-domain-seed.txt

# Расширенный список RU-доменов генерируется локально до SSH-мутаций и
# загружается готовым файлом, чтобы remote deploy step был коротким.
install -m 644 /tmp/_st_vpn_ru_domains.conf /etc/dnsmasq.d/vpn-ru-domains.conf
grep -q '^ipset=/ozon\.com/ru_subnets$' /etc/dnsmasq.d/vpn-ru-domains.conf
grep -q '^ipset=/gosuslugi\.ru/ru_subnets$' /etc/dnsmasq.d/vpn-ru-domains.conf
echo "[ok] RU domain rules installed (category-ru + local seed)"

# systemd-юнит для автостарта после ребута
install -m 644 /tmp/_st_restore.service /etc/systemd/system/split-tunnel-restore.service

# Очистка temp
rm -f /tmp/_st_*.sh /tmp/_st_*.conf /tmp/_st_*.service /tmp/_st_*.txt

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

# ── 3.5. Watchdog rollback перед переключением DNS DNAT ─────────────────────
schedule_watchdog || err "Не удалось поставить watchdog rollback — split tunneling не применялся"

# ── 4. Запуск split-tunnel-apply.sh (zero-downtime переключение) ────────────
step "Применение split tunneling (zero-downtime через CONNMARK)"

remote "sudo bash /usr/local/sbin/split-tunnel-apply.sh" \
    || fail_guarded "split-tunnel-apply.sh завершился с ошибкой"
ok "Split tunneling включён"

# ── 5. Включение автостарта split-tunnel-restore ────────────────────────────
step "Включение автостарта после ребута"

remote "sudo systemctl enable split-tunnel-restore.service >/dev/null" \
    || fail_guarded "Не удалось включить split-tunnel-restore.service"
ok "split-tunnel-restore.service enabled"

# ── 6. Финальная верификация ────────────────────────────────────────────────
step "Финальная верификация"

if ! VERIFY="$(remote_script "$(cat <<'REMOTE_VERIFY'
set -uo pipefail
echo "── dnsmasq ──"
systemctl is-active dnsmasq
ss -lnup 2>/dev/null | grep ':53.*dnsmasq' | head -1
echo "── ipset ──"
ipset list ru_subnets 2>/dev/null | grep 'Number of entries'
echo "── RU domain rules ──"
grep -E '^ipset=/ozon\.com/ru_subnets$' /etc/dnsmasq.d/vpn-ru-domains.conf
echo "── iptables mangle ──"
iptables -t mangle -S PREROUTING | grep awg1 | wc -l
echo "── iptables nat (DNS DNAT) ──"
iptables -t nat -S PREROUTING | grep -E 'dport 53' | sed 's/^/   /'
echo "── ip rule fwmark ──"
ip rule show | grep 'fwmark 0x100' | head -1
echo "── ip rule DNS replies ──"
ip rule show | grep 'from 10.9.0.1 to 10.9.0.0/24 lookup main' | head -1
echo "── ip route table 100 ──"
ip route show table 100 | head -1
echo "── split-tunnel-restore.service ──"
systemctl is-enabled split-tunnel-restore.service
REMOTE_VERIFY
)")"; then
    fail_guarded "Финальная удалённая верификация не прошла"
fi

echo "$VERIFY"

step "Local canary: DNS через текущий VPN"
if ! command -v dig >/dev/null 2>&1; then
    warn "Локальная команда dig не найдена — пропускаю локальный DNS canary"
else
    dig +time=3 +tries=1 @10.8.0.2 google.com +short | grep -E '^[0-9]+\.' >/dev/null \
        || warn "Local canary: google.com не резолвится через 10.8.0.2 с управляющего компьютера (возможно, вы не в этом VPN)"
    dig +time=3 +tries=1 @10.8.0.2 lenta.ru +short | grep -E '^[0-9]+\.' >/dev/null \
        || warn "Local canary: lenta.ru не резолвится через 10.8.0.2 с управляющего компьютера (возможно, вы не в этом VPN)"
    dig +time=3 +tries=1 @10.8.0.2 ozon.com +short | grep -E '^[0-9]+\.' >/dev/null \
        || warn "Local canary: ozon.com не резолвится через 10.8.0.2 с управляющего компьютера (возможно, вы не в этом VPN)"
fi
ok "Local DNS canary не блокирует deploy; критическая проверка выполняется remote canary"

step "Remote canary: ipset + route mark + firewall"
if ! SMOKE="$(remote_script "$(cat <<'REMOTE_SMOKE'
set -uo pipefail
CLIENT_NET="${CLIENT_NET:-10.9.0}"
DNSMASQ_IP="${CLIENT_NET}.1"
TUN_NET="${TUN_NET:-10.8.0}"
VPS2_DNS_IP="${TUN_NET}.2"
CLIENT_CIDR="${CLIENT_NET}.0/24"
MARK_HEX="${MARK_HEX:-0x100}"
IPSET_NAME="${IPSET_NAME:-ru_subnets}"
MAIN_IF="$(ip route show default | awk '/^default/ {print $5; exit}')"
RU_IP="$(dig +time=3 +tries=1 @"${DNSMASQ_IP}" lenta.ru +short | grep -E '^[0-9]+\.' | head -1)"
[[ -n "$RU_IP" ]] || { echo "no RU_IP from dnsmasq"; exit 10; }
echo "lenta.ru→${RU_IP}"
OZON_IP="$(dig +time=3 +tries=1 @"${DNSMASQ_IP}" ozon.com +short | grep -E '^[0-9]+\.' | head -1)"
[[ -n "$OZON_IP" ]] || { echo "no OZON_IP from dnsmasq"; exit 21; }
echo "ozon.com→${OZON_IP}"
sleep 1
COUNT=$(ipset list "$IPSET_NAME" 2>/dev/null | awk '/Number of entries:/ {print $4}')
echo "ipset entries: $COUNT"
[[ "$COUNT" =~ ^[0-9]+$ && "$COUNT" -gt 0 ]] || { echo "ipset is empty"; exit 11; }
ipset test "$IPSET_NAME" "$OZON_IP" >/dev/null 2>&1 || { echo "ozon.com IP was not added to $IPSET_NAME"; exit 22; }
PEER_IP="$(awg show awg1 allowed-ips 2>/dev/null | awk '$2 ~ /^10\.9\./ {print $2; exit}' | cut -d/ -f1)"
[[ -n "$PEER_IP" ]] || PEER_IP="${CLIENT_NET}.2"
ROUTE="$(ip route get "$RU_IP" mark "$MARK_HEX" from "$PEER_IP" iif awg1 2>&1 || true)"
echo "route: $ROUTE"
echo "$ROUTE" | grep -q " dev ${MAIN_IF}" || { echo "marked route does not use ${MAIN_IF}"; exit 12; }
OZON_ROUTE="$(ip route get "$OZON_IP" mark "$MARK_HEX" from "$PEER_IP" iif awg1 2>&1 || true)"
echo "ozon route: $OZON_ROUTE"
echo "$OZON_ROUTE" | grep -q " dev ${MAIN_IF}" || { echo "marked ozon route does not use ${MAIN_IF}"; exit 23; }
DNS_REPLY_ROUTE="$(ip route get "$PEER_IP" from "$DNSMASQ_IP" 2>&1 || true)"
echo "dns reply route: $DNS_REPLY_ROUTE"
echo "$DNS_REPLY_ROUTE" | grep -q " dev awg1" || { echo "dns reply route does not use awg1"; exit 13; }
iptables -C FORWARD -i awg1 -o "$MAIN_IF" -m mark --mark "$MARK_HEX" -j ACCEPT 2>/dev/null \
  || { echo "missing marked FORWARD awg1→${MAIN_IF}"; exit 14; }
iptables -t nat -C PREROUTING -i awg1 -p udp --dport 53 -j DNAT --to-destination "${DNSMASQ_IP}:53" 2>/dev/null \
  || { echo "missing UDP DNS DNAT to ${DNSMASQ_IP}:53"; exit 15; }
iptables -t nat -C PREROUTING -i awg1 -p tcp --dport 53 -j DNAT --to-destination "${DNSMASQ_IP}:53" 2>/dev/null \
  || { echo "missing TCP DNS DNAT to ${DNSMASQ_IP}:53"; exit 16; }
iptables -t nat -C POSTROUTING -o awg1 -s "${DNSMASQ_IP}/32" -d "${CLIENT_CIDR}" -p udp --sport 53 -j SNAT --to-source "${VPS2_DNS_IP}" 2>/dev/null \
  || { echo "missing UDP DNS reply SNAT to ${VPS2_DNS_IP}"; exit 17; }
iptables -t nat -C POSTROUTING -o awg1 -s "${DNSMASQ_IP}/32" -d "${CLIENT_CIDR}" -p tcp --sport 53 -j SNAT --to-source "${VPS2_DNS_IP}" 2>/dev/null \
  || { echo "missing TCP DNS reply SNAT to ${VPS2_DNS_IP}"; exit 18; }
iptables -C INPUT -i awg1 -d "${DNSMASQ_IP}" -p udp --dport 53 -j ACCEPT 2>/dev/null \
  || { echo "missing UDP DNS INPUT allow to ${DNSMASQ_IP}:53"; exit 19; }
iptables -C INPUT -i awg1 -d "${DNSMASQ_IP}" -p tcp --dport 53 -j ACCEPT 2>/dev/null \
  || { echo "missing TCP DNS INPUT allow to ${DNSMASQ_IP}:53"; exit 20; }
REMOTE_SMOKE
)")"; then
    echo "${SMOKE:-}"
    fail_guarded "Remote canary failed"
fi

echo "$SMOKE"

cancel_watchdog

ok ""
ok "Split tunneling успешно установлен на VPS1"
ok ""
ok "  • Российские TLD и домены category-ru (включая Ozon) идут напрямую через VPS1"
ok "  • Зарубежный трафик идёт через VPS2 как раньше"
ok "  • Клиентские конфиги НЕ изменены"
ok "  • DNS-резолв через VPS2 upstream 10.8.0.2:53 продолжает работать (через dnsmasq на VPS1)"
ok ""
ok "  Откат:  bash scripts/deploy/setup-split-tunneling.sh --rollback"
