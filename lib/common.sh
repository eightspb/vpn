#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — общие утилиты для всех скриптов проекта
#
# Подключение:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/lib/common.sh"
#
# Предоставляет:
#   - Цвета и функции вывода (log, ok, err, warn, step)
#   - Парсинг конфигов (clean_value, read_kv, parse_kv)
#   - Загрузка дефолтов из .env / keys.env (load_defaults_from_files)
#   - Валидация обязательных переменных (require_vars)
#   - Работа с путями Windows/Linux (expand_tilde)
#   - SSH-хелперы (ssh_exec, ssh_upload, ssh_run_script)
#   - Авто-поиск SSH-ключа (auto_pick_key_if_missing)
#   - Копирование ключа из /mnt/ во временный файл (prepare_key_for_ssh)
#   - Очистка временных ключей (cleanup_temp_keys)
#   - Проверка зависимостей (check_deps)
#
# Переменные загружаются по приоритету:
#   1) CLI-аргументы (задаются в вызывающем скрипте до/после load_defaults_from_files)
#   2) .env (SSH-доступ, ADGUARD_PASS, CLIENT_IP)
#   3) vpn-output/keys.env (ключи, сети, порты после деплоя)
#   4) Встроенные дефолты
# =============================================================================

# ── Цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Функции вывода ────────────────────────────────────────────────────────────
log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
err()  { echo -e "  ${RED}✗ ОШИБКА:${NC} $*" >&2; exit 1; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
info() { echo -e "  ${CYAN}→${NC} $*"; }
step() { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

# ── SSH client bins (cross-platform override) ───────────────────────────────
SSH_BIN="${SSH_BIN:-ssh}"
SCP_BIN="${SCP_BIN:-scp}"
SSHPASS_BIN="${SSHPASS_BIN:-sshpass}"

# ── Парсинг значений ──────────────────────────────────────────────────────────

# Убирает \r, кавычки и пробелы по краям
clean_value() {
    local v="$1"
    v="${v//$'\r'/}"
    v="${v#\"}"; v="${v%\"}"
    v="${v#\'}"; v="${v%\'}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf "%s" "$v"
}

# Читает значение ключа из файла формата KEY=VALUE
read_kv() {
    local file="$1" key="$2" raw
    raw="$(awk -F= -v k="$key" '$1==k{sub(/^[^=]*=/,"",$0); print $0}' "$file" | tail -n 1)"
    clean_value "$raw"
}

# Читает значение ключа из строки данных формата KEY=VALUE
parse_kv() {
    local data="$1" key="$2"
    printf "%s\n" "$data" | awk -v k="$key" \
        'BEGIN{n=length(k)} substr($0,1,n+1)==k"=" {print substr($0,n+2); exit}'
}

# ── Определение корня проекта ─────────────────────────────────────────────────

# Находит корень проекта (директорию с .env и lib/common.sh)
_find_project_root() {
    local dir="${COMMON_SH_DIR:-}"
    if [[ -z "$dir" ]]; then
        dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
    # lib/common.sh лежит в <root>/lib/ — поднимаемся на уровень выше
    local root="${dir%/lib}"
    [[ "$root" == "$dir" ]] && root="$dir"
    printf "%s" "$root"
}

COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(_find_project_root)"

# ── Загрузка дефолтов из файлов ───────────────────────────────────────────────
# Заполняет переменные из .env и vpn-output/keys.env.
# Не перезаписывает переменные, которые уже имеют непустое значение
# (позволяет CLI-аргументам иметь приоритет).
#
# Загружает: VPS1_IP, VPS1_USER, VPS1_KEY, VPS1_PASS,
#            VPS2_IP, VPS2_USER, VPS2_KEY, VPS2_PASS,
#            ADGUARD_PASS, CLIENT_IP/CLIENT_VPN_IP,
#            TUN_NET, CLIENT_NET, VPS2_TUN_IP, VPS1_PORT_CLIENTS, VPS2_PORT
load_defaults_from_files() {
    local root="${PROJECT_ROOT:-.}"
    local env_file="${root}/.env"
    local keys_file="${root}/vpn-output/keys.env"

    # --- keys.env (ключи, сети, порты после деплоя) ---
    if [[ -f "$keys_file" ]]; then
        local k_val
        k_val="$(read_kv "$keys_file" VPS1_IP)"
        [[ -n "$k_val" && -z "${VPS1_IP:-}" ]] && VPS1_IP="$k_val"

        k_val="$(read_kv "$keys_file" TUN_NET)"
        if [[ -n "$k_val" ]]; then
            [[ -z "${TUN_NET:-}" ]]     && TUN_NET="$k_val"
            [[ -z "${VPS2_TUN_IP:-}" ]] && VPS2_TUN_IP="${k_val}.2"
        fi

        k_val="$(read_kv "$keys_file" CLIENT_NET)"
        [[ -n "$k_val" && -z "${CLIENT_NET:-}" ]] && CLIENT_NET="$k_val"

        k_val="$(read_kv "$keys_file" VPS1_PORT_CLIENTS)"
        [[ -n "$k_val" && -z "${VPS1_PORT_CLIENTS:-}" ]] && VPS1_PORT_CLIENTS="$k_val"

        k_val="$(read_kv "$keys_file" VPS2_PORT)"
        [[ -n "$k_val" && -z "${VPS2_PORT:-}" ]] && VPS2_PORT="$k_val"

        k_val="$(read_kv "$keys_file" CLIENT_VPN_IP)"
        [[ -n "$k_val" && -z "${CLIENT_VPN_IP:-}" ]] && CLIENT_VPN_IP="$k_val"
    fi

    # --- .env (SSH-доступ и дополнительные параметры) ---
    if [[ -f "$env_file" ]]; then
        local e_val

        e_val="$(read_kv "$env_file" VPS1_IP)"
        [[ -n "$e_val" && -z "${VPS1_IP:-}" ]]   && VPS1_IP="$e_val"
        e_val="$(read_kv "$env_file" VPS1_USER)"
        [[ -n "$e_val" && -z "${VPS1_USER:-}" ]]  && VPS1_USER="$e_val"
        e_val="$(read_kv "$env_file" VPS1_KEY)"
        [[ -n "$e_val" && -z "${VPS1_KEY:-}" ]]   && VPS1_KEY="$e_val"
        e_val="$(read_kv "$env_file" VPS1_PASS)"
        [[ -n "$e_val" && -z "${VPS1_PASS:-}" ]]  && VPS1_PASS="$e_val"

        e_val="$(read_kv "$env_file" VPS2_IP)"
        [[ -n "$e_val" && -z "${VPS2_IP:-}" ]]    && VPS2_IP="$e_val"
        e_val="$(read_kv "$env_file" VPS2_USER)"
        [[ -n "$e_val" && -z "${VPS2_USER:-}" ]]   && VPS2_USER="$e_val"
        e_val="$(read_kv "$env_file" VPS2_KEY)"
        [[ -n "$e_val" && -z "${VPS2_KEY:-}" ]]    && VPS2_KEY="$e_val"
        e_val="$(read_kv "$env_file" VPS2_PASS)"
        [[ -n "$e_val" && -z "${VPS2_PASS:-}" ]]   && VPS2_PASS="$e_val"

        e_val="$(read_kv "$env_file" ADGUARD_PASS)"
        [[ -n "$e_val" && -z "${ADGUARD_PASS:-}" ]] && ADGUARD_PASS="$e_val"
        e_val="$(read_kv "$env_file" CLIENT_IP)"
        [[ -n "$e_val" && -z "${CLIENT_VPN_IP:-}" ]] && CLIENT_VPN_IP="$e_val"
    fi
    return 0
}

# ── Валидация обязательных переменных ─────────────────────────────────────────
# Использование: require_vars "описание" VAR1 VAR2 ...
# Проверяет что все перечисленные переменные не пусты, иначе — err с подсказкой.
require_vars() {
    local context="$1"; shift
    local missing=()
    for var_name in "$@"; do
        local val="${!var_name:-}"
        [[ -z "$val" ]] && missing+=("$var_name")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "${context}: не заданы обязательные переменные: ${missing[*]}. Проверьте .env или передайте через CLI."
    fi
}

# ── Работа с путями ───────────────────────────────────────────────────────────

# Разворачивает ~ и конвертирует Windows-пути (C:\...) в /mnt/c/...
expand_tilde() {
    local p drive rest
    p="$(clean_value "$1")"
    # Нормализуем обратные слэши Windows
    p="${p//\\//}"
    # Конвертируем Windows-путь C:/... в /mnt/c/...
    if [[ "$p" =~ ^([A-Za-z]):/(.*)$ ]]; then
        drive="${BASH_REMATCH[1],,}"
        rest="${BASH_REMATCH[2]}"
        p="/mnt/${drive}/${rest}"
    fi
    # Разворачиваем ~/
    # Используем строковое сравнение через подстановку параметров (надёжнее [[ ]] с тильдой)
    local p_no_tilde="${p#\~/}"
    if [[ "$p_no_tilde" != "$p" ]]; then
        # Строка начиналась с ~/
        printf "%s" "${HOME}/${p_no_tilde}"
    elif [[ "$p" == "~" ]]; then
        printf "%s" "${HOME}"
    else
        local p_no_home_tilde="${p#${HOME}/\~/}"
        if [[ "$p_no_home_tilde" != "$p" ]]; then
            printf "%s" "${HOME}/${p_no_home_tilde}"
        elif [[ "$p" == .ssh/* || "$p" == ./.ssh/* ]]; then
            local proj_root
            proj_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
            printf "%s" "${proj_root}/${p}"
        else
            printf "%s" "$p"
        fi
    fi
}

# ── SSH-ключи ─────────────────────────────────────────────────────────────────

# Если ключ не задан или не найден — ищет стандартные ключи
auto_pick_key_if_missing() {
    local current_key="$1" win_home candidate
    win_home="${USERPROFILE:-}"; win_home="${win_home//\\//}"
    if [[ -n "$current_key" && -f "$current_key" ]]; then
        printf "%s" "$current_key"; return
    fi
    # Ищем ключи в .ssh/ папке проекта
    local project_ssh_dir
    project_ssh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/.ssh"
    if [[ -d "$project_ssh_dir" ]]; then
        for candidate in "$project_ssh_dir"/id_ed25519 "$project_ssh_dir"/id_rsa "$project_ssh_dir"/*; do
            [[ -f "$candidate" && ! "$candidate" =~ \.pub$ ]] && { printf "%s" "$candidate"; return; }
        done
    fi
    for candidate in "${HOME}/.ssh/id_ed25519" "${HOME}/.ssh/id_rsa" \
                     "${win_home}/.ssh/id_ed25519" "${win_home}/.ssh/id_rsa" \
                     /c/Users/*/.ssh/id_ed25519 /c/Users/*/.ssh/id_rsa \
                     /mnt/c/Users/*/.ssh/id_ed25519 /mnt/c/Users/*/.ssh/id_rsa; do
        [[ -f "$candidate" ]] && { printf "%s" "$candidate"; return; }
    done
    printf "%s" "$current_key"
}

# Глобальный список временных файлов ключей для очистки
COMMON_TEMP_KEY_FILES=()

# Если ключ находится в /mnt/... — копирует во временный файл с chmod 600
prepare_key_for_ssh() {
    local key="$1" tmp_key
    if [[ -z "$key" || ! -f "$key" ]]; then printf "%s" "$key"; return; fi
    # For Windows OpenSSH (ssh.exe), keep key path in Windows form.
    if [[ "${SSH_BIN:-ssh}" == *"ssh.exe" ]]; then
        if [[ "$key" =~ ^/mnt/([A-Za-z])/(.*)$ ]]; then
            local drive="${BASH_REMATCH[1]}"
            local rest="${BASH_REMATCH[2]}"
            printf "%s:/%s" "${drive^^}" "${rest}"
            return
        fi
        if [[ "$key" =~ ^/([A-Za-z])/(.*)$ ]]; then
            local drive2="${BASH_REMATCH[1]}"
            local rest2="${BASH_REMATCH[2]}"
            printf "%s:/%s" "${drive2^^}" "${rest2}"
            return
        fi
        printf "%s" "$key"
        return
    fi
    if [[ "$key" == /mnt/* ]]; then
        tmp_key="$(umask 077; mktemp /tmp/vpn_key_XXXXXX)" || { printf "%s" "$key"; return; }
        [[ -z "$tmp_key" ]] && { printf "%s" "$key"; return; }
        cp "$key" "$tmp_key" 2>/dev/null || { rm -f "$tmp_key"; printf "%s" "$key"; return; }
        chmod 600 "$tmp_key" 2>/dev/null || true
        COMMON_TEMP_KEY_FILES+=("$tmp_key")
        printf "%s" "$tmp_key"; return
    fi
    printf "%s" "$key"
}

# Удаляет все временные файлы ключей
cleanup_temp_keys() {
    local f
    for f in "${COMMON_TEMP_KEY_FILES[@]+"${COMMON_TEMP_KEY_FILES[@]}"}"; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f"
    done
}

_path_for_native_ssh() {
    local p="$1"
    if command -v cygpath >/dev/null 2>&1; then
        local win
        win="$(cygpath -w "$p" 2>/dev/null || true)"
        if [[ -n "$win" ]]; then
            win="${win//\\//}"
            printf "%s" "$win"
            return
        fi
    fi
    if [[ "$p" =~ ^/mnt/([A-Za-z])/(.*)$ ]]; then
        local drive="${BASH_REMATCH[1]}"
        local rest="${BASH_REMATCH[2]}"
        printf "%s:/%s" "${drive^^}" "${rest}"
        return
    fi
    if [[ "$p" =~ ^/([A-Za-z])/(.*)$ ]]; then
        local drive2="${BASH_REMATCH[1]}"
        local rest2="${BASH_REMATCH[2]}"
        printf "%s:/%s" "${drive2^^}" "${rest2}"
        return
    fi
    printf "%s" "$p"
}

# ── SSH-хелперы ───────────────────────────────────────────────────────────────

# Выполняет команду на удалённом сервере через SSH
# Использование: ssh_exec <ip> <user> <key> <pass> <cmd> [timeout]
ssh_exec() {
    local ip="$1" user="$2" key="$3" pass="$4" cmd="$5"
    local timeout="${6:-30}"
    local ssh_opts=(-o StrictHostKeyChecking=accept-new
                    -o BatchMode=no -o ConnectTimeout="$timeout")
    ip="$(clean_value "$ip")"
    user="$(clean_value "$user")"
    key="$(expand_tilde "$key")"
    pass="$(clean_value "$pass")"

    if [[ -n "$key" && -f "$key" ]]; then
        timeout "$timeout" "$SSH_BIN" "${ssh_opts[@]}" -i "$key" "${user}@${ip}" "$cmd"
    elif [[ -n "$pass" ]]; then
        timeout "$timeout" "$SSHPASS_BIN" -p "$pass" "$SSH_BIN" "${ssh_opts[@]}" "${user}@${ip}" "$cmd"
    else
        timeout "$timeout" "$SSH_BIN" "${ssh_opts[@]}" "${user}@${ip}" "$cmd"
    fi
}

# Загружает файл на удалённый сервер через SCP
# Использование: ssh_upload <local_file> <ip> <user> <key> <pass> [remote_dst]
ssh_upload() {
    local local_file="$1" ip="$2" user="$3" key="$4" pass="$5"
    local dst="${6:-/tmp/$(basename "$local_file")}"
    local scp_opts=(-o StrictHostKeyChecking=accept-new)
    local src="$local_file"
    key="$(expand_tilde "$key")"
    if [[ "$SCP_BIN" == *".exe" ]]; then
        src="$(_path_for_native_ssh "$local_file")"
    fi

    if [[ -n "$key" && -f "$key" ]]; then
        "$SCP_BIN" "${scp_opts[@]}" -i "$key" "$src" "${user}@${ip}:${dst}"
    elif [[ -n "$pass" ]]; then
        "$SSHPASS_BIN" -p "$pass" "$SCP_BIN" "${scp_opts[@]}" "$src" "${user}@${ip}:${dst}"
    else
        "$SCP_BIN" "${scp_opts[@]}" "$src" "${user}@${ip}:${dst}"
    fi
}

# Загружает скрипт во временный файл и выполняет его через sudo bash на сервере
# Использование: ssh_run_script <ip> <user> <key> <pass> <script_content>
ssh_run_script() {
    local ip="$1" user="$2" key="$3" pass="$4" script="$5"
    local tmp
    tmp="$(mktemp /tmp/vpn_deploy_XXXX.sh)"
    printf "%s" "$script" > "$tmp"
    ssh_upload "$tmp" "$ip" "$user" "$key" "$pass" /tmp/_vpn_step.sh
    rm -f "$tmp"
    ssh_exec "$ip" "$user" "$key" "$pass" "sudo bash /tmp/_vpn_step.sh"
}

# ── AmneziaVPN конфиг-генерация ───────────────────────────────────────────────

# Возвращает доступную команду Python (python3 или python)
_find_python() {
    if command -v python3 &>/dev/null; then echo "python3"
    elif command -v python &>/dev/null; then echo "python"
    else echo ""; fi
}

# Генерирует нативный JSON-конфиг AmneziaVPN (amnezia-awg формат).
# Параметры (позиционные):
#   1  out_file     — путь к выходному .json файлу
#   2  priv_key     — приватный ключ клиента
#   3  client_addr  — IP клиента с маской (например: 10.9.0.3/24)
#   4  mtu          — MTU (например: 1280)
#   5  allowed_ips  — AllowedIPs (например: 0.0.0.0/0)
#   6  server_pub   — публичный ключ сервера
#   7  endpoint     — endpoint сервера (host:port)
#   8  host_ip      — IP сервера (для поля hostName)
#   9  port         — порт сервера
#   10 dns          — DNS-адрес клиента
#   11-19           — Jc Jmin Jmax S1 S2 H1 H2 H3 H4
#   20 description  — имя профиля
amnezia_write_json() {
    local out_file="$1"  priv_key="$2"  client_addr="$3" mtu="$4"
    local allowed_ips="$5" server_pub="$6" endpoint="$7" host_ip="$8"
    local port="${9}"      dns="${10}"
    local jc="${11}"       jmin="${12}"     jmax="${13}"
    local s1="${14}"       s2="${15}"
    local h1="${16}"       h2="${17}"       h3="${18}"      h4="${19}"
    local description="${20:-VPN}"

    local _py; _py="$(_find_python)"
    [[ -z "$_py" ]] && { warn "python/python3 не найден — AmneziaVPN JSON не сгенерирован"; return 1; }

    OUT="$out_file" PRIV="$priv_key" ADDR="$client_addr" MTU_V="$mtu" \
    ALLOWED="$allowed_ips" SPUB="$server_pub" EP="$endpoint" \
    HOST="$host_ip" PORT_V="$port" DNS_V="$dns" \
    JC="$jc" JMIN="$jmin" JMAX="$jmax" S1V="$s1" S2V="$s2" \
    H1V="$h1" H2V="$h2" H3V="$h3" H4V="$h4" DESC="$description" \
    "$_py" - << 'AMNEZIA_PY'
import json, os
e = os.environ
last_config = (
    "[Interface]\n"
    f"Address = {e['ADDR']}\n"
    f"DNS = {e['DNS_V']}\n"
    f"PrivateKey = {e['PRIV']}\n"
    f"MTU = {e['MTU_V']}\n"
    "\n[Peer]\n"
    f"PublicKey = {e['SPUB']}\n"
    f"AllowedIPs = {e['ALLOWED']}\n"
    "PersistentKeepalive = 25\n"
    f"Endpoint = {e['EP']}\n"
)
cfg = {
    "containers": [{
        "awg": {
            "H1": e["H1V"], "H2": e["H2V"], "H3": e["H3V"], "H4": e["H4V"],
            "Jc": e["JC"], "Jmax": e["JMAX"], "Jmin": e["JMIN"],
            "S1": e["S1V"], "S2": e["S2V"],
            "last_config": last_config,
            "port": e["PORT_V"],
            "transport_proto": "udp"
        },
        "container": "amnezia-awg"
    }],
    "defaultContainer": "amnezia-awg",
    "description": e["DESC"],
    "dns1": e["DNS_V"],
    "dns2": "8.8.8.8",
    "hostName": e["HOST"]
}
with open(e["OUT"], "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
AMNEZIA_PY
}

# Выводит QR-код AmneziaVPN в терминале (формат vpn://base64).
# $1 — путь к .json файлу конфига
amnezia_qr_show() {
    local json_file="$1"
    [[ -f "$json_file" ]] || { warn "JSON не найден: $json_file"; return 1; }
    local _py; _py="$(_find_python)"
    [[ -z "$_py" ]] && { warn "python/python3 не найден — QR недоступен"; return 1; }
    local share_url
    share_url=$("$_py" -c "
import base64, sys
data = open(sys.argv[1]).read()
sys.stdout.write('vpn://' + base64.b64encode(data.encode()).decode())
" "$json_file")
    if command -v qrencode &>/dev/null; then
        printf "%s" "$share_url" | qrencode -t ANSIUTF8
    else
        "$_py" -c "
import base64, sys
try:
    import qrcode
    data = open(sys.argv[1]).read()
    url = 'vpn://' + base64.b64encode(data.encode()).decode()
    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_L)
    qr.add_data(url)
    qr.make(fit=True)
    qr.print_ascii(invert=True)
except ImportError:
    print('Для QR установите: pip install qrcode[pil] или sudo apt install qrencode')
    sys.exit(1)
" "$json_file"
    fi
}

# Сохраняет QR-код AmneziaVPN как PNG.
# $1 — путь к .json файлу конфига, $2 — путь к PNG
amnezia_qr_save_png() {
    local json_file="$1" png_file="$2"
    [[ -f "$json_file" ]] || { warn "JSON не найден: $json_file"; return 1; }
    local _py; _py="$(_find_python)"
    [[ -z "$_py" ]] && { warn "python/python3 не найден — QR недоступен"; return 1; }
    local share_url
    share_url=$("$_py" -c "
import base64, sys
data = open(sys.argv[1]).read()
sys.stdout.write('vpn://' + base64.b64encode(data.encode()).decode())
" "$json_file")
    if command -v qrencode &>/dev/null; then
        printf "%s" "$share_url" | qrencode -t PNG -o "$png_file" -s 6
    else
        "$_py" -c "
import base64, sys
try:
    import qrcode
    data = open(sys.argv[1]).read()
    url = 'vpn://' + base64.b64encode(data.encode()).decode()
    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_L, box_size=6, border=2)
    qr.add_data(url)
    qr.make(fit=True)
    img = qr.make_image(fill_color='black', back_color='white')
    img.save(sys.argv[2])
except ImportError:
    print('Для QR PNG установите: pip install qrcode[pil]')
    sys.exit(1)
" "$json_file" "$png_file"
    fi
}

# ── Проверка зависимостей ─────────────────────────────────────────────────────

# Проверяет наличие нужных утилит. Принимает список через пространство.
# Дополнительно: если передан флаг --need-sshpass, проверяет sshpass.
# Использование: check_deps [--need-sshpass] [extra_cmd ...]
check_deps() {
    local missing=()
    local need_sshpass=false
    local args=("$@")
    local filtered=()

    for a in "${args[@]+"${args[@]}"}"; do
        if [[ "$a" == "--need-sshpass" ]]; then
            need_sshpass=true
        else
            filtered+=("$a")
        fi
    done

    for cmd in "$SSH_BIN" "$SCP_BIN" awk "${filtered[@]+"${filtered[@]}"}"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ "$need_sshpass" == "true" ]]; then
        command -v "$SSHPASS_BIN" &>/dev/null || missing+=("$SSHPASS_BIN")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Не найдены утилиты: ${missing[*]}"
    fi
}
