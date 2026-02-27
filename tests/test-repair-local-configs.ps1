param(
    [string]$ScriptPath = "repair-local-configs.ps1"
)

$ErrorActionPreference = "Stop"
$pass = 0
$fail = 0

function Ok([string]$msg) {
    $script:pass++
    Write-Host "  [PASS] $msg" -ForegroundColor Green
}

function Fail([string]$msg) {
    $script:fail++
    Write-Host "  [FAIL] $msg" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== Test repair-local-configs.ps1 ===" -ForegroundColor Cyan
Write-Host ""

if (Test-Path -LiteralPath $ScriptPath) {
    Ok "Script exists: $ScriptPath"
} else {
    Fail "Script not found: $ScriptPath"
}

if (Get-Command ssh -ErrorAction SilentlyContinue) {
    Ok "ssh command is available"
} else {
    Fail "ssh command is missing"
}

if (Test-Path -LiteralPath ".env") {
    $envContent = Get-Content -LiteralPath ".env" -Raw
    if ($envContent -match "VPS1_IP\s*=")   { Ok ".env contains VPS1_IP" } else { Fail ".env missing VPS1_IP" }
    if ($envContent -match "VPS1_USER\s*=") { Ok ".env contains VPS1_USER" } else { Fail ".env missing VPS1_USER" }
    if ($envContent -match "VPS1_KEY\s*=")  { Ok ".env contains VPS1_KEY" } else { Fail ".env missing VPS1_KEY" }
} else {
    Fail ".env file is missing"
}

if ((Test-Path -LiteralPath "vpn-output/client.conf") -and (Test-Path -LiteralPath "vpn-output/phone.conf")) {
    Ok "Both local config files exist"
} else {
    Fail "Expected vpn-output/client.conf and vpn-output/phone.conf"
}

if (Test-Path -LiteralPath $ScriptPath) {
    try {
        [void][System.Management.Automation.PSParser]::Tokenize((Get-Content -LiteralPath $ScriptPath -Raw), [ref]$null)
        Ok "PowerShell syntax parse succeeded"
    } catch {
        Fail "PowerShell syntax parse failed: $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "=================================" 
Write-Host "Total: PASS=$pass FAIL=$fail"
Write-Host "================================="
Write-Host ""

if ($fail -gt 0) { exit 1 } else { exit 0 }
