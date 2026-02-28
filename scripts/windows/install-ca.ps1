# install-ca.ps1 — Установка Root CA сертификата youtube-proxy на Windows
# Запускать ПОСЛЕ подключения к VPN.
#
# Использование:
#   powershell -ExecutionPolicy Bypass -File install-ca.ps1
#
# Что делает:
#   1. Скачивает CA-сертификат с VPS2 (доступен только через VPN)
#   2. Устанавливает его в хранилище Trusted Root CAs Windows
#   3. После установки YouTube работает без рекламы через VPN

param(
    [string]$CaUrl = "http://10.8.0.2:8080/ca.crt",
    [string]$OutFile = "$env:TEMP\vpn-ca.crt"
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== Установка Root CA для YouTube Proxy ===" -ForegroundColor Cyan
Write-Host ""

# Проверяем подключение к VPN
Write-Host "[1/3] Проверка подключения к VPN (10.9.0.1)..." -ForegroundColor Yellow
$vpnCheck = Test-Connection -ComputerName "10.9.0.1" -Count 1 -Quiet -ErrorAction SilentlyContinue
if (-not $vpnCheck) {
    Write-Host "ОШИБКА: VPN не подключён. Сначала подключитесь к VPN." -ForegroundColor Red
    Write-Host "  Откройте AmneziaWG и подключитесь к профилю VPN." -ForegroundColor Red
    exit 1
}
Write-Host "  VPN подключён." -ForegroundColor Green

# Скачиваем CA-сертификат
Write-Host "[2/3] Скачивание CA-сертификата с $CaUrl..." -ForegroundColor Yellow
try {
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($CaUrl, $OutFile)
    Write-Host "  Сертификат сохранён: $OutFile" -ForegroundColor Green
} catch {
    Write-Host "ОШИБКА: Не удалось скачать сертификат." -ForegroundColor Red
    Write-Host "  URL: $CaUrl" -ForegroundColor Red
    Write-Host "  Убедитесь, что VPN подключён и youtube-proxy запущен на VPS2." -ForegroundColor Red
    Write-Host "  Детали: $_" -ForegroundColor Red
    exit 1
}

# Устанавливаем в Trusted Root CAs
Write-Host "[3/3] Установка сертификата в Trusted Root CAs..." -ForegroundColor Yellow
try {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($OutFile)
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
        [System.Security.Cryptography.X509Certificates.StoreName]::Root,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
    )
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)

    # Проверяем, не установлен ли уже
    $existing = $store.Certificates | Where-Object { $_.Subject -eq $cert.Subject }
    if ($existing) {
        Write-Host "  Сертификат уже установлен: $($cert.Subject)" -ForegroundColor Green
    } else {
        $store.Add($cert)
        Write-Host "  Сертификат установлен: $($cert.Subject)" -ForegroundColor Green
    }
    $store.Close()
} catch {
    Write-Host "ОШИБКА: Не удалось установить сертификат." -ForegroundColor Red
    Write-Host "  Запустите PowerShell от имени администратора." -ForegroundColor Red
    Write-Host "  Детали: $_" -ForegroundColor Red
    exit 1
} finally {
    Remove-Item $OutFile -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=== Готово! ===" -ForegroundColor Green
Write-Host ""
Write-Host "Root CA установлен. Теперь:" -ForegroundColor White
Write-Host "  - YouTube работает без рекламы через VPN" -ForegroundColor Green
Write-Host "  - Перезапустите браузер если YouTube всё ещё показывает ошибку SSL" -ForegroundColor Yellow
Write-Host ""
Write-Host "Для удаления сертификата:" -ForegroundColor Gray
Write-Host "  certmgr.msc → Trusted Root Certification Authorities → найти 'YouTube Proxy CA'" -ForegroundColor Gray
Write-Host ""
