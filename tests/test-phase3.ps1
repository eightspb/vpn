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
    "Хардкод устаревшего VPS1 IP отсутствует в scripts/monitor/monitor-realtime.sh" `
    "Хардкод устаревшего VPS1 IP всё ещё присутствует в scripts/monitor/monitor-realtime.sh"

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
    "Хардкод устаревшего VPS1 IP отсутствует в scripts/monitor/monitor-web.sh" `
    "Хардкод устаревшего VPS1 IP всё ещё присутствует в scripts/monitor/monitor-web.sh"

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
$peer_content = Get-Content "scripts/tools/add_phone_peer.sh" -Raw

check ($peer_content -match '--vps1-ip') `
    "scripts/tools/add_phone_peer.sh принимает --vps1-ip" `
    "scripts/tools/add_phone_peer.sh не принимает --vps1-ip"

check ($peer_content -match '--peer-ip') `
    "scripts/tools/add_phone_peer.sh принимает --peer-ip" `
    "scripts/tools/add_phone_peer.sh не принимает --peer-ip"

check ($peer_content -match '--peer-name') `
    "scripts/tools/add_phone_peer.sh принимает --peer-name" `
    "scripts/tools/add_phone_peer.sh не принимает --peer-name"

check ($peer_content -match 'автоопределение|auto.*ip|next.*ip|seq 3 254' -or $peer_content -match 'seq 3') `
    "scripts/tools/add_phone_peer.sh содержит автоопределение IP" `
    "scripts/tools/add_phone_peer.sh не содержит автоопределение IP"

check ($peer_content -match 'load_defaults_from_files') `
    "scripts/tools/add_phone_peer.sh читает .env через load_defaults_from_files" `
    "scripts/tools/add_phone_peer.sh не читает .env"

check (-not ($peer_content -match '10\.9\.0\.3')) `
    "Хардкод 10.9.0.3 убран из scripts/tools/add_phone_peer.sh" `
    "Хардкод 10.9.0.3 всё ещё присутствует в scripts/tools/add_phone_peer.sh"

# ---------------------------------------------------------------------------
# 6. deploy.sh: legacy proxy flags are rejected
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 6. scripts/deploy/deploy.sh: legacy proxy flags rejected ---"
$deploy_content = Get-Content "scripts/deploy/deploy.sh" -Raw

check ($deploy_content -match '--with-proxy\|--remove-adguard') `
    "deploy.sh явно отклоняет --with-proxy/--remove-adguard" `
    "deploy.sh не отклоняет legacy proxy flags"

# ---------------------------------------------------------------------------
# 7. manage.sh: legacy proxy mode is rejected
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 7. manage.sh: legacy proxy mode rejected ---"
$manage_content = Get-Content "manage.sh" -Raw

check ($manage_content -match '--proxy удалён') `
    "manage.sh явно отклоняет --proxy" `
    "manage.sh не отклоняет --proxy"

# ---------------------------------------------------------------------------
# 8. diagnose.sh: AdGuard Home is the DNS service
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 8. scripts/tools/diagnose.sh: AdGuard Home checks ---"
$diagnose_content = Get-Content "scripts/tools/diagnose.sh" -Raw

check ($diagnose_content -match 'AdGuard Home' -and $diagnose_content -match 'port53') `
    "diagnose.sh проверяет AdGuard Home и DNS port 53" `
    "diagnose.sh не проверяет AdGuard Home/DNS"

check ($diagnose_content -match 'systemctl start AdGuardHome' -and $diagnose_content -match 'Восстанавливаю legacy youtube-proxy') `
    "diagnose.sh ремонтирует AdGuard Home и восстанавливает legacy DNS только при rollback" `
    "diagnose.sh не содержит безопасный rollback legacy DNS при ошибке AdGuard"

# ---------------------------------------------------------------------------
# 9. deploy scripts: safe AdGuard switch before legacy cleanup
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- 9. deploy scripts: safe AdGuard switch before legacy cleanup ---"

function firstLine($path, $pattern) {
    $matches = Select-String -Path $path -Pattern $pattern
    if ($matches) { return $matches[0].LineNumber }
    return 0
}

foreach ($deploy_file in @("scripts/deploy/deploy.sh", "scripts/deploy/deploy-vps2.sh")) {
    $content = Get-Content $deploy_file -Raw

    check ($content -match 'ADGUARD_WAS_ACTIVE' -and `
           $content -match 'ADGUARD_CONFIG_BACKUP' -and `
           $content -match 'LEGACY_YOUTUBE_PROXY_ACTIVE' -and `
           $content -match 'restore_previous_dns' -and `
           $content -match 'health_ok') `
        "$deploy_file: есть rollback конфига/сервиса и healthcheck при переключении DNS" `
        "$deploy_file: нет полного rollback/healthcheck при переключении DNS"

    $backup_line = firstLine $deploy_file 'ADGUARD_CONFIG_BACKUP='
    $curl_line = firstLine $deploy_file 'curl -fsSL https://static.adguard.com'
    $health_line = firstLine $deploy_file 'health_ok=false'
    $cleanup_line = firstLine $deploy_file 'rm -rf /opt/youtube-proxy'

    check ($backup_line -gt 0 -and $curl_line -gt $backup_line -and $health_line -gt $curl_line -and $cleanup_line -gt $health_line) `
        "$deploy_file: backup и legacy cleanup выполняются в безопасном порядке" `
        "$deploy_file: backup/cleanup порядок может сломать DNS при неудачном deploy"
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
