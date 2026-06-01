# Phase 2 tests: MTU in deploy scripts and legacy proxy cleanup
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
if (-not $root) { $root = (Get-Location).Path }
Set-Location $root
$fail = 0

Write-Host "=== Phase 2: MTU in scripts/deploy/deploy-vps1.sh ==="
$vps1 = Get-Content scripts/deploy/deploy-vps1.sh -Raw
if ($vps1 -match "MTU = 1420" -and $vps1 -match "MTU = 1360") {
    Write-Host "OK: scripts/deploy/deploy-vps1.sh has MTU for awg0 and awg1"
} else {
    Write-Host "FAIL: scripts/deploy/deploy-vps1.sh expected MTU = 1420 and MTU = 1360"
    $fail = 1
}

Write-Host ""
Write-Host "=== Phase 2: MTU in scripts/deploy/deploy-vps2.sh ==="
if ((Get-Content scripts/deploy/deploy-vps2.sh -Raw) -match "MTU = 1420") {
    Write-Host "OK: scripts/deploy/deploy-vps2.sh has MTU for awg0"
} else {
    Write-Host "FAIL: scripts/deploy/deploy-vps2.sh expected MTU = 1420"
    $fail = 1
}

Write-Host ""
Write-Host "=== Phase 2: legacy youtube-proxy removed ==="
if (-not (Test-Path "youtube-proxy") -and -not (Test-Path "scripts/deploy/deploy-proxy.sh")) {
    Write-Host "OK: youtube-proxy code and deploy script removed"
} else {
    Write-Host "FAIL: youtube-proxy legacy files still present"
    $fail = 1
}

$readme = Get-Content README.md -Raw
$manage = Get-Content manage.sh -Raw
if (-not ($readme -match "--with-proxy") -and -not ($manage -match "--with-proxy")) {
    Write-Host "OK: --with-proxy removed from docs/help"
} else {
    Write-Host "FAIL: --with-proxy still referenced in docs/help"
    $fail = 1
}

if (-not ($readme -match "--proxy") -and $manage -match "--proxy удалён") {
    Write-Host "OK: --proxy removed from docs and rejected by manage.sh"
} else {
    Write-Host "FAIL: --proxy docs/rejection state is not correct"
    $fail = 1
}

Write-Host ""
if ($fail -eq 0) {
    Write-Host "=== All Phase 2 checks passed ==="
    exit 0
} else {
    Write-Host "=== Some checks failed ==="
    exit 1
}
