#!/usr/bin/env bash
# =============================================================================
# migrate-ssh-keys.sh — переносит SSH-ключи в папку проекта .ssh/
#
# Что делает:
#   1. Создаёт .ssh/ в корне проекта
#   2. Копирует используемые SSH-ключи из ~/.ssh/ в .ssh/
#   3. Обновляет .env (VPS1_KEY, VPS2_KEY → .ssh/...)
#   4. Обновляет .env.example
#   5. Обновляет .gitignore (добавляет .ssh/)
#   6. Обновляет lib/common.sh (auto_pick_key_if_missing ищет .ssh/ проекта)
#   7. Обновляет все скрипты с захардкоженными путями ~/.ssh/ssh-key-*
#   8. Обновляет manage.sh (примеры в usage)
#   9. Обновляет README.md
#
# Использование:
#   bash scripts/tools/migrate-ssh-keys.sh [--dry-run]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { printf "${GREEN}[OK]${NC}   %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err()  { printf "${RED}[ERR]${NC}  %s\n" "$*"; }
info() { printf "${CYAN}[INFO]${NC} %s\n" "$*"; }
step() { printf "\n${CYAN}── %s${NC}\n" "$*"; }

ERRORS=0
CHANGES=0

inc_changes() { CHANGES=$((CHANGES + 1)); }
inc_errors()  { ERRORS=$((ERRORS + 1)); }

# ── 1. Определяем ключи из .env ──────────────────────────────────────────────
step "1. Определяем SSH-ключи из .env"

read_kv() {
    local file="$1" key="$2"
    awk -F= -v k="$key" '$1==k{sub(/^[^=]*=/,"",$0); gsub(/\r/,""); gsub(/^[ \t'"'"']+|[ \t'"'"']+$/,""); print; exit}' "$file" 2>/dev/null
}

expand_path() {
    local p="${1//\\//}"
    [[ "$p" == "~/"* ]] && p="${HOME}/${p#'~/'}"
    printf "%s" "$p"
}

# Ищет ключ по нескольким путям (WSL home, Windows home)
find_key_file() {
    local raw="$1"
    local expanded win_home
    expanded="$(expand_path "$raw")"
    [[ -f "$expanded" ]] && { printf "%s" "$expanded"; return 0; }
    win_home="${USERPROFILE:-}"; win_home="${win_home//\\//}"
    if [[ -n "$win_home" ]]; then
        local win_path="${win_home}/${raw#'~/'}"
        [[ -f "$win_path" ]] && { printf "%s" "$win_path"; return 0; }
    fi
    for prefix in /mnt/c/Users/*/; do
        local try="${prefix}.ssh/$(basename "$raw")"
        [[ -f "$try" ]] && { printf "%s" "$try"; return 0; }
    done
    printf "%s" "$expanded"
    return 1
}

ENV_FILE="${PROJECT_ROOT}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    err ".env не найден: $ENV_FILE"
    exit 1
fi

VPS1_KEY_RAW="$(read_kv "$ENV_FILE" VPS1_KEY)"
VPS2_KEY_RAW="$(read_kv "$ENV_FILE" VPS2_KEY)"
info "VPS1_KEY из .env: $VPS1_KEY_RAW"
info "VPS2_KEY из .env: $VPS2_KEY_RAW"

KEYS_TO_COPY=()
declare -A KEY_BASENAME_MAP

for key_raw in "$VPS1_KEY_RAW" "$VPS2_KEY_RAW"; do
    [[ -z "$key_raw" ]] && continue
    key_path="$(find_key_file "$key_raw")" || true
    basename_key="$(basename "$key_path")"
    if [[ -f "$key_path" ]]; then
        if [[ ! " ${KEYS_TO_COPY[*]:-} " =~ " ${key_path} " ]]; then
            KEYS_TO_COPY+=("$key_path")
            KEY_BASENAME_MAP["$key_path"]="$basename_key"
            ok "Найден ключ: $key_path"
        fi
    else
        err "Ключ не найден: $key_raw (пробовали: $key_path)"
        inc_errors
    fi
done

if [[ ${#KEYS_TO_COPY[@]} -eq 0 ]]; then
    err "Не найдено ни одного SSH-ключа для переноса"
    exit 1
fi

# ── 2. Создаём .ssh/ и копируем ключи ────────────────────────────────────────
step "2. Копируем SSH-ключи в ${PROJECT_ROOT}/.ssh/"

SSH_DIR="${PROJECT_ROOT}/.ssh"

if $DRY_RUN; then
    info "[dry-run] Создал бы $SSH_DIR"
else
    mkdir -p "$SSH_DIR"
    ok "Создана папка $SSH_DIR"
fi

find_pub_file() {
    local priv="$1" base
    base="$(basename "$priv")"
    [[ -f "${priv}.pub" ]] && { printf "%s" "${priv}.pub"; return 0; }
    for prefix in "${HOME}/.ssh" /mnt/c/Users/*/.ssh; do
        [[ -f "${prefix}/${base}.pub" ]] && { printf "%s" "${prefix}/${base}.pub"; return 0; }
    done
    return 1
}

for key_path in "${KEYS_TO_COPY[@]}"; do
    base="${KEY_BASENAME_MAP[$key_path]}"
    dst="${SSH_DIR}/${base}"
    pub_path="$(find_pub_file "$key_path")" || pub_path=""
    if $DRY_RUN; then
        info "[dry-run] Скопировал бы $key_path → $dst"
        [[ -n "$pub_path" ]] && info "[dry-run] Скопировал бы $pub_path → ${dst}.pub"
    else
        cp "$key_path" "$dst"
        chmod 600 "$dst" 2>/dev/null || true
        ok "Скопирован: $key_path → $dst"
        inc_changes
        if [[ -n "$pub_path" ]]; then
            cp "$pub_path" "${dst}.pub"
            chmod 644 "${dst}.pub" 2>/dev/null || true
            ok "Скопирован: $pub_path → ${dst}.pub"
            inc_changes
        else
            warn "Публичный ключ (.pub) не найден для $base"
        fi
    fi
done

# ── 3. Обновляем .gitignore ──────────────────────────────────────────────────
step "3. Обновляем .gitignore"

GITIGNORE="${PROJECT_ROOT}/.gitignore"
if [[ -f "$GITIGNORE" ]]; then
    if ! grep -qF '.ssh/' "$GITIGNORE"; then
        if $DRY_RUN; then
            info "[dry-run] Добавил бы .ssh/ в .gitignore"
        else
            printf '\n# SSH keys (private, do not commit)\n.ssh/\n' >> "$GITIGNORE"
            ok "Добавлено .ssh/ в .gitignore"
            inc_changes
        fi
    else
        ok ".ssh/ уже в .gitignore"
    fi
else
    warn ".gitignore не найден"
fi

# ── 4. Обновляем .env ────────────────────────────────────────────────────────
step "4. Обновляем .env"

update_env_key() {
    local file="$1" var="$2" old_raw="$3"
    local base new_val
    base="$(basename "$(expand_path "$old_raw")")"
    new_val=".ssh/${base}"
    if grep -q "^${var}=" "$file"; then
        if $DRY_RUN; then
            info "[dry-run] $file: $var=$old_raw → $var=$new_val"
        else
            sed -i "s|^${var}=.*|${var}=${new_val}|" "$file"
            ok "$file: $var → $new_val"
            inc_changes
        fi
    fi
}

update_env_key "$ENV_FILE" "VPS1_KEY" "$VPS1_KEY_RAW"
update_env_key "$ENV_FILE" "VPS2_KEY" "$VPS2_KEY_RAW"

# ── 5. Обновляем .env.example ────────────────────────────────────────────────
step "5. Обновляем .env.example"

ENV_EXAMPLE="${PROJECT_ROOT}/.env.example"
if [[ -f "$ENV_EXAMPLE" ]]; then
    for var in VPS1_KEY VPS2_KEY; do
        old_val="$(read_kv "$ENV_EXAMPLE" "$var")"
        if [[ "$old_val" == "~/.ssh/"* ]]; then
            if $DRY_RUN; then
                info "[dry-run] .env.example: $var=$old_val → $var=.ssh/id_rsa"
            else
                sed -i "s|^${var}=.*|${var}=.ssh/id_rsa|" "$ENV_EXAMPLE"
                ok ".env.example: $var → .ssh/id_rsa"
                inc_changes
            fi
        fi
    done
else
    warn ".env.example не найден"
fi

# ── 6. Обновляем lib/common.sh — auto_pick_key_if_missing ────────────────────
step "6. Обновляем lib/common.sh (auto_pick_key_if_missing)"

COMMON_SH="${PROJECT_ROOT}/lib/common.sh"
if [[ -f "$COMMON_SH" ]]; then
    if ! grep -q 'PROJECT_ROOT.*/.ssh/' "$COMMON_SH"; then
        if $DRY_RUN; then
            info "[dry-run] Добавил бы поиск в .ssh/ проекта в auto_pick_key_if_missing"
        else
            # Добавляем поиск ключей в .ssh/ проекта перед стандартными путями
            sed -i '/auto_pick_key_if_missing()/,/^}/ {
                /for candidate in/i\
    # Ищем ключи в .ssh/ папке проекта\
    local project_ssh_dir\
    project_ssh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/.ssh"\
    if [[ -d "$project_ssh_dir" ]]; then\
        for candidate in "$project_ssh_dir"/id_ed25519 "$project_ssh_dir"/id_rsa "$project_ssh_dir"/*; do\
            [[ -f "$candidate" && ! "$candidate" =~ \\.pub$ ]] && { printf "%s" "$candidate"; return; }\
        done\
    fi
            }' "$COMMON_SH"
            ok "Добавлен поиск в .ssh/ проекта в auto_pick_key_if_missing"
            inc_changes
        fi
    else
        ok "auto_pick_key_if_missing уже ищет в .ssh/ проекта"
    fi
else
    err "lib/common.sh не найден"
    inc_errors
fi

# ── 7. Обновляем захардкоженные пути в скриптах ──────────────────────────────
step "7. Обновляем захардкоженные пути ~/.ssh/ssh-key-* в скриптах"

OLD_KEY_PATH='~/.ssh/ssh-key-1772056840349'
NEW_KEY_PATH='.ssh/ssh-key-1772056840349'

SCRIPTS_WITH_HARDCODED=(
    "tests/dump_awg_conf.sh"
    "tests/check_vps1_keys.sh"
    "tests/find_awg_conf3.sh"
    "tests/find_awg_conf2.sh"
    "tests/find_awg_conf.sh"
    "tests/check_awg1_journal.sh"
    "tests/check_cert_san.sh"
    "tests/check_vps1_full_conf.sh"
    "tests/check_vps1_conf.sh"
    "tests/check_awg_state.sh"
)

for script in "${SCRIPTS_WITH_HARDCODED[@]}"; do
    full_path="${PROJECT_ROOT}/${script}"
    [[ ! -f "$full_path" ]] && { warn "Не найден: $script"; continue; }
    if grep -qF "$OLD_KEY_PATH" "$full_path"; then
        if $DRY_RUN; then
            info "[dry-run] $script: $OLD_KEY_PATH → $NEW_KEY_PATH"
        else
            sed -i "s|${OLD_KEY_PATH}|${NEW_KEY_PATH}|g" "$full_path"
            ok "$script: обновлён"
            inc_changes
        fi
    fi
done

# ── 8. Обновляем manage.sh (примеры в usage) ─────────────────────────────────
step "8. Обновляем manage.sh"

MANAGE_SH="${PROJECT_ROOT}/manage.sh"
if [[ -f "$MANAGE_SH" ]]; then
    if grep -qF "$OLD_KEY_PATH" "$MANAGE_SH"; then
        if $DRY_RUN; then
            info "[dry-run] manage.sh: $OLD_KEY_PATH → $NEW_KEY_PATH"
        else
            sed -i "s|${OLD_KEY_PATH}|${NEW_KEY_PATH}|g" "$MANAGE_SH"
            ok "manage.sh: обновлён"
            inc_changes
        fi
    fi
    # Обновляем общие примеры ~/.ssh/id_rsa → .ssh/id_rsa
    if grep -qF '~/.ssh/id_rsa' "$MANAGE_SH"; then
        if $DRY_RUN; then
            info "[dry-run] manage.sh: ~/.ssh/id_rsa → .ssh/id_rsa"
        else
            sed -i 's|~/.ssh/id_rsa|.ssh/id_rsa|g' "$MANAGE_SH"
            ok "manage.sh: ~/.ssh/id_rsa → .ssh/id_rsa"
            inc_changes
        fi
    fi
fi

# ── 9. Обновляем README.md ───────────────────────────────────────────────────
step "9. Обновляем README.md"

README="${PROJECT_ROOT}/README.md"
if [[ -f "$README" ]]; then
    if grep -qF "$OLD_KEY_PATH" "$README"; then
        if $DRY_RUN; then
            info "[dry-run] README.md: $OLD_KEY_PATH → $NEW_KEY_PATH"
        else
            sed -i "s|${OLD_KEY_PATH}|${NEW_KEY_PATH}|g" "$README"
            ok "README.md: ssh-key путь обновлён"
            inc_changes
        fi
    fi
    if grep -qF '~/.ssh/id_rsa' "$README"; then
        if $DRY_RUN; then
            info "[dry-run] README.md: ~/.ssh/id_rsa → .ssh/id_rsa"
        else
            sed -i 's|~/.ssh/id_rsa|.ssh/id_rsa|g' "$README"
            ok "README.md: ~/.ssh/id_rsa → .ssh/id_rsa"
            inc_changes
        fi
    fi
    if grep -qF '~/.ssh/<your_key>' "$README"; then
        if $DRY_RUN; then
            info "[dry-run] README.md: ~/.ssh/<your_key> → .ssh/<your_key>"
        else
            sed -i 's|~/.ssh/<your_key>|.ssh/<your_key>|g' "$README"
            ok "README.md: ~/.ssh/<your_key> → .ssh/<your_key>"
            inc_changes
        fi
    fi
fi

# ── 10. Обновляем scripts/tools/add_phone_peer.sh ────────────────────────────
step "10. Обновляем scripts/tools/add_phone_peer.sh"

ADD_PEER="${PROJECT_ROOT}/scripts/tools/add_phone_peer.sh"
if [[ -f "$ADD_PEER" ]]; then
    if grep -qF "$OLD_KEY_PATH" "$ADD_PEER"; then
        if $DRY_RUN; then
            info "[dry-run] add_phone_peer.sh: $OLD_KEY_PATH → $NEW_KEY_PATH"
        else
            sed -i "s|${OLD_KEY_PATH}|${NEW_KEY_PATH}|g" "$ADD_PEER"
            ok "add_phone_peer.sh: обновлён"
            inc_changes
        fi
    fi
fi

# ── Итог ─────────────────────────────────────────────────────────────────────
step "Итог"
if $DRY_RUN; then
    info "Dry-run завершён. Изменений не внесено."
else
    ok "Изменений: $CHANGES"
fi
if [[ $ERRORS -gt 0 ]]; then
    err "Ошибок: $ERRORS"
    exit 1
fi

ok "Миграция SSH-ключей завершена!"
echo ""
info "SSH-ключи теперь в: ${PROJECT_ROOT}/.ssh/"
info ".env обновлён: VPS1_KEY=.ssh/..., VPS2_KEY=.ssh/..."
info ".gitignore обновлён: .ssh/ не попадёт в git"
echo ""
info "Проверьте работу: bash manage.sh check"
