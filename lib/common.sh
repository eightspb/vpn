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
#   - Работа с путями Windows/Linux (expand_tilde)
#   - SSH-хелперы (ssh_exec, ssh_upload, ssh_run_script)
#   - Авто-поиск SSH-ключа (auto_pick_key_if_missing)
#   - Копирование ключа из /mnt/ во временный файл (prepare_key_for_ssh)
#   - Очистка временных ключей (cleanup_temp_keys)
#   - Проверка зависимостей (check_deps)
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

# ── Загрузка дефолтов из файлов ───────────────────────────────────────────────
# Заполняет переменные VPS1_*/VPS2_* из ./vpn-output/keys.env и ./.env
# Переменные должны быть объявлены в вызывающем скрипте до вызова этой функции.
load_defaults_from_files() {
    if [[ -f "./vpn-output/keys.env" ]]; then
        local k_vps1 k_tun
        k_vps1="$(read_kv ./vpn-output/keys.env VPS1_IP)"
        k_tun="$(read_kv ./vpn-output/keys.env TUN_NET)"
        [[ -n "${k_vps1}" && -z "${VPS1_IP:-}" ]] && VPS1_IP="$k_vps1"
        if [[ -n "${k_tun}" ]]; then
            # Если в вызывающем скрипте есть VPS2_TUN_IP — обновляем его
            [[ -v VPS2_TUN_IP ]] && VPS2_TUN_IP="${k_tun}.2"
            # Если есть TUN_NET — обновляем
            [[ -v TUN_NET && -z "${TUN_NET:-}" ]] && TUN_NET="$k_tun"
        fi
    fi

    if [[ -f "./.env" ]]; then
        local e_vps1_ip e_vps1_user e_vps1_key e_vps1_pass
        local e_vps2_ip e_vps2_user e_vps2_key e_vps2_pass
        e_vps1_ip="$(read_kv ./.env VPS1_IP)"
        e_vps1_user="$(read_kv ./.env VPS1_USER)"
        e_vps1_key="$(read_kv ./.env VPS1_KEY)"
        e_vps1_pass="$(read_kv ./.env VPS1_PASS)"
        e_vps2_ip="$(read_kv ./.env VPS2_IP)"
        e_vps2_user="$(read_kv ./.env VPS2_USER)"
        e_vps2_key="$(read_kv ./.env VPS2_KEY)"
        e_vps2_pass="$(read_kv ./.env VPS2_PASS)"

        [[ -n "${e_vps1_ip}" ]]   && VPS1_IP="$e_vps1_ip"
        [[ -n "${e_vps1_user}" ]] && VPS1_USER="$e_vps1_user"
        [[ -n "${e_vps1_key}" ]]  && VPS1_KEY="$e_vps1_key"
        [[ -n "${e_vps1_pass}" ]] && VPS1_PASS="$e_vps1_pass"
        [[ -v VPS2_IP   && -n "${e_vps2_ip}" ]]   && VPS2_IP="$e_vps2_ip"
        [[ -v VPS2_USER && -n "${e_vps2_user}" ]] && VPS2_USER="$e_vps2_user"
        [[ -v VPS2_KEY  && -n "${e_vps2_key}" ]]  && VPS2_KEY="$e_vps2_key"
        [[ -v VPS2_PASS && -n "${e_vps2_pass}" ]] && VPS2_PASS="$e_vps2_pass"
    fi
    return 0
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
    local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
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
    local scp_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
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
