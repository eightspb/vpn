#!/usr/bin/env bash
# =============================================================================
# reorganize.sh — реорганизация файлов проекта по подпапкам
#
# Что делает:
#   1. Создаёт папки scripts/deploy, scripts/monitor, scripts/tools, scripts/windows
#   2. Перемещает скрипты через git mv
#   3. Обновляет пути в manage.sh
#   4. Обновляет source/SCRIPT_DIR ссылки в перемещённых скриптах
#   5. Обновляет пути в тестах
#   6. Обновляет README.md
#
# Использование:
#   bash reorganize.sh [--dry-run]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "[DRY-RUN] Режим предварительного просмотра — изменения не применяются"
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }

run() {
    if $DRY_RUN; then
        echo "  [DRY] $*"
    else
        "$@"
    fi
}

# =============================================================================
# 1. Создание папок
# =============================================================================
log "=== 1. Создание папок ==="

for dir in scripts/deploy scripts/monitor scripts/tools scripts/windows; do
    if [[ ! -d "$dir" ]]; then
        run mkdir -p "$dir"
        log "  mkdir $dir"
    else
        log "  $dir уже существует"
    fi
done

# =============================================================================
# 2. Перемещение файлов через git mv
# =============================================================================
log "=== 2. Перемещение файлов ==="

move_file() {
    local src="$1" dst="$2"
    if [[ -f "$src" ]]; then
        # Для неотслеживаемых файлов git mv не работает — сначала добавляем в индекс
        if ! git ls-files --error-unmatch "$src" > /dev/null 2>&1; then
            run git add "$src"
        fi
        run git mv "$src" "$dst"
        log "  git mv $src -> $dst"
    else
        warn "  Файл не найден, пропускаем: $src"
    fi
}

# scripts/deploy/
move_file "deploy.sh"          "scripts/deploy/deploy.sh"
move_file "deploy-vps1.sh"     "scripts/deploy/deploy-vps1.sh"
move_file "deploy-vps2.sh"     "scripts/deploy/deploy-vps2.sh"
move_file "deploy-proxy.sh"    "scripts/deploy/deploy-proxy.sh"
move_file "security-update.sh" "scripts/deploy/security-update.sh"

# scripts/monitor/
move_file "monitor-realtime.sh" "scripts/monitor/monitor-realtime.sh"
move_file "monitor-web.sh"      "scripts/monitor/monitor-web.sh"
move_file "dashboard.html"      "scripts/monitor/dashboard.html"

# scripts/tools/
move_file "add_phone_peer.sh"        "scripts/tools/add_phone_peer.sh"
move_file "benchmark.sh"             "scripts/tools/benchmark.sh"
move_file "check_ping.sh"            "scripts/tools/check_ping.sh"
move_file "diagnose.sh"              "scripts/tools/diagnose.sh"
move_file "generate-all-configs.sh"  "scripts/tools/generate-all-configs.sh"
move_file "generate-split-config.py" "scripts/tools/generate-split-config.py"
move_file "load-test.sh"             "scripts/tools/load-test.sh"
move_file "optimize-vpn.sh"          "scripts/tools/optimize-vpn.sh"
move_file "repair-vps1.sh"           "scripts/tools/repair-vps1.sh"

# scripts/windows/
move_file "install-ca.ps1"          "scripts/windows/install-ca.ps1"
move_file "repair-local-configs.ps1" "scripts/windows/repair-local-configs.ps1"

# =============================================================================
# 3. Обновление manage.sh — пути к скриптам
# =============================================================================
log "=== 3. Обновление manage.sh ==="

update_manage_sh() {
    local file="manage.sh"
    [[ -f "$file" ]] || err "manage.sh не найден"

    # Функция применяет sed-замену (или выводит в dry-run)
    apply_sed() {
        local pattern="$1"
        if $DRY_RUN; then
            echo "  [DRY] sed '$pattern' $file"
        else
            # Используем временный файл для совместимости (нет sed -i на всех платформах)
            local tmp
            tmp=$(mktemp)
            sed "$pattern" "$file" > "$tmp" && mv "$tmp" "$file"
        fi
    }

    # deploy.sh -> scripts/deploy/deploy.sh
    apply_sed 's|bash "${SCRIPT_DIR}/deploy\.sh"|bash "${SCRIPT_DIR}/scripts/deploy/deploy.sh"|g'
    apply_sed 's|bash "${SCRIPT_DIR}/deploy-vps1\.sh"|bash "${SCRIPT_DIR}/scripts/deploy/deploy-vps1.sh"|g'
    apply_sed 's|bash "${SCRIPT_DIR}/deploy-vps2\.sh"|bash "${SCRIPT_DIR}/scripts/deploy/deploy-vps2.sh"|g'
    apply_sed 's|bash "${SCRIPT_DIR}/deploy-proxy\.sh"|bash "${SCRIPT_DIR}/scripts/deploy/deploy-proxy.sh"|g'

    # monitor-realtime.sh -> scripts/monitor/monitor-realtime.sh
    apply_sed 's|bash "${SCRIPT_DIR}/monitor-realtime\.sh"|bash "${SCRIPT_DIR}/scripts/monitor/monitor-realtime.sh"|g'
    apply_sed 's|bash "${SCRIPT_DIR}/monitor-web\.sh"|bash "${SCRIPT_DIR}/scripts/monitor/monitor-web.sh"|g'

    # add_phone_peer.sh -> scripts/tools/add_phone_peer.sh
    apply_sed 's|bash "${SCRIPT_DIR}/add_phone_peer\.sh"|bash "${SCRIPT_DIR}/scripts/tools/add_phone_peer.sh"|g'

    # check_ping.sh -> scripts/tools/check_ping.sh
    apply_sed 's|"${SCRIPT_DIR}/check_ping\.sh"|"${SCRIPT_DIR}/scripts/tools/check_ping.sh"|g'

    log "  manage.sh обновлён"
}
update_manage_sh

# =============================================================================
# 4. Обновление source/SCRIPT_DIR ссылок в перемещённых скриптах
# =============================================================================
log "=== 4. Обновление путей внутри скриптов ==="

apply_sed_to_file() {
    local file="$1" pattern="$2"
    if $DRY_RUN; then
        echo "  [DRY] sed '$pattern' $file"
    else
        local tmp
        tmp=$(mktemp)
        sed "$pattern" "$file" > "$tmp" && mv "$tmp" "$file"
    fi
}

# --- scripts/deploy/deploy.sh ---
# SECURITY_UPDATE_SCRIPT: ${SCRIPT_DIR}/security-update.sh -> ${SCRIPT_DIR}/security-update.sh (same dir)
# deploy-proxy.sh: ${LINUX_SCRIPT_DIR}/deploy-proxy.sh -> ${LINUX_SCRIPT_DIR}/deploy-proxy.sh (same dir)
# Эти два файла теперь в одной папке — ничего менять не нужно для security-update.sh и deploy-proxy.sh
# НО: youtube-proxy/ теперь относительно SCRIPT_DIR (scripts/deploy/) нужно ../../youtube-proxy
# Это в deploy-proxy.sh

# --- scripts/deploy/deploy-vps1.sh и deploy-vps2.sh ---
# SECURITY_UPDATE_SCRIPT="${SCRIPT_DIR}/security-update.sh" — теперь в той же папке, ничего менять не нужно

# --- scripts/deploy/deploy-proxy.sh ---
# PROXY_DIR="$SCRIPT_DIR/youtube-proxy" -> PROXY_DIR="$SCRIPT_DIR/../../youtube-proxy"
if [[ -f "scripts/deploy/deploy-proxy.sh" ]] || $DRY_RUN; then
    apply_sed_to_file "scripts/deploy/deploy-proxy.sh" \
        's|PROXY_DIR="\$SCRIPT_DIR/youtube-proxy"|PROXY_DIR="$SCRIPT_DIR/../../youtube-proxy"|'
    log "  scripts/deploy/deploy-proxy.sh: PROXY_DIR обновлён"
fi

# --- scripts/tools/benchmark.sh ---
# source "${SCRIPT_DIR}/lib/common.sh" -> source "${SCRIPT_DIR}/../../lib/common.sh"
if [[ -f "scripts/tools/benchmark.sh" ]] || $DRY_RUN; then
    apply_sed_to_file "scripts/tools/benchmark.sh" \
        's|source "${SCRIPT_DIR}/lib/common\.sh"|source "${SCRIPT_DIR}/../../lib/common.sh"|g'
    log "  scripts/tools/benchmark.sh: source путь обновлён"
fi

# --- scripts/tools/load-test.sh ---
if [[ -f "scripts/tools/load-test.sh" ]] || $DRY_RUN; then
    apply_sed_to_file "scripts/tools/load-test.sh" \
        's|source "${SCRIPT_DIR}/lib/common\.sh"|source "${SCRIPT_DIR}/../../lib/common.sh"|g'
    log "  scripts/tools/load-test.sh: source путь обновлён"
fi

# --- scripts/tools/optimize-vpn.sh ---
if [[ -f "scripts/tools/optimize-vpn.sh" ]] || $DRY_RUN; then
    apply_sed_to_file "scripts/tools/optimize-vpn.sh" \
        's|source "${SCRIPT_DIR}/lib/common\.sh"|source "${SCRIPT_DIR}/../../lib/common.sh"|g'
    log "  scripts/tools/optimize-vpn.sh: source путь обновлён"
fi

# --- scripts/tools/generate-all-configs.sh ---
# python3 generate-split-config.py -> python3 "${SCRIPT_DIR}/generate-split-config.py"
# (скрипт делает cd "$SCRIPT_DIR", так что относительный путь сохраняется — ничего менять не нужно)
log "  scripts/tools/generate-all-configs.sh: generate-split-config.py в той же папке — без изменений"

# --- scripts/monitor/monitor-web.sh ---
# cd "$SCRIPT_DIR" — теперь SCRIPT_DIR = scripts/monitor/
# JSON_FILE="./vpn-output/data.json" — относительно CWD (scripts/monitor/)
# vpn-output/ находится в корне, нужно ../../vpn-output/data.json
if [[ -f "scripts/monitor/monitor-web.sh" ]] || $DRY_RUN; then
    apply_sed_to_file "scripts/monitor/monitor-web.sh" \
        's|JSON_FILE="\./vpn-output/data\.json"|JSON_FILE="../../vpn-output/data.json"|'
    log "  scripts/monitor/monitor-web.sh: JSON_FILE путь обновлён"
fi

# =============================================================================
# 5. Обновление тестов
# =============================================================================
log "=== 5. Обновление тестов ==="

update_test_file() {
    local file="$1"
    [[ -f "$file" ]] || { warn "  Тест не найден: $file"; return; }

    apply_sed_to_file "$file" \
        's|\bmonitor-realtime\.sh\b|scripts/monitor/monitor-realtime.sh|g'
    apply_sed_to_file "$file" \
        's|\bmonitor-web\.sh\b|scripts/monitor/monitor-web.sh|g'
    apply_sed_to_file "$file" \
        's|\bdashboard\.html\b|scripts/monitor/dashboard.html|g'
    apply_sed_to_file "$file" \
        's|\bdeploy\.sh\b|scripts/deploy/deploy.sh|g'
    apply_sed_to_file "$file" \
        's|\bdeploy-vps1\.sh\b|scripts/deploy/deploy-vps1.sh|g'
    apply_sed_to_file "$file" \
        's|\bdeploy-vps2\.sh\b|scripts/deploy/deploy-vps2.sh|g'
    apply_sed_to_file "$file" \
        's|\bdeploy-proxy\.sh\b|scripts/deploy/deploy-proxy.sh|g'
    apply_sed_to_file "$file" \
        's|\bsecurity-update\.sh\b|scripts/deploy/security-update.sh|g'
    apply_sed_to_file "$file" \
        's|\badd_phone_peer\.sh\b|scripts/tools/add_phone_peer.sh|g'
    apply_sed_to_file "$file" \
        's|\bbenchmark\.sh\b|scripts/tools/benchmark.sh|g'
    apply_sed_to_file "$file" \
        's|\bcheck_ping\.sh\b|scripts/tools/check_ping.sh|g'
    apply_sed_to_file "$file" \
        's|\bdiagnose\.sh\b|scripts/tools/diagnose.sh|g'
    apply_sed_to_file "$file" \
        's|\bgenerate-all-configs\.sh\b|scripts/tools/generate-all-configs.sh|g'
    apply_sed_to_file "$file" \
        's|\bload-test\.sh\b|scripts/tools/load-test.sh|g'
    apply_sed_to_file "$file" \
        's|\boptimize-vpn\.sh\b|scripts/tools/optimize-vpn.sh|g'
    apply_sed_to_file "$file" \
        's|\brepair-vps1\.sh\b|scripts/tools/repair-vps1.sh|g'
    apply_sed_to_file "$file" \
        's|\binstall-ca\.ps1\b|scripts/windows/install-ca.ps1|g'
    apply_sed_to_file "$file" \
        's|\brepair-local-configs\.ps1\b|scripts/windows/repair-local-configs.ps1|g'

    log "  $file обновлён"
}

for test_file in tests/test-phase2.sh tests/test-phase3.sh tests/test-phase4.sh \
                 tests/test-phase5.sh tests/test-proxy-fix.sh \
                 tests/test-monitor-web.sh tests/test-optimize.sh \
                 tests/test-load-test.sh tests/test-generate-all-configs.sh; do
    update_test_file "$test_file"
done

# Специальные замены в test-monitor-web.sh: проверка JSON_FILE пути
if [[ -f "tests/test-monitor-web.sh" ]] || $DRY_RUN; then
    apply_sed_to_file "tests/test-monitor-web.sh" \
        "s|JSON_FILE=\"\./vpn-output/data\.json\"|JSON_FILE=\"../../vpn-output/data.json\"|g"
    log "  tests/test-monitor-web.sh: JSON_FILE проверка обновлена"
fi

# PowerShell тесты — обновляем вручную через sed (они тоже ссылаются на скрипты)
for ps_file in tests/test-phase2.ps1 tests/test-phase3.ps1 tests/test-phase4.ps1 \
               tests/test-optimize.ps1 tests/test-repair-local-configs.ps1; do
    [[ -f "$ps_file" ]] || continue
    apply_sed_to_file "$ps_file" 's|\bdeploy\.sh\b|scripts/deploy/deploy.sh|g'
    apply_sed_to_file "$ps_file" 's|\bdeploy-vps1\.sh\b|scripts/deploy/deploy-vps1.sh|g'
    apply_sed_to_file "$ps_file" 's|\bdeploy-vps2\.sh\b|scripts/deploy/deploy-vps2.sh|g'
    apply_sed_to_file "$ps_file" 's|\bdeploy-proxy\.sh\b|scripts/deploy/deploy-proxy.sh|g'
    apply_sed_to_file "$ps_file" 's|\bmonitor-realtime\.sh\b|scripts/monitor/monitor-realtime.sh|g'
    apply_sed_to_file "$ps_file" 's|\bmonitor-web\.sh\b|scripts/monitor/monitor-web.sh|g'
    apply_sed_to_file "$ps_file" 's|\bdashboard\.html\b|scripts/monitor/dashboard.html|g'
    apply_sed_to_file "$ps_file" 's|\boptimize-vpn\.sh\b|scripts/tools/optimize-vpn.sh|g'
    apply_sed_to_file "$ps_file" 's|\bbenchmark\.sh\b|scripts/tools/benchmark.sh|g'
    apply_sed_to_file "$ps_file" 's|\brepair-local-configs\.ps1\b|scripts/windows/repair-local-configs.ps1|g'
    log "  $ps_file обновлён"
done

# =============================================================================
# 6. Обновление README.md
# =============================================================================
log "=== 6. Обновление README.md ==="

update_readme() {
    local file="README.md"
    [[ -f "$file" ]] || { warn "README.md не найден"; return; }

    # Замены путей в примерах команд и таблицах
    apply_sed_to_file "$file" 's|bash deploy\.sh|bash scripts/deploy/deploy.sh|g'
    apply_sed_to_file "$file" 's|bash deploy-vps1\.sh|bash scripts/deploy/deploy-vps1.sh|g'
    apply_sed_to_file "$file" 's|bash deploy-vps2\.sh|bash scripts/deploy/deploy-vps2.sh|g'
    apply_sed_to_file "$file" 's|bash deploy-proxy\.sh|bash scripts/deploy/deploy-proxy.sh|g'
    apply_sed_to_file "$file" 's|bash security-update\.sh|bash scripts/deploy/security-update.sh|g'
    apply_sed_to_file "$file" 's|bash monitor-realtime\.sh|bash scripts/monitor/monitor-realtime.sh|g'
    apply_sed_to_file "$file" 's|bash monitor-web\.sh|bash scripts/monitor/monitor-web.sh|g'
    apply_sed_to_file "$file" 's|\`monitor-web\.sh\`|`scripts/monitor/monitor-web.sh`|g'
    apply_sed_to_file "$file" 's|\`monitor-realtime\.sh\`|`scripts/monitor/monitor-realtime.sh`|g'
    apply_sed_to_file "$file" 's|\`dashboard\.html\`|`scripts/monitor/dashboard.html`|g'
    apply_sed_to_file "$file" 's|bash add_phone_peer\.sh|bash scripts/tools/add_phone_peer.sh|g'
    apply_sed_to_file "$file" 's|bash benchmark\.sh|bash scripts/tools/benchmark.sh|g'
    apply_sed_to_file "$file" 's|bash check_ping\.sh|bash scripts/tools/check_ping.sh|g'
    apply_sed_to_file "$file" 's|bash diagnose\.sh|bash scripts/tools/diagnose.sh|g'
    apply_sed_to_file "$file" 's|bash generate-all-configs\.sh|bash scripts/tools/generate-all-configs.sh|g'
    apply_sed_to_file "$file" 's|bash load-test\.sh|bash scripts/tools/load-test.sh|g'
    apply_sed_to_file "$file" 's|bash optimize-vpn\.sh|bash scripts/tools/optimize-vpn.sh|g'
    apply_sed_to_file "$file" 's|bash repair-vps1\.sh|bash scripts/tools/repair-vps1.sh|g'
    apply_sed_to_file "$file" 's|\`deploy\.sh\`|`scripts/deploy/deploy.sh`|g'
    apply_sed_to_file "$file" 's|\`deploy-vps1\.sh\`|`scripts/deploy/deploy-vps1.sh`|g'
    apply_sed_to_file "$file" 's|\`deploy-vps2\.sh\`|`scripts/deploy/deploy-vps2.sh`|g'
    apply_sed_to_file "$file" 's|\`deploy-proxy\.sh\`|`scripts/deploy/deploy-proxy.sh`|g'
    apply_sed_to_file "$file" 's|\`add_phone_peer\.sh\`|`scripts/tools/add_phone_peer.sh`|g'
    apply_sed_to_file "$file" 's|\`benchmark\.sh\`|`scripts/tools/benchmark.sh`|g'
    apply_sed_to_file "$file" 's|\`check_ping\.sh\`|`scripts/tools/check_ping.sh`|g'
    apply_sed_to_file "$file" 's|\`diagnose\.sh\`|`scripts/tools/diagnose.sh`|g'
    apply_sed_to_file "$file" 's|\`generate-all-configs\.sh\`|`scripts/tools/generate-all-configs.sh`|g'
    apply_sed_to_file "$file" 's|\`load-test\.sh\`|`scripts/tools/load-test.sh`|g'
    apply_sed_to_file "$file" 's|\`optimize-vpn\.sh\`|`scripts/tools/optimize-vpn.sh`|g'
    apply_sed_to_file "$file" 's|\`repair-vps1\.sh\`|`scripts/tools/repair-vps1.sh`|g'
    apply_sed_to_file "$file" 's|\`install-ca\.ps1\`|`scripts/windows/install-ca.ps1`|g'
    apply_sed_to_file "$file" 's|\`repair-local-configs\.ps1\`|`scripts/windows/repair-local-configs.ps1`|g'
    apply_sed_to_file "$file" 's|\`security-update\.sh\`|`scripts/deploy/security-update.sh`|g'

    log "  README.md обновлён"
}
update_readme

# =============================================================================
# Итог
# =============================================================================
echo ""
if $DRY_RUN; then
    log "=== DRY-RUN завершён — изменения не применены ==="
else
    log "=== Реорганизация завершена ==="
    echo ""
    echo "Структура scripts/:"
    find scripts/ -type f | sort
    echo ""
    log "Запустите тесты: bash tests/test-reorganize.sh"
fi
