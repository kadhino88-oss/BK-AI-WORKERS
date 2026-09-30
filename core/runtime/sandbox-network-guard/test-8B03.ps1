$ErrorActionPreference = "Stop"

$Module = Join-Path $PSScriptRoot "SANDBOX-NETWORK-EXTERNAL-IO-GUARD.ps1"

. $Module

Initialize-SandboxNetworkGuard | Out-Null

$script:Total = 0
$script:Pass = 0
$script:Fail = 0

function Run-Test {
    param(
        [string]$TestName,
        [scriptblock]$TestAction,
        [bool]$ExpectThrow
    )

    $script:Total++

    try {
        & $TestAction | Out-Null

        if ($ExpectThrow) {
            Write-Host ("[{0:00}] [FAIL] {1}" -f $script:Total,$TestName)
            $script:Fail++
        }
        else {
            Write-Host ("[{0:00}] [PASS] {1}" -f $script:Total,$TestName)
            $script:Pass++
        }
    }
    catch {
        if ($ExpectThrow) {
            Write-Host ("[{0:00}] [PASS] {1} -> {2}" -f $script:Total,$TestName,$_.Exception.Message)
            $script:Pass++
        }
        else {
            Write-Host ("[{0:00}] [FAIL] {1} -> {2}" -f $script:Total,$TestName,$_.Exception.Message)
            $script:Fail++
        }
    }
}

# 01
Run-Test "Module present" {
    if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) {
        throw "MODULE_MISSING"
    }
} $false

# 02
Run-Test "State SANDBOX" {
    $s = Get-SandboxNetworkGuardState
    if ($s.Mode -ne "SANDBOX") { throw "BAD_MODE" }
} $false

# 03
Run-Test "Network disabled" {
    $s = Get-SandboxNetworkGuardState
    if ($s.NetworkEnabled -ne $false) { throw "NETWORK_ENABLED" }
} $false

# 04
Run-Test "External IO disabled" {
    $s = Get-SandboxNetworkGuardState
    if ($s.ExternalIOEnabled -ne $false) { throw "EXTERNAL_IO_ENABLED" }
} $false

# 05
Run-Test "Provider network disabled" {
    $s = Get-SandboxNetworkGuardState
    if ($s.ProviderNetworkEnabled -ne $false) { throw "PROVIDER_NETWORK_ENABLED" }
} $false

# 06
Run-Test "Connector network disabled" {
    $s = Get-SandboxNetworkGuardState
    if ($s.ConnectorNetworkEnabled -ne $false) { throw "CONNECTOR_NETWORK_ENABLED" }
} $false

# 07
Run-Test "Filesystem external write disabled" {
    $s = Get-SandboxNetworkGuardState
    if ($s.FilesystemExternalWriteEnabled -ne $false) { throw "FILESYSTEM_WRITE_ENABLED" }
} $false

# 08
Run-Test "Process spawn disabled" {
    $s = Get-SandboxNetworkGuardState
    if ($s.ProcessSpawnEnabled -ne $false) { throw "PROCESS_SPAWN_ENABLED" }
} $false

# 09
Run-Test "DNS disabled" {
    $s = Get-SandboxNetworkGuardState
    if ($s.DNSResolutionEnabled -ne $false) { throw "DNS_ENABLED" }
} $false

# 10
Run-Test "Outbound HTTP disabled" {
    $s = Get-SandboxNetworkGuardState
    if ($s.OutboundHTTPEnabled -ne $false) { throw "HTTP_ENABLED" }
} $false

# 11
Run-Test "Sandbox access neutral autorise" {
    $r = Test-SandboxNetworkAccess `
        -Environment "SANDBOX" `
        -Mode "SANDBOX"

    if ($r.Decision -ne "ALLOW") {
        throw "SANDBOX_NOT_ALLOWED"
    }
} $false

# 12
Run-Test "Network request bloque" {
    Test-SandboxNetworkAccess `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestNetwork $true
} $true

# 13
Run-Test "External IO bloque" {
    Test-SandboxNetworkAccess `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestExternalIO $true
} $true

# 14
Run-Test "Provider network bloque" {
    Test-SandboxNetworkAccess `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -ProviderNetwork $true
} $true

# 15
Run-Test "Connector network bloque" {
    Test-SandboxNetworkAccess `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -ConnectorNetwork $true
} $true

# 16
Run-Test "Filesystem externe bloque" {
    Test-SandboxNetworkAccess `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -FilesystemExternalWrite $true
} $true

# 17
Run-Test "Process spawn bloque" {
    Test-SandboxNetworkAccess `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -ProcessSpawn $true
} $true

# 18
Run-Test "DNS bloque" {
    Test-SandboxNetworkAccess `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -DNSResolution $true
} $true

# 19
Run-Test "Outbound HTTP bloque" {
    Test-SandboxNetworkAccess `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -OutboundHTTP $true
} $true

# 20
Run-Test "LIVE environment bloque" {
    Test-SandboxNetworkAccess `
        -Environment "LIVE" `
        -Mode "LIVE"
} $true

# 21
Run-Test "Mode LIVE bloque" {
    Test-SandboxNetworkAccess `
        -Environment "SANDBOX" `
        -Mode "LIVE"
} $true

# 22
Run-Test "Environment vide bloque" {
    Test-SandboxNetworkAccess `
        -Environment "" `
        -Mode "SANDBOX"
} $true

# 23
Run-Test "Mode vide bloque" {
    Test-SandboxNetworkAccess `
        -Environment "SANDBOX" `
        -Mode ""
} $true

# 24
Run-Test "Fail closed combinaison externe" {
    Assert-SandboxNetworkAccess `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestNetwork $true `
        -RequestExternalIO $true `
        -ProviderNetwork $true `
        -ConnectorNetwork $true `
        -FilesystemExternalWrite $true `
        -ProcessSpawn $true `
        -DNSResolution $true `
        -OutboundHTTP $true
} $true

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTAT 8B-03"
Write-Host "============================================================"
Write-Host ("TOTAL TESTS : {0}" -f $script:Total)
Write-Host ("PASS        : {0}" -f $script:Pass)
Write-Host ("FAIL        : {0}" -f $script:Fail)
Write-Host ""

if (($script:Total -eq 24) -and ($script:Pass -eq 24) -and ($script:Fail -eq 0)) {
    Write-Host "8B-03 : VALIDEE - 24/24" -ForegroundColor Green
}
else {
    Write-Host "8B-03 : NON VALIDEE" -ForegroundColor Red
}

Write-Host "============================================================"
Write-Host "8B-03 - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"