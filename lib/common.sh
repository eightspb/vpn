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
ok()   { echo -e "${GREEN}✓${NC} $*"; }
err()  { echo -e "${RED}✗ ОШИБКА:${NC} $*" >&2; exit 1; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
step() { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

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
            # Артефакт двойного разворачивания — убираем лишний ~/
            printf "%s" "${HOME}/${p_no_home_tilde}"
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
    if [[ "$key" == /mnt/* ]]; then
        tmp_key="$(mktemp /tmp/vpn_key_XXXXXX)" || { printf "%s" "$key"; return; }
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
        timeout "$timeout" ssh "${ssh_opts[@]}" -i "$key" "${user}@${ip}" "$cmd"
    elif [[ -n "$pass" ]]; then
        timeout "$timeout" sshpass -p "$pass" ssh "${ssh_opts[@]}" "${user}@${ip}" "$cmd"
    else
        timeout "$timeout" ssh "${ssh_opts[@]}" "${user}@${ip}" "$cmd"
    fi
}

# Загружает файл на удалённый сервер через SCP
# Использование: ssh_upload <local_file> <ip> <user> <key> <pass> [remote_dst]
ssh_upload() {
    local local_file="$1" ip="$2" user="$3" key="$4" pass="$5"
    local dst="${6:-/tmp/$(basename "$local_file")}"
    local scp_opts=(-o StrictHostKeyChecking=accept-new)
    key="$(expand_tilde "$key")"

    if [[ -n "$key" && -f "$key" ]]; then
        scp "${scp_opts[@]}" -i "$key" "$local_file" "${user}@${ip}:${dst}"
    elif [[ -n "$pass" ]]; then
        sshpass -p "$pass" scp "${scp_opts[@]}" "$local_file" "${user}@${ip}:${dst}"
    else
        scp "${scp_opts[@]}" "$local_file" "${user}@${ip}:${dst}"
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

    for cmd in ssh scp awk "${filtered[@]+"${filtered[@]}"}"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ "$need_sshpass" == "true" ]]; then
        command -v sshpass &>/dev/null || missing+=("sshpass")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Не найдены утилиты: ${missing[*]}"
    fi
}
