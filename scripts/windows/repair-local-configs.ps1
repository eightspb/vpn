param(
    [string]$Vps1Ip = "",
    [string]$Vps1User = "",
    [string]$Vps1Key = "",
    [string]$ClientConfPath = "vpn-output/client.conf",
    [string]$PhoneConfPath = "vpn-output/phone.conf"
)

$ErrorActionPreference = "Stop"

function Read-DotEnvValue {
    param(
        [string]$FilePath,
        [string]$Key
    )
    if (-not (Test-Path -LiteralPath $FilePath)) { return "" }
    $line = Get-Content -LiteralPath $FilePath |
        Where-Object { $_ -match "^\s*$([regex]::Escape($Key))\s*=" } |
        Select-Object -Last 1
    if (-not $line) { return "" }
    $value = ($line -split "=", 2)[1].Trim()
    $value = $value.Trim("'").Trim('"')
    return $value
}

function Expand-KeyPath {
    param([string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return "" }
    if ($PathValue.StartsWith("~/")) {
        $userHome = $env:USERPROFILE
        return (Join-Path $userHome $PathValue.Substring(2))
    }
    return $PathValue
}

function Invoke-Ssh {
    param(
        [string]$ServerIp,
        [string]$User,
        [string]$KeyPath,
        [string]$Command
    )
    $sshArgs = @(
        "-i", $KeyPath,
        "-o", "StrictHostKeyChecking=accept-new",
        "$User@$ServerIp",
        $Command
    )
    $result = & ssh @sshArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "SSH command failed: $Command`n$result"
    }
    return ($result | Out-String).Trim()
}

function Get-ConfValue {
    param(
        [string[]]$Lines,
        [string]$Key
    )
    $line = $Lines | Where-Object { $_ -match "^\s*$([regex]::Escape($Key))\s*=" } | Select-Object -First 1
    if (-not $line) { return "" }
    return ($line -split "=", 2)[1].Trim()
}

function New-ConfigText {
    param(
        [string]$PrivateKey,
        [string]$Address,
        [string]$Dns,
        [string]$ServerPubKey,
        [string]$Endpoint,
        [string]$ProfileName,
        [string[]]$JunkLines
    )

    $parts = @()
    $parts += "# Name = $ProfileName"
    $parts += ""
    $parts += "[Interface]"
    $parts += "Address    = $Address"
    $parts += "PrivateKey = $PrivateKey"
    $parts += "DNS        = $Dns"
    $parts += "MTU        = 1280"
    if ($JunkLines.Count -gt 0) {
        $parts += ""
        $parts += "# AmneziaWG junk parameters"
        $parts += $JunkLines
    }
    $parts += ""
    $parts += "[Peer]"
    $parts += "PublicKey           = $ServerPubKey"
    $parts += "Endpoint            = $Endpoint"
    $parts += "AllowedIPs          = 0.0.0.0/0"
    $parts += "PersistentKeepalive = 25"
    return ($parts -join "`n") + "`n"
}

if (-not (Test-Path -LiteralPath $ClientConfPath)) {
    throw "Client config not found: $ClientConfPath"
}
if (-not (Test-Path -LiteralPath $PhoneConfPath)) {
    throw "Phone config not found: $PhoneConfPath"
}

if ([string]::IsNullOrWhiteSpace($Vps1Ip)) {
    $Vps1Ip = Read-DotEnvValue -FilePath ".env" -Key "VPS1_IP"
}
if ([string]::IsNullOrWhiteSpace($Vps1User)) {
    $Vps1User = Read-DotEnvValue -FilePath ".env" -Key "VPS1_USER"
}
if ([string]::IsNullOrWhiteSpace($Vps1Key)) {
    $Vps1Key = Read-DotEnvValue -FilePath ".env" -Key "VPS1_KEY"
}

$Vps1Key = Expand-KeyPath $Vps1Key

if ([string]::IsNullOrWhiteSpace($Vps1Ip))   { throw "VPS1_IP is required (via .env or parameter)" }
if ([string]::IsNullOrWhiteSpace($Vps1User)) { $Vps1User = "root" }
if ([string]::IsNullOrWhiteSpace($Vps1Key))  { throw "VPS1_KEY is required (via .env or parameter)" }
if (-not (Test-Path -LiteralPath $Vps1Key))  { throw "SSH key not found: $Vps1Key" }

Write-Host ""
Write-Host "=== Repair local VPN configs (client + phone) ===" -ForegroundColor Cyan
Write-Host "VPS1: $Vps1User@$Vps1Ip" -ForegroundColor Gray
Write-Host ""

$clientLines = Get-Content -LiteralPath $ClientConfPath
$phoneLines  = Get-Content -LiteralPath $PhoneConfPath

$clientPriv = Get-ConfValue -Lines $clientLines -Key "PrivateKey"
$phonePriv  = Get-ConfValue -Lines $phoneLines  -Key "PrivateKey"

if ([string]::IsNullOrWhiteSpace($clientPriv)) { throw "PrivateKey not found in $ClientConfPath" }
if ([string]::IsNullOrWhiteSpace($phonePriv))  { throw "PrivateKey not found in $PhoneConfPath" }

Write-Host "[1/6] Read server parameters..." -ForegroundColor Yellow
$serverPub = Invoke-Ssh -ServerIp $Vps1Ip -User $Vps1User -KeyPath $Vps1Key -Command "sudo awg show awg1 public-key"
$serverName = Invoke-Ssh -ServerIp $Vps1Ip -User $Vps1User -KeyPath $Vps1Key -Command "hostname -f 2>/dev/null || hostname"
$serverName = $serverName.Trim()
if ([string]::IsNullOrWhiteSpace($serverName)) { $serverName = $Vps1Ip }
$junkRaw = Invoke-Ssh -ServerIp $Vps1Ip -User $Vps1User -KeyPath $Vps1Key -Command "sudo awk '/^\[Interface\]/{f=1;next} f && /^\[/{exit} f && /^(Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4)[[:space:]]*=/{print}' /etc/amnezia/amneziawg/awg1.conf"
$junkLines = @()
if (-not [string]::IsNullOrWhiteSpace($junkRaw)) {
    $junkLines = @($junkRaw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

Write-Host "[2/6] Derive peer public keys from local PrivateKey..." -ForegroundColor Yellow
$clientPub = Invoke-Ssh -ServerIp $Vps1Ip -User $Vps1User -KeyPath $Vps1Key -Command "printf '%s' '$clientPriv' | sudo awg pubkey"
$phonePub  = Invoke-Ssh -ServerIp $Vps1Ip -User $Vps1User -KeyPath $Vps1Key -Command "printf '%s' '$phonePriv' | sudo awg pubkey"

Write-Host "[3/6] Check peers on VPS1..." -ForegroundColor Yellow
$allowedRaw = Invoke-Ssh -ServerIp $Vps1Ip -User $Vps1User -KeyPath $Vps1Key -Command "sudo awg show awg1 allowed-ips"
$allowedLines = @($allowedRaw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

$clientExists = $false
$phoneExists = $false
$ip03Busy = $false

foreach ($line in $allowedLines) {
    if ($line -match "^\s*(\S+)\s+(\S+)") {
        $pub = $matches[1]
        $ip = $matches[2]
        if ($pub -eq $clientPub -and $ip -eq "10.9.0.2/32") { $clientExists = $true }
        if ($pub -eq $phonePub  -and $ip -eq "10.9.0.3/32") { $phoneExists = $true }
        if ($pub -ne $phonePub  -and $ip -eq "10.9.0.3/32") { $ip03Busy = $true }
    }
}

if (-not $clientExists) {
    Write-Host "  client peer missing on server, adding 10.9.0.2/32..." -ForegroundColor Yellow
    $addClientCmd = "printf '\n# client (repaired)\n[Peer]\nPublicKey  = $clientPub\nAllowedIPs = 10.9.0.2/32\n' | sudo tee -a /etc/amnezia/amneziawg/awg1.conf >/dev/null && sudo awg set awg1 peer '$clientPub' allowed-ips 10.9.0.2/32"
    [void](Invoke-Ssh -ServerIp $Vps1Ip -User $Vps1User -KeyPath $Vps1Key -Command $addClientCmd)
}

if (-not $phoneExists) {
    if ($ip03Busy) {
        throw "Cannot add phone peer: IP 10.9.0.3/32 is already used by another peer on VPS1."
    }
    Write-Host "  phone peer missing on server, adding 10.9.0.3/32..." -ForegroundColor Yellow
    $addPhoneCmd = "printf '\n# phone (repaired)\n[Peer]\nPublicKey  = $phonePub\nAllowedIPs = 10.9.0.3/32\n' | sudo tee -a /etc/amnezia/amneziawg/awg1.conf >/dev/null && sudo awg set awg1 peer '$phonePub' allowed-ips 10.9.0.3/32"
    [void](Invoke-Ssh -ServerIp $Vps1Ip -User $Vps1User -KeyPath $Vps1Key -Command $addPhoneCmd)
}

Write-Host "[4/6] Rebuild local config files..." -ForegroundColor Yellow
$endpoint = "$Vps1Ip`:51820"
$dns = "10.8.0.2"

$clientOut = New-ConfigText -PrivateKey $clientPriv -Address "10.9.0.2/24" -Dns $dns -ServerPubKey $serverPub -Endpoint $endpoint -ProfileName "$serverName - client" -JunkLines $junkLines
$phoneOut  = New-ConfigText -PrivateKey $phonePriv  -Address "10.9.0.3/24" -Dns $dns -ServerPubKey $serverPub -Endpoint $endpoint -ProfileName "$serverName - phone" -JunkLines $junkLines

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $ClientConfPath), $clientOut, $utf8NoBom)
[System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $PhoneConfPath), $phoneOut, $utf8NoBom)

Write-Host "[5/6] Validate peers on server..." -ForegroundColor Yellow
$allowedFinal = Invoke-Ssh -ServerIp $Vps1Ip -User $Vps1User -KeyPath $Vps1Key -Command "sudo awg show awg1 allowed-ips"
if ($allowedFinal -notmatch [regex]::Escape("$clientPub`t10.9.0.2/32") -and $allowedFinal -notmatch [regex]::Escape("$clientPub 10.9.0.2/32")) {
    throw "Validation failed: client peer not found with 10.9.0.2/32"
}
if ($allowedFinal -notmatch [regex]::Escape("$phonePub`t10.9.0.3/32") -and $allowedFinal -notmatch [regex]::Escape("$phonePub 10.9.0.3/32")) {
    throw "Validation failed: phone peer not found with 10.9.0.3/32"
}

Write-Host "[6/6] Done." -ForegroundColor Green
Write-Host ""
Write-Host "Updated files:" -ForegroundColor Green
Write-Host "  - $ClientConfPath"
Write-Host "  - $PhoneConfPath"
Write-Host ""
Write-Host "Server values used:" -ForegroundColor Gray
Write-Host "  PublicKey: $serverPub"
Write-Host "  Endpoint : $endpoint"
Write-Host ""
