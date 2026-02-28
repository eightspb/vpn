# tests/test-phase3.ps1 — проверки Фазы 3 (безопасность и архитектура)
# Запуск: powershell -File tests\test-phase3.ps1

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

function check($condition, $pass_msg, $fail_msg) {
    if ($condition) { ok $pass_msg } else { fail $fail_msg }
}

Write-Host ""
Write-Host "=== Тесты Фазы 3: Безопасность и архитектура ===" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 1. scripts/monitor/monitor-realtime.sh: нет eval
# ---------------------------------------------------------------------------
Write-Host "--- 1. scripts/monitor/monitor-realtime.sh: убран eval ---"
$content = Get-Content "scripts/monitor/monitor-realtime.sh" -Raw

check (-not ($content -match '(?m)^\s*eval\s+"\$data"')) `
    "eval `"`$data`" отсутствует в scripts/monitor/monitor-realtime.sh" `
    "eval `"`$data`" всё ещё присутствует в scripts/monitor/monitor-realtime.sh"

check ($content -match 'parse_kv') `
    "parse_kv присутствует в scripts/monitor/monitor-realtime.sh" `
    "parse_kv не найден в scripts/monitor/monitor-realtime.sh"

# ---------------------------------------------------------------------------
# 2. scripts/monitor/monitor-realtime.sh: нет хардкода IP/ключей
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 2. scripts/monitor/monitor-realtime.sh: нет хардкода дефолтов ---"

check (-not ($content -match '89\.169\.179\.233')) `
    "Хардкод IP 89.169.179.233 отсутствует в scripts/monitor/monitor-realtime.sh" `
    "Хардкод IP 89.169.179.233 всё ещё присутствует в scripts/monitor/monitor-realtime.sh"

check (-not ($content -match '38\.135\.122\.81')) `
    "Хардкод IP 38.135.122.81 отсутствует в scripts/monitor/monitor-realtime.sh" `
    "Хардкод IP 38.135.122.81 всё ещё присутствует в scripts/monitor/monitor-realtime.sh"

check (-not ($content -match 'ssh-key-1772056840349')) `
    "Хардкод SSH-ключа отсутствует в scripts/monitor/monitor-realtime.sh" `
    "Хардкод SSH-ключа всё ещё присутствует в scripts/monitor/monitor-realtime.sh"

# ---------------------------------------------------------------------------
# 3. scripts/monitor/monitor-web.sh: нет хардкода IP/ключей
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 3. scripts/monitor/monitor-web.sh: нет хардкода дефолтов ---"
$web_content = Get-Content "scripts/monitor/monitor-web.sh" -Raw

check (-not ($web_content -match '89\.169\.179\.233')) `
    "Хардкод IP 89.169.179.233 отсутствует в scripts/monitor/monitor-web.sh" `
    "Хардкод IP 89.169.179.233 всё ещё присутствует в scripts/monitor/monitor-web.sh"

check (-not ($web_content -match '38\.135\.122\.81')) `
    "Хардкод IP 38.135.122.81 отсутствует в scripts/monitor/monitor-web.sh" `
    "Хардкод IP 38.135.122.81 всё ещё присутствует в scripts/monitor/monitor-web.sh"

check (-not ($web_content -match 'ssh-key-1772056840349')) `
    "Хардкод SSH-ключа отсутствует в scripts/monitor/monitor-web.sh" `
    "Хардкод SSH-ключа всё ещё присутствует в scripts/monitor/monitor-web.sh"

# ---------------------------------------------------------------------------
# 4. scripts/monitor/monitor-web.sh и scripts/monitor/monitor-realtime.sh: читают .env
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 4. Скрипты читают .env ---"

check ($web_content -match 'load_defaults_from_files') `
    "scripts/monitor/monitor-web.sh вызывает load_defaults_from_files" `
    "scripts/monitor/monitor-web.sh не вызывает load_defaults_from_files"

check ($content -match 'load_defaults_from_files') `
    "scripts/monitor/monitor-realtime.sh вызывает load_defaults_from_files" `
    "scripts/monitor/monitor-realtime.sh не вызывает load_defaults_from_files"

# ---------------------------------------------------------------------------
# 5. add_phone_peer.sh: параметризирован
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 5. add_phone_peer.sh: параметризация ---"
$peer_content = Get-Content "add_phone_peer.sh" -Raw

check ($peer_content -match '--vps1-ip') `
    "add_phone_peer.sh принимает --vps1-ip" `
    "add_phone_peer.sh не принимает --vps1-ip"

check ($peer_content -match '--peer-ip') `
    "add_phone_peer.sh принимает --peer-ip" `
    "add_phone_peer.sh не принимает --peer-ip"

check ($peer_content -match '--peer-name') `
    "add_phone_peer.sh принимает --peer-name" `
    "add_phone_peer.sh не принимает --peer-name"

check ($peer_content -match 'автоопределение|auto.*ip|next.*ip|seq 3 254' -or $peer_content -match 'seq 3') `
    "add_phone_peer.sh содержит автоопределение IP" `
    "add_phone_peer.sh не содержит автоопределение IP"

check ($peer_content -match 'load_defaults_from_files') `
    "add_phone_peer.sh читает .env через load_defaults_from_files" `
    "add_phone_peer.sh не читает .env"

check (-not ($peer_content -match '10\.9\.0\.3')) `
    "Хардкод 10.9.0.3 убран из add_phone_peer.sh" `
    "Хардкод 10.9.0.3 всё ещё присутствует в add_phone_peer.sh"

# ---------------------------------------------------------------------------
# 6. config.yaml: CA-сервер на VPN-интерфейсе
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 6. config.yaml: CA-сервер ограничен VPN-интерфейсом ---"
$yaml_content = Get-Content "youtube-proxy\config.yaml" -Raw

check ($yaml_content -match '10\.8\.0\.2:8080') `
    "CA-сервер слушает на 10.8.0.2:8080 (VPN-интерфейс)" `
    "CA-сервер не ограничен VPN-интерфейсом"

check (-not ($yaml_content -match '0\.0\.0\.0:8080')) `
    "CA-сервер не слушает на 0.0.0.0:8080" `
    "CA-сервер всё ещё слушает на 0.0.0.0:8080"

# ---------------------------------------------------------------------------
# 7. scripts/deploy/deploy-proxy.sh: firewall-правило для порта 8080
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 7. scripts/deploy/deploy-proxy.sh: firewall для CA-сервера ---"
$proxy_content = Get-Content "scripts/deploy/deploy-proxy.sh" -Raw

check ($proxy_content -match 'iptables.*8080.*DROP|DROP.*8080') `
    "scripts/deploy/deploy-proxy.sh блокирует порт 8080 снаружи" `
    "scripts/deploy/deploy-proxy.sh не блокирует порт 8080 снаружи"

check ($proxy_content -match 'iptables.*8080.*awg0|awg0.*8080') `
    "scripts/deploy/deploy-proxy.sh разрешает порт 8080 только через awg0" `
    "scripts/deploy/deploy-proxy.sh не ограничивает 8080 интерфейсом awg0"

check (-not ($proxy_content -match "http://\`$VPS2_IP:8080")) `
    "scripts/deploy/deploy-proxy.sh не содержит публичный URL CA (http://VPS2_IP:8080)" `
    "scripts/deploy/deploy-proxy.sh всё ещё содержит публичный URL CA"

check ($proxy_content -match '10\.8\.0\.2:8080') `
    "scripts/deploy/deploy-proxy.sh указывает VPN-URL для CA (10.8.0.2:8080)" `
    "scripts/deploy/deploy-proxy.sh не содержит VPN-URL для CA"

# ---------------------------------------------------------------------------
# 8. Go build проверка (youtube-proxy)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 8. Go build youtube-proxy ---"

$go_bin = $null
foreach ($candidate in @("go", "$env:USERPROFILE\go\bin\go.exe", "$env:USERPROFILE\go-dist\go\bin\go.exe")) {
    try {
        $null = & $candidate version 2>$null
        $go_bin = $candidate
        break
    } catch {}
}

if ($go_bin) {
    try {
        Push-Location "youtube-proxy"
        & $go_bin build ./... 2>&1 | Out-Null
        ok "go build ./... успешен в youtube-proxy"
    } catch {
        fail "go build ./... завершился с ошибкой: $_"
    } finally {
        Pop-Location
    }
} else {
    Write-Host "  [SKIP] Go не найден, пропускаем go build" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Итог
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "================================" -ForegroundColor Cyan
Write-Host "  PASS: $PASS  |  FAIL: $FAIL" -ForegroundColor $(if ($FAIL -eq 0) { "Green" } else { "Red" })
Write-Host "================================"
Write-Host ""

if ($FAIL -gt 0) {
    exit 1
}
