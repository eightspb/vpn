#!/usr/bin/env bash
# =============================================================================
# cleanup-legacy.sh — удаление legacy-файлов и финальные правки после реорганизации
#
# Что делает:
#   1. Удаляет phase4-cleanup.sh (одноразовый скрипт, уже выполнен, в .gitignore)
#   2. Удаляет vpn-dashboard-nginx.conf (устаревший конфиг, в .gitignore)
#   3. Удаляет ru-ips.txt (автогенерируемый файл, в .gitignore)
#   4. Обновляет README.md: пути python3 generate-split-config.py -> scripts/tools/
#   5. Обновляет .gitignore: убирает запись phase4-cleanup.sh (файл удалён)
#
# Использование:
#   bash cleanup-legacy.sh [--dry-run]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "[DRY-RUN] Режим предварительного просмотра — изменения не применяются"
fi

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

apply_sed() {
    local file="$1" pattern="$2"
    if $DRY_RUN; then
        echo "  [DRY] sed '$pattern' $file"
    else
        local tmp
        tmp=$(mktemp)
        sed "$pattern" "$file" > "$tmp" && mv "$tmp" "$file"
    fi
}

remove_file() {
    local f="$1"
    if [[ -f "$f" ]]; then
        if $DRY_RUN; then
            echo "  [DRY] rm $f"
        else
            rm "$f"
            log "  Удалён: $f"
        fi
    else
        warn "  Файл не найден (уже удалён?): $f"
    fi
}

# =============================================================================
# 1. Удаление legacy-файлов (не трекаются git — в .gitignore)
# =============================================================================
log "=== 1. Удаление legacy-файлов ==="

remove_file "phase4-cleanup.sh"
remove_file "vpn-dashboard-nginx.conf"
remove_file "ru-ips.txt"

# =============================================================================
# 2. Обновление README.md: пути к generate-split-config.py
# =============================================================================
log "=== 2. Обновление README.md ==="

apply_sed "README.md" \
    's|python3 generate-split-config\.py|python3 scripts/tools/generate-split-config.py|g'
log "  README.md: пути generate-split-config.py обновлены"

# =============================================================================
# 3. Обновление .gitignore: убираем запись phase4-cleanup.sh
# =============================================================================
log "=== 3. Обновление .gitignore ==="

apply_sed ".gitignore" \
    '/^# one-time cleanup script\r\?$/d'
apply_sed ".gitignore" \
    '/^phase4-cleanup\.sh\r\?$/d'
log "  .gitignore: запись phase4-cleanup.sh удалена"

# =============================================================================
# Итог
# =============================================================================
echo ""
if $DRY_RUN; then
    log "=== DRY-RUN завершён — изменения не применены ==="
else
    log "=== Чистка завершена ==="
    echo ""
    echo "Корень проекта:"
    ls -1 *.sh *.md *.txt *.conf 2>/dev/null || true
    echo ""
    log "Запустите тесты: bash tests/test-cleanup-legacy.sh"
fi
