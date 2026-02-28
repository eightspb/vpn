# Тест: скрипт git-push-github и наличие remote origin.
# Проверяет, что remote origin настроен на https://github.com/eightspb/vpn.git
# Запуск: powershell -ExecutionPolicy Bypass -File tests/test-git-push-github.ps1

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

$expectedUrl = "https://github.com/eightspb/vpn.git"
$remoteName = "origin"
$scriptPath = Join-Path $RepoRoot "scripts\git-push-github.ps1"

$fail = 0

# 1) Скрипт существует
if (-not (Test-Path $scriptPath)) {
    Write-Host "FAIL: Скрипт не найден: $scriptPath"
    exit 1
}
Write-Host "OK: Скрипт существует"

# 2) После добавления remote — URL должен быть правильным (проверяем, если origin уже есть)
$remotes = git remote 2>$null
if ($remotes -match [regex]::Escape($remoteName)) {
    $url = git remote get-url $remoteName 2>$null
    if ($url -eq $expectedUrl) {
        Write-Host "OK: remote '$remoteName' указывает на $expectedUrl"
    } else {
        Write-Host "FAIL: remote '$remoteName' URL = '$url', ожидалось '$expectedUrl'"
        $fail = 1
    }
} else {
    Write-Host "OK: remote '$remoteName' ещё не добавлен (скрипт добавит при первом запуске)"
}

if ($fail -ne 0) { exit 1 }
Write-Host "Все проверки пройдены."
