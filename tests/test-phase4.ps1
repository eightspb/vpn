# tests/test-phase4.ps1 — проверки Фазы 4 (чистка и документация)
# Запуск: powershell -File tests\test-phase4.ps1

$ErrorActionPreference = "Stop"
$PASS = 0
$FAIL = 0

function ok($msg) {
    Write-Host "  [PASS] $msg" -ForegroundColor Green
    $script:PASS++
}

function fail($msg) {
    Write-Host "  [FAIL] $msg" -ForegroundColor Red
    $script:FAIL++
}

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host ""
Write-Host "=== Тесты Фазы 4: Чистка и документация ===" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Устаревшие скрипты удалены
# ---------------------------------------------------------------------------
Write-Host "--- 1. Устаревшие скрипты удалены ---"

if (-not (Test-Path "update-dashboard-data.sh")) {
    ok "update-dashboard-data.sh отсутствует"
} else {
    fail "update-dashboard-data.sh всё ещё существует"
}

if (-not (Test-Path "update-dashboard-simple.sh")) {
    ok "update-dashboard-simple.sh отсутствует"
} else {
    fail "update-dashboard-simple.sh всё ещё существует"
}

# ---------------------------------------------------------------------------
# 2. Мусорные файлы удалены
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 2. Мусорные файлы удалены ---"

if (-not (Test-Path "qc")) { ok "файл qc отсутствует" } else { fail "файл qc всё ещё существует" }
if (-not (Test-Path "query")) { ok "файл query отсутствует" } else { fail "файл query всё ещё существует" }

# ---------------------------------------------------------------------------
# 3. spb_client.conf удалён
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 3. spb_client.conf с приватным ключом удалён ---"

if (-not (Test-Path "spb_client.conf")) {
    ok "spb_client.conf отсутствует"
} else {
    fail "spb_client.conf всё ещё существует (содержит приватный ключ!)"
}

# ---------------------------------------------------------------------------
# 4. .gitignore содержит нужные записи
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 4. .gitignore содержит нужные записи ---"

$gi = Get-Content ".gitignore" -Raw -ErrorAction SilentlyContinue

foreach ($pattern in @("*.conf", "vpn-output/*", ".env", "youtube-proxy/youtube-proxy")) {
    if ($gi -match [regex]::Escape($pattern)) {
        ok ".gitignore содержит: $pattern"
    } else {
        fail ".gitignore не содержит: $pattern"
    }
}

# ---------------------------------------------------------------------------
# 5. README.md содержит актуальную документацию
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 5. README.md содержит актуальную документацию ---"

if (Test-Path "README.md") {
    ok "README.md существует"
    $readme = Get-Content "README.md" -Raw

    foreach ($phase in @("test-phase2", "test-phase3", "test-phase4")) {
        if ($readme -match [regex]::Escape($phase)) {
            ok "README.md упоминает $phase"
        } else {
            fail "README.md не упоминает $phase"
        }
    }

    if ($readme -match 'PrivateKey\s*=') {
        fail "README.md содержит PrivateKey!"
    } else {
        ok "README.md не содержит приватных ключей"
    }
} else {
    fail "README.md отсутствует"
}

# ---------------------------------------------------------------------------
# 6. Тесты всех фаз присутствуют
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 6. Тесты всех фаз присутствуют ---"

foreach ($f in @(
    "tests/test-phase2.sh", "tests/test-phase2.ps1",
    "tests/test-phase3.sh", "tests/test-phase3.ps1",
    "tests/test-phase4.sh", "tests/test-phase4.ps1"
)) {
    if (Test-Path $f) { ok "$f существует" } else { fail "$f отсутствует" }
}

# ---------------------------------------------------------------------------
# 7. Deploy-скрипты: базовая валидация структуры
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 7. Deploy-скрипты: базовая валидация структуры ---"

foreach ($script in @("scripts/deploy/deploy.sh", "scripts/deploy/deploy-vps1.sh", "scripts/deploy/deploy-vps2.sh", "scripts/deploy/deploy-proxy.sh")) {
    if (-not (Test-Path $script)) {
        fail "$script отсутствует"
        continue
    }
    $content = Get-Content $script -Raw

    # Проверяем set -e
    if ($content -match '(?m)^\s*set\s+-[a-z]*e') {
        ok "${script}: содержит set -e (безопасный режим)"
    } else {
        fail "${script}: отсутствует set -e"
    }

    # Нет хардкода приватных ключей
    if ($content -match 'PrivateKey\s*=\s*[A-Za-z0-9+/]{40,}') {
        fail "${script}: содержит хардкод приватного ключа!"
    } else {
        ok "${script}: нет хардкода приватных ключей"
    }
}

# ---------------------------------------------------------------------------
# Итог
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=================================" -ForegroundColor Cyan
Write-Host "Итого: PASS=$PASS  FAIL=$FAIL" -ForegroundColor Cyan
Write-Host "=================================" -ForegroundColor Cyan
Write-Host ""

if ($FAIL -gt 0) { exit 1 } else { exit 0 }
