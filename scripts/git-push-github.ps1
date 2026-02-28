# Настройка remote origin для GitHub и push.
# Репозиторий: https://github.com/eightspb/vpn
# Запуск: powershell -ExecutionPolicy Bypass -File scripts/git-push-github.ps1

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

$GitHubUrl = "https://github.com/eightspb/vpn.git"
$RemoteName = "origin"
$Branch = "main"

$remotes = git remote 2>$null
if (-not $remotes -or $remotes -notmatch [regex]::Escape($RemoteName)) {
    Write-Host "Добавляю remote '$RemoteName' -> $GitHubUrl"
    git remote add $RemoteName $GitHubUrl
} else {
    $currentUrl = git remote get-url $RemoteName 2>$null
    if ($currentUrl -ne $GitHubUrl) {
        Write-Host "Обновляю URL remote '$RemoteName' на $GitHubUrl"
        git remote set-url $RemoteName $GitHubUrl
    }
}

Write-Host "Пуш в $RemoteName $Branch ..."
git push -u $RemoteName $Branch
Write-Host "Готово."
