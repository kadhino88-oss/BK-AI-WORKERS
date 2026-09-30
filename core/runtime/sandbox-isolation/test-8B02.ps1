$ErrorActionPreference = "Stop"

$Module = Join-Path $PSScriptRoot "SANDBOX-LIVE-ISOLATION-GUARD.ps1"

. $Module

Initialize-SandboxIsolationState | Out-Null

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
Run-Test "Sandbox state ready" {
    $s = Get-SandboxIsolationState
    if ($s.SandboxEnabled -ne $true) { throw "SANDBOX_DISABLED" }
} $false

# 03
Run-Test "Live disabled" {
    $s = Get-SandboxIsolationState
    if ($s.LiveEnabled -ne $false) { throw "LIVE_ENABLED" }
} $false

# 04
Run-Test "Sandbox mode accepted" {
    $r = Test-SandboxLiveIsolation -Environment "SANDBOX" -Mode "SANDBOX"
    if ($r.Decision -ne "ALLOW") { throw "SANDBOX_NOT_ALLOWED" }
} $false

# 05
Run-Test "Sandbox isolated flag" {
    $r = Test-SandboxLiveIsolation -Environment "SANDBOX" -Mode "SANDBOX"
    if ($r.Isolated -ne $true) { throw "NOT_ISOLATED" }
} $false

# 06
Run-Test "Sandbox live flag false" {
    $r = Test-SandboxLiveIsolation -Environment "SANDBOX" -Mode "SANDBOX"
    if ($r.LiveEnabled -ne $false) { throw "LIVE_FLAG_INVALID" }
} $false

# 07
Run-Test "Provider live interdit" {
    Test-SandboxLiveIsolation `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -UseLiveProvider $true
} $true

# 08
Run-Test "Connector live interdit" {
    Test-SandboxLiveIsolation `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -UseLiveConnector $true
} $true

# 09
Run-Test "Demande LIVE interdite" {
    Test-SandboxLiveIsolation `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestLive $true
} $true

# 10
Run-Test "Cross environment interdit" {
    Test-SandboxLiveIsolation `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -CrossEnvironmentExecution $true
} $true

# 11
Run-Test "Mode LIVE dans sandbox interdit" {
    Test-SandboxLiveIsolation `
        -Environment "SANDBOX" `
        -Mode "LIVE"
} $true

# 12
Run-Test "Environment LIVE interdit" {
    Test-SandboxLiveIsolation `
        -Environment "LIVE" `
        -Mode "LIVE"
} $true

# 13
Run-Test "Environment inconnue interdite" {
    Test-SandboxLiveIsolation `
        -Environment "UNKNOWN" `
        -Mode "UNKNOWN"
} $true

# 14
Run-Test "Environment vide interdite" {
    Test-SandboxLiveIsolation `
        -Environment "" `
        -Mode "SANDBOX"
} $true

# 15
Run-Test "Mode vide interdit" {
    Test-SandboxLiveIsolation `
        -Environment "SANDBOX" `
        -Mode ""
} $true

# 16
Run-Test "Assert sandbox valide" {
    $r = Assert-SandboxLiveIsolation `
        -Environment "SANDBOX" `
        -Mode "SANDBOX"

    if ($r.Isolated -ne $true) {
        throw "ASSERT_FAILED"
    }
} $false

# 17
Run-Test "Assert bloque provider live" {
    Assert-SandboxLiveIsolation `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -UseLiveProvider $true
} $true

# 18
Run-Test "Assert bloque connector live" {
    Assert-SandboxLiveIsolation `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -UseLiveConnector $true
} $true

# 19
Run-Test "Assert bloque demande live" {
    Assert-SandboxLiveIsolation `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestLive $true
} $true

# 20
Run-Test "Etat persiste sandbox" {
    $s = Get-SandboxIsolationState
    if ($s.SandboxEnabled -ne $true) { throw "SANDBOX_STATE_BAD" }
    if ($s.LiveEnabled -ne $false) { throw "LIVE_STATE_BAD" }
} $false

# 21
Run-Test "Sandbox provider live false" {
    $s = Get-SandboxIsolationState
    if ($s.SandboxMayUseLiveProvider -ne $false) {
        throw "PROVIDER_ISOLATION_BAD"
    }
} $false

# 22
Run-Test "Sandbox connector live false" {
    $s = Get-SandboxIsolationState
    if ($s.SandboxMayUseLiveConnector -ne $false) {
        throw "CONNECTOR_ISOLATION_BAD"
    }
} $false

# 23
Run-Test "Sandbox cross environment false" {
    $s = Get-SandboxIsolationState
    if ($s.CrossEnvironmentExecution -ne $false) {
        throw "CROSS_ENVIRONMENT_STATE_BAD"
    }
} $false

# 24
Run-Test "Fail closed securite sandbox" {
    Assert-SandboxLiveIsolation `
        -Environment "LIVE" `
        -Mode "LIVE" `
        -RequestLive $true `
        -UseLiveProvider $true `
        -UseLiveConnector $true `
        -CrossEnvironmentExecution $true
} $true

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "RESULTAT 8B-02" -ForegroundColor Cyan
Write-Host "============================================================"
Write-Host ("TOTAL TESTS : {0}" -f $script:Total)
Write-Host ("PASS        : {0}" -f $script:Pass)
Write-Host ("FAIL        : {0}" -f $script:Fail)
Write-Host ""

if (($script:Total -eq 24) -and ($script:Pass -eq 24) -and ($script:Fail -eq 0)) {
    Write-Host "8B-02 : VALIDEE - 24/24" -ForegroundColor Green
}
else {
    Write-Host "8B-02 : NON VALIDEE" -ForegroundColor Red
}

Write-Host "============================================================"
Write-Host "8B-02 - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"