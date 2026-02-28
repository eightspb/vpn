#!/usr/bin/env bash
# =============================================================================
# deploy-admin.sh — управление VPN Admin Panel
#
# Использование:
#   bash deploy-admin.sh start       — Запуск (dev: 127.0.0.1:8081, в WSL: 0.0.0.0:8081)
#   bash deploy-admin.sh start-prod  — Запуск HTTPS (0.0.0.0:8443)
#   bash deploy-admin.sh stop        — Остановка
#   bash deploy-admin.sh status      — Проверка статуса
#   bash deploy-admin.sh setup       — Установка зависимостей
#   bash deploy-admin.sh restart     — Перезапуск
#   bash deploy-admin.sh logs        — Просмотр логов
#   bash deploy-admin.sh reset-password  — Сбросить пароль admin на «admin»
#
# Опции:
#   --port PORT       Порт (по умолчанию: 8081 dev, 8443 prod)
#   --host HOST       Host для bind (по умолчанию: auto)
#   --cert FILE       SSL-сертификат (для start-prod)
#   --key FILE        SSL-ключ (для start-prod)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ "$SCRIPT_DIR" =~ ^/[A-Za-z]/ ]]; then
    _drive=$(echo "$SCRIPT_DIR" | cut -c2 | tr '[:upper:]' '[:lower:]')
    _rest=$(echo "$SCRIPT_DIR" | cut -c3-)
    SCRIPT_DIR="/mnt/${_drive}${_rest}"
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

source "${PROJECT_ROOT}/lib/common.sh"

ADMIN_DIR="${PROJECT_ROOT}/scripts/admin"
ADMIN_SCRIPT="${ADMIN_DIR}/admin-server.py"
REQUIREMENTS="${ADMIN_DIR}/requirements.txt"
VENV_DIR="${ADMIN_DIR}/.venv"
PID_FILE="${ADMIN_DIR}/admin.pid"
LOG_FILE="${ADMIN_DIR}/admin.log"

# ── Поиск Python ─────────────────────────────────────────────────────────────

find_python() {
    for cmd in python3 python py; do
        if command -v "$cmd" &>/dev/null; then
            local ver
            ver="$("$cmd" --version 2>&1 | grep -oP '\d+\.\d+' | head -1)"
            local major="${ver%%.*}"
            if [[ "$major" -ge 3 ]]; then
                printf "%s" "$cmd"
                return 0
            fi
        fi
    done
    return 1
}

PYTHON=""
find_python_or_fail() {
    PYTHON="$(find_python)" || err "Python 3 не найден. Установите Python 3.8+"
}

# ── Виртуальное окружение ─────────────────────────────────────────────────────

ensure_venv() {
    if [[ ! -d "$VENV_DIR" ]]; then
        step "Создание виртуального окружения"
        "$PYTHON" -m venv "$VENV_DIR"
        ok "Venv создан: $VENV_DIR"
    fi
}

activate_venv() {
    if [[ -f "$VENV_DIR/bin/activate" ]]; then
        source "$VENV_DIR/bin/activate"
    elif [[ -f "$VENV_DIR/Scripts/activate" ]]; then
        source "$VENV_DIR/Scripts/activate"
    else
        err "Не найден activate в $VENV_DIR"
    fi
}

install_deps() {
    step "Установка зависимостей"
    if [[ ! -f "$REQUIREMENTS" ]]; then
        err "Не найден $REQUIREMENTS"
    fi
    activate_venv
    pip install --upgrade pip -q 2>/dev/null || true
    pip install -r "$REQUIREMENTS" -q
    ok "Зависимости установлены"
}

# ── Управление процессом ──────────────────────────────────────────────────────

is_running() {
    if [[ ! -f "$PID_FILE" ]]; then
        return 1
    fi
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    if [[ -z "$pid" ]]; then
        rm -f "$PID_FILE"
        return 1
    fi
    if kill -0 "$pid" 2>/dev/null; then
        return 0
    else
        warn "Стейл PID-файл (процесс $pid не существует), удаляю"
        rm -f "$PID_FILE"
        return 1
    fi
}

get_pid() {
    cat "$PID_FILE" 2>/dev/null
}

is_admin_process_pid() {
    local pid="${1:-}"
    [[ -z "$pid" ]] && return 1
    kill -0 "$pid" 2>/dev/null || return 1

    local args=""
    if command -v ps &>/dev/null; then
        args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    fi
    [[ -z "$args" ]] && return 1

    [[ "$args" == *"admin-server.py"* ]]
}

find_running_admin_pid() {
    # 1) PID file (preferred source)
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid="$(get_pid)"
        if [[ -n "$pid" ]] && is_admin_process_pid "$pid"; then
            printf "%s" "$pid"
            return 0
        fi
        rm -f "$PID_FILE"
    fi

    # 2) Process table fallback
    if command -v pgrep &>/dev/null; then
        local pid
        while IFS= read -r pid; do
            [[ -z "$pid" ]] && continue
            if is_admin_process_pid "$pid"; then
                echo "$pid" > "$PID_FILE"
                printf "%s" "$pid"
                return 0
            fi
        done < <(pgrep -f "admin-server.py" 2>/dev/null || true)
    fi
    return 1
}

get_listener_pid_by_port() {
    local port="$1"
    local pid=""

    if command -v ss &>/dev/null; then
        pid="$(ss -tlnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p { if (match($0, /pid=([0-9]+)/, m)) { print m[1]; exit } }')"
    fi
    if [[ -z "$pid" ]] && command -v lsof &>/dev/null; then
        pid="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -n1 || true)"
    fi
    if [[ -n "$pid" ]]; then
        printf "%s" "$pid"
        return 0
    fi
    return 1
}

stop_pid_gracefully() {
    local pid="$1"
    kill "$pid" 2>/dev/null || true
    for _ in {1..20}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.25
    done
    warn "Процесс $pid не завершился, отправляю SIGKILL"
    kill -9 "$pid" 2>/dev/null || true
    sleep 0.5
}

is_wsl_runtime() {
    [[ -n "${WSL_INTEROP:-}" || -n "${WSL_DISTRO_NAME:-}" ]] && return 0
    grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null
}

default_bind_host() {
    local mode="${1:-dev}"
    if [[ "$mode" == "prod" ]]; then
        printf "0.0.0.0"
        return 0
    fi
    if is_wsl_runtime; then
        # In WSL we bind to all interfaces so localhost:8081 is reachable from Windows.
        printf "0.0.0.0"
    else
        printf "127.0.0.1"
    fi
}

print_admin_urls() {
    local host="$1" port="$2"
    if [[ "$host" == "127.0.0.1" ]]; then
        log "URL: http://localhost:${port}"
        return 0
    fi
    if [[ "$host" == "0.0.0.0" ]]; then
        log "URL (localhost): http://localhost:${port}"
        return 0
    fi
    log "URL: http://${host}:${port}"
}

cmd_setup() {
    find_python_or_fail
    ensure_venv
    install_deps
    ok "Админ-панель готова к запуску"
}

cmd_start() {
    local mode="${1:-dev}"
    shift || true
    local port="" host="" cert="" key_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)  port="$2";     shift 2 ;;
            --host)  host="$2";     shift 2 ;;
            --cert)  cert="$2";     shift 2 ;;
            --key)   key_file="$2"; shift 2 ;;
            *)       shift ;;
        esac
    done

    local listen_port="${port:-}"
    if [[ -z "$listen_port" ]]; then
        [[ "$mode" == "prod" ]] && listen_port="8443" || listen_port="8081"
    fi
    local listen_host="${host:-$(default_bind_host "$mode")}"

    local running_pid=""
    if running_pid="$(find_running_admin_pid)"; then
        warn "Админ-панель уже запущена (PID: $running_pid)"
        print_admin_urls "$listen_host" "$listen_port"
        return 0
    fi

    local owner_pid=""
    if owner_pid="$(get_listener_pid_by_port "$listen_port" 2>/dev/null)"; then
        if is_admin_process_pid "$owner_pid"; then
            echo "$owner_pid" > "$PID_FILE"
            warn "Обнаружен запущенный admin-server на порту ${listen_port} (PID: $owner_pid)"
            print_admin_urls "$listen_host" "$listen_port"
            return 0
        fi
        err "Порт ${listen_port} уже занят процессом PID=${owner_pid}. Освободите порт или используйте --port."
    fi

    find_python_or_fail
    ensure_venv
    install_deps

    step "Запуск админ-панели ($mode)"

    activate_venv

    local args=()
    if [[ "$mode" == "prod" ]]; then
        args+=(--prod)
        [[ -n "$cert" ]] && args+=(--cert "$cert")
        [[ -n "$key_file" ]] && args+=(--key "$key_file")
    fi
    args+=(--host "$listen_host")
    [[ -n "$port" ]] && args+=(--port "$port")

    nohup "$PYTHON" "$ADMIN_SCRIPT" "${args[@]}" >> "$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"

    for _ in {1..30}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            err "Не удалось запустить админ-панель. Проверьте логи: $LOG_FILE"
        fi
        owner_pid="$(get_listener_pid_by_port "$listen_port" 2>/dev/null || true)"
        if [[ -n "$owner_pid" ]] && is_admin_process_pid "$owner_pid"; then
            echo "$owner_pid" > "$PID_FILE"
            ok "Админ-панель запущена (PID: $owner_pid)"
            print_admin_urls "$listen_host" "$listen_port"
            log "Логи: $LOG_FILE"
            return 0
        fi
        sleep 0.25
    done

    stop_pid_gracefully "$pid"
    rm -f "$PID_FILE"
    err "Админ-панель не начала слушать порт ${listen_port}. Проверьте логи: $LOG_FILE"
}

cmd_stop() {
    local pid=""
    if ! pid="$(find_running_admin_pid)"; then
        warn "Админ-панель не запущена"
        rm -f "$PID_FILE"
        return 0
    fi
    step "Остановка админ-панели (PID: $pid)"

    stop_pid_gracefully "$pid"
    rm -f "$PID_FILE"
    ok "Админ-панель остановлена"
}

cmd_restart() {
    cmd_stop
    cmd_start "$@"
}

cmd_status() {
    local pid=""
    if pid="$(find_running_admin_pid)"; then
        ok "Админ-панель запущена (PID: $pid)"

        if command -v ss &>/dev/null; then
            local ports
            ports="$(ss -tlnp 2>/dev/null | grep "pid=${pid}," | awk '{print $4}' | sed 's/.*://' | tr '\n' ', ' | sed 's/,$//')"
            [[ -n "$ports" ]] && log "Порты: $ports"
        fi

        if [[ -f "$LOG_FILE" ]]; then
            log "Последние строки лога:"
            tail -5 "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
                echo "  $line"
            done
        fi
        return 0
    fi
    warn "Админ-панель не запущена"
    return 1
}

cmd_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        warn "Лог-файл не найден: $LOG_FILE"
        return 1
    fi
    step "Логи админ-панели ($LOG_FILE)"
    tail -f "$LOG_FILE"
}

cmd_reset_password() {
    find_python_or_fail
    ensure_venv
    activate_venv

    local db_file="${ADMIN_DIR}/admin.db"
    if [[ ! -f "$db_file" ]]; then
        warn "База админки не найдена: $db_file"
        log "Запустите админку один раз: bash deploy-admin.sh start"
        return 1
    fi

    step "Сброс пароля пользователя admin на «admin»"

    "$PYTHON" "${ADMIN_DIR}/reset-admin-password.py" "$db_file" || { err "Не удалось сбросить пароль"; return 1; }

    ok "Пароль пользователя admin установлен в «admin». Войдите и смените его в настройках."
}

# ── Справка ───────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
deploy-admin.sh — управление VPN Admin Panel

Команды:
  start        Запуск (dev: 127.0.0.1:8081, в WSL: 0.0.0.0:8081)
  start-prod   Запуск HTTPS (0.0.0.0:8443)
  stop         Остановка
  status       Проверка статуса
  setup        Установка зависимостей
  restart      Перезапуск
  logs         Просмотр логов (tail -f)
  reset-password  Сбросить пароль admin на «admin» (если забыли)

Опции:
  --port PORT  Порт (по умолчанию: 8081 dev, 8443 prod)
  --host HOST  Host для bind (по умолчанию: auto)
  --cert FILE  SSL-сертификат (для start-prod)
  --key FILE   SSL-ключ (для start-prod)

Примеры:
  bash deploy-admin.sh setup
  bash deploy-admin.sh start
  bash deploy-admin.sh start --host 0.0.0.0
  bash deploy-admin.sh start --port 9000
  bash deploy-admin.sh start-prod --cert cert.pem --key key.pem
  bash deploy-admin.sh status
  bash deploy-admin.sh stop
  bash deploy-admin.sh logs
  bash deploy-admin.sh reset-password   # если забыли пароль
EOF
}

# ── Диспетчер команд ──────────────────────────────────────────────────────────

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
    start)      cmd_start "dev" "$@" ;;
    start-prod) cmd_start "prod" "$@" ;;
    stop)       cmd_stop ;;
    status)     cmd_status ;;
    setup)      cmd_setup ;;
    restart)    cmd_restart "dev" "$@" ;;
    logs)       cmd_logs ;;
    reset-password) cmd_reset_password ;;
    help|--help|-h) usage ;;
    *)
        echo -e "${RED}Неизвестная команда: ${COMMAND}${NC}" >&2
        usage >&2
        exit 1
        ;;
esac
