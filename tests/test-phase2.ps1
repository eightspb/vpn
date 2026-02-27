# Phase 2 tests: DNS cache, streaming, connection pooling, MTU in deploy scripts
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
if (-not $root) { $root = (Get-Location).Path }
Set-Location $root
$fail = 0

Write-Host "=== Phase 2: Go build youtube-proxy ==="
Push-Location youtube-proxy
try {
    go build ./...
    Write-Host "OK: youtube-proxy build"
} catch {
    Write-Host "FAIL: youtube-proxy build"
    $fail = 1
} finally { Pop-Location }

Write-Host ""
Write-Host "=== Phase 2: MTU in deploy-vps1.sh ==="
$vps1 = Get-Content deploy-vps1.sh -Raw
if ($vps1 -match "MTU = 1320" -and $vps1 -match "MTU = 1280") {
    Write-Host "OK: deploy-vps1.sh has MTU for awg0 and awg1"
} else {
    Write-Host "FAIL: deploy-vps1.sh expected MTU = 1320 and MTU = 1280"
    $fail = 1
}

Write-Host ""
Write-Host "=== Phase 2: MTU in deploy-vps2.sh ==="
if ((Get-Content deploy-vps2.sh -Raw) -match "MTU = 1280") {
    Write-Host "OK: deploy-vps2.sh has MTU for awg0"
} else {
    Write-Host "FAIL: deploy-vps2.sh expected MTU = 1280"
    $fail = 1
}

Write-Host ""
Write-Host "=== Phase 2: proxy.go connection pooling and streaming ==="
$proxy = Get-Content youtube-proxy/internal/proxy/proxy.go -Raw
if ($proxy -match "MaxIdleConns" -and $proxy -match "io\.Copy\(w, resp\.Body\)") {
    Write-Host "OK: connection pooling and streaming in proxy.go"
} else {
    Write-Host "FAIL: proxy.go expected MaxIdleConns and io.Copy"
    $fail = 1
}

Write-Host ""
Write-Host "=== Phase 2: dns/server.go cache ==="
$dns = Get-Content youtube-proxy/internal/dns/server.go -Raw
if ($dns -match "cacheEntry" -and $dns -match "maxCacheTTL") {
    Write-Host "OK: DNS cache in server.go"
} else {
    Write-Host "FAIL: dns/server.go expected cache"
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
