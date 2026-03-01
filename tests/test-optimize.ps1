# tests/test-optimize.ps1 — проверки скриптов оптимизации и full-tunnel конфигов
# Запуск: powershell -File tests\test-optimize.ps1

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
Write-Host "=== Тесты оптимизации VPN (scripts/tools/optimize-vpn.sh, scripts/tools/benchmark.sh, full tunnel) ===" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Наличие файлов
# ---------------------------------------------------------------------------
Write-Host "--- 1. Файлы присутствуют ---"

foreach ($f in @("scripts/tools/optimize-vpn.sh", "scripts/tools/benchmark.sh")) {
    if (Test-Path $f) { ok "$f существует" } else { fail "$f отсутствует" }
}

foreach ($f in @("vpn-output/client.conf", "vpn-output/phone.conf")) {
    if (Test-Path $f) { ok "$f существует" } else { fail "$f отсутствует" }
}

# ---------------------------------------------------------------------------
# 2. Скрипты подключают lib/common.sh
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 2. Скрипты подключают lib/common.sh ---"

foreach ($f in @("scripts/tools/optimize-vpn.sh", "scripts/tools/benchmark.sh")) {
    if (-not (Test-Path $f)) { fail "$f отсутствует"; continue }
    $content = Get-Content $f -Raw
    if ($content -match 'source.*lib/common\.sh') {
        ok "${f}: source lib/common.sh найден"
    } else {
        fail "${f}: source lib/common.sh не найден"
    }
}

# ---------------------------------------------------------------------------
# 3. scripts/tools/optimize-vpn.sh содержит флаг --benchmark-only
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 3. scripts/tools/optimize-vpn.sh: флаг --benchmark-only ---"

if (Test-Path "scripts/tools/optimize-vpn.sh") {
    $opt = Get-Content "scripts/tools/optimize-vpn.sh" -Raw
    if ($opt -match '--benchmark-only') {
        ok "scripts/tools/optimize-vpn.sh: --benchmark-only найден"
    } else {
        fail "scripts/tools/optimize-vpn.sh: --benchmark-only не найден"
    }
    if ($opt -match 'BENCHMARK_ONLY') {
        ok "scripts/tools/optimize-vpn.sh: переменная BENCHMARK_ONLY найдена"
    } else {
        fail "scripts/tools/optimize-vpn.sh: переменная BENCHMARK_ONLY не найдена"
    }
} else {
    fail "scripts/tools/optimize-vpn.sh отсутствует"
}

# ---------------------------------------------------------------------------
# 4. scripts/tools/optimize-vpn.sh содержит ключевые sysctl параметры
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 4. scripts/tools/optimize-vpn.sh: sysctl параметры ---"

if (Test-Path "scripts/tools/optimize-vpn.sh") {
    $opt = Get-Content "scripts/tools/optimize-vpn.sh" -Raw
    foreach ($param in @(
        "tcp_slow_start_after_idle",
        "nf_conntrack_max=524288",
        "rmem_max=67108864",
        "wmem_max=67108864",
        "tcp_congestion_control=bbr",
        "default_qdisc=fq",
        "tcp_fastopen=3",
        "nf_conntrack_tcp_timeout_established",
        "99-vpn.conf"
    )) {
        if ($opt -match [regex]::Escape($param)) {
            ok "scripts/tools/optimize-vpn.sh: содержит $param"
        } else {
            fail "scripts/tools/optimize-vpn.sh: не содержит $param"
        }
    }
} else {
    fail "scripts/tools/optimize-vpn.sh отсутствует"
}

# ---------------------------------------------------------------------------
# 5. scripts/tools/optimize-vpn.sh содержит MTU значения
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 5. scripts/tools/optimize-vpn.sh: MTU значения ---"

if (Test-Path "scripts/tools/optimize-vpn.sh") {
    $opt = Get-Content "scripts/tools/optimize-vpn.sh" -Raw
    if ($opt -match '1420') {
        ok "scripts/tools/optimize-vpn.sh: MTU 1420 найден"
    } else {
        fail "scripts/tools/optimize-vpn.sh: MTU 1420 не найден"
    }
    if ($opt -match '1360') {
        ok "scripts/tools/optimize-vpn.sh: MTU 1360 найден"
    } else {
        fail "scripts/tools/optimize-vpn.sh: MTU 1360 не найден"
    }
}

# ---------------------------------------------------------------------------
# 6. scripts/tools/optimize-vpn.sh содержит MSS 1320
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 6. scripts/tools/optimize-vpn.sh: MSS clamp ---"

if (Test-Path "scripts/tools/optimize-vpn.sh") {
    $opt = Get-Content "scripts/tools/optimize-vpn.sh" -Raw
    if ($opt -match 'set-mss 1320') {
        ok "scripts/tools/optimize-vpn.sh: MSS 1320 найден"
    } else {
        fail "scripts/tools/optimize-vpn.sh: MSS 1320 не найден"
    }
    if ($opt -match 'TCPMSS') {
        ok "scripts/tools/optimize-vpn.sh: TCPMSS найден"
    } else {
        fail "scripts/tools/optimize-vpn.sh: TCPMSS не найден"
    }
}

# ---------------------------------------------------------------------------
# 7. scripts/tools/optimize-vpn.sh содержит PersistentKeepalive = 60
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 7. scripts/tools/optimize-vpn.sh: PersistentKeepalive ---"

if (Test-Path "scripts/tools/optimize-vpn.sh") {
    $opt = Get-Content "scripts/tools/optimize-vpn.sh" -Raw
    if ($opt -match 'PersistentKeepalive = 60') {
        ok "scripts/tools/optimize-vpn.sh: PersistentKeepalive = 60 найден"
    } else {
        fail "scripts/tools/optimize-vpn.sh: PersistentKeepalive = 60 не найден"
    }
}

# ---------------------------------------------------------------------------
# 8. scripts/tools/optimize-vpn.sh содержит Junk параметры
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 8. scripts/tools/optimize-vpn.sh: Junk параметры ---"

if (Test-Path "scripts/tools/optimize-vpn.sh") {
    $opt = Get-Content "scripts/tools/optimize-vpn.sh" -Raw
    foreach ($param in @("Jc   = 2", "Jmin = 20", "Jmax = 200", "S1   = 15", "S2   = 20")) {
        if ($opt -match [regex]::Escape($param)) {
            ok "scripts/tools/optimize-vpn.sh: '$param' найден"
        } else {
            fail "scripts/tools/optimize-vpn.sh: '$param' не найден"
        }
    }
}

# ---------------------------------------------------------------------------
# 9. Full tunnel конфиги: AllowedIPs = 0.0.0.0/0
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 9. Full tunnel конфиги: AllowedIPs ---"

foreach ($f in @("vpn-output/client.conf", "vpn-output/phone.conf")) {
    if (-not (Test-Path $f)) { fail "$f отсутствует"; continue }
    $content = Get-Content $f -Raw

    if ($content -match 'AllowedIPs') {
        ok "${f}: AllowedIPs найден"
    } else {
        fail "${f}: AllowedIPs не найден"
    }

    if ($content -match '(?m)^AllowedIPs\s*=\s*0\.0\.0\.0/0\s*$') {
        ok "${f}: AllowedIPs = 0.0.0.0/0 (full tunnel)"
    } else {
        fail "${f}: AllowedIPs не равен 0.0.0.0/0"
    }
}

# ---------------------------------------------------------------------------
# 10. Оригинальные конфиги не содержат split-схему
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 10. Оригинальные конфиги: без split ---"

foreach ($f in @("vpn-output/client.conf", "vpn-output/phone.conf")) {
    if (-not (Test-Path $f)) { fail "$f отсутствует"; continue }
    $content = Get-Content $f -Raw
    if ($content -match 'split') {
        fail "${f}: найдено упоминание split (неожиданно)"
    } else {
        ok "${f}: упоминаний split нет"
    }
}

# ---------------------------------------------------------------------------
# 11. scripts/tools/benchmark.sh содержит ключевые метрики
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 11. scripts/tools/benchmark.sh: ключевые метрики ---"

if (Test-Path "scripts/tools/benchmark.sh") {
    $bench = Get-Content "scripts/tools/benchmark.sh" -Raw
    foreach ($metric in @("ping", "speed_download", "mtu", "handshakes", "rmem_max", "tcp_congestion_control", "10.8.0.2")) {
        if ($bench -match [regex]::Escape($metric)) {
            ok "scripts/tools/benchmark.sh: содержит метрику '$metric'"
        } else {
            fail "scripts/tools/benchmark.sh: не содержит метрику '$metric'"
        }
    }
} else {
    fail "scripts/tools/benchmark.sh отсутствует"
}

# ---------------------------------------------------------------------------
# 12. scripts/tools/optimize-vpn.sh содержит флаги --vps1-only и --vps2-only
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 12. scripts/tools/optimize-vpn.sh: флаги --vps1-only и --vps2-only ---"

if (Test-Path "scripts/tools/optimize-vpn.sh") {
    $opt = Get-Content "scripts/tools/optimize-vpn.sh" -Raw
    foreach ($flag in @("--vps1-only", "--vps2-only")) {
        if ($opt -match [regex]::Escape($flag)) {
            ok "scripts/tools/optimize-vpn.sh: $flag найден"
        } else {
            fail "scripts/tools/optimize-vpn.sh: $flag не найден"
        }
    }
}

# ---------------------------------------------------------------------------
# 13. scripts/tools/optimize-vpn.sh использует SSH-хелперы из lib/common.sh
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 13. scripts/tools/optimize-vpn.sh: использует SSH-хелперы ---"

if (Test-Path "scripts/tools/optimize-vpn.sh") {
    $opt = Get-Content "scripts/tools/optimize-vpn.sh" -Raw
    foreach ($fn in @("ssh_run_script", "ssh_exec", "load_defaults_from_files", "prepare_key_for_ssh", "cleanup_temp_keys")) {
        if ($opt -match [regex]::Escape($fn)) {
            ok "scripts/tools/optimize-vpn.sh: вызывает $fn"
        } else {
            fail "scripts/tools/optimize-vpn.sh: не вызывает $fn"
        }
    }
}

# ---------------------------------------------------------------------------
# 14. Нет хардкода приватных ключей в скриптах
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 14. Нет хардкода приватных ключей ---"

foreach ($f in @("scripts/tools/optimize-vpn.sh", "scripts/tools/benchmark.sh")) {
    if (-not (Test-Path $f)) { fail "$f отсутствует"; continue }
    $content = Get-Content $f -Raw
    if ($content -match 'PrivateKey\s*=\s*[A-Za-z0-9+/]{40,}') {
        fail "${f}: содержит хардкод приватного ключа!"
    } else {
        ok "${f}: нет хардкода приватных ключей"
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
