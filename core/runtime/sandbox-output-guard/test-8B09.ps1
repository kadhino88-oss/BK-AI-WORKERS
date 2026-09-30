$ErrorActionPreference = "Stop"

$Module = Join-Path $PSScriptRoot "SANDBOX-OUTPUT-DATA-EXFILTRATION-GUARD.ps1"

. $Module

Initialize-SandboxOutputGuard | Out-Null

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
    $s = Get-SandboxOutputGuardState
    if ($s.Mode -ne "SANDBOX") { throw "BAD_MODE" }
} $false

# 03
Run-Test "External output disabled" {
    if ((Get-SandboxOutputGuardState).ExternalOutputAllowed -ne $false) {
        throw "EXTERNAL_OUTPUT_ENABLED"
    }
} $false

# 04
Run-Test "Network output disabled" {
    if ((Get-SandboxOutputGuardState).NetworkOutputAllowed -ne $false) {
        throw "NETWORK_OUTPUT_ENABLED"
    }
} $false

# 05
Run-Test "Provider output disabled" {
    if ((Get-SandboxOutputGuardState).ProviderOutputAllowed -ne $false) {
        throw "PROVIDER_OUTPUT_ENABLED"
    }
} $false

# 06
Run-Test "Connector output disabled" {
    if ((Get-SandboxOutputGuardState).ConnectorOutputAllowed -ne $false) {
        throw "CONNECTOR_OUTPUT_ENABLED"
    }
} $false

# 07
Run-Test "External file export disabled" {
    if ((Get-SandboxOutputGuardState).ExternalFileExportAllowed -ne $false) {
        throw "FILE_EXPORT_ENABLED"
    }
} $false

# 08
Run-Test "Clipboard export disabled" {
    if ((Get-SandboxOutputGuardState).ClipboardExportAllowed -ne $false) {
        throw "CLIPBOARD_ENABLED"
    }
} $false

# 09
Run-Test "Secret output disabled" {
    if ((Get-SandboxOutputGuardState).SecretOutputAllowed -ne $false) {
        throw "SECRET_OUTPUT_ENABLED"
    }
} $false

# 10
Run-Test "Cross tenant output disabled" {
    if ((Get-SandboxOutputGuardState).CrossTenantOutputAllowed -ne $false) {
        throw "CROSS_TENANT_OUTPUT_ENABLED"
    }
} $false

# 11
Run-Test "Request neutre autorisee" {
    $r = Test-SandboxOutputRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX"

    if ($r.Decision -ne "ALLOW") {
        throw "NEUTRAL_REQUEST_BLOCKED"
    }
} $false

# 12
Run-Test "External output bloque" {
    Test-SandboxOutputRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestExternalOutput $true
} $true

# 13
Run-Test "Network output bloque" {
    Test-SandboxOutputRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestNetworkOutput $true
} $true

# 14
Run-Test "Provider output bloque" {
    Test-SandboxOutputRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestProviderOutput $true
} $true

# 15
Run-Test "Connector output bloque" {
    Test-SandboxOutputRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestConnectorOutput $true
} $true

# 16
Run-Test "Export fichier externe bloque" {
    Test-SandboxOutputRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestExternalFileExport $true
} $true

# 17
Run-Test "Clipboard bloque" {
    Test-SandboxOutputRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestClipboardExport $true
} $true

# 18
Run-Test "Redirection output bloquee" {
    Test-SandboxOutputRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestRedirectOutput $true
} $true

# 19
Run-Test "Secret output bloque" {
    Test-SandboxOutputRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestSecretOutput $true
} $true

# 20
Run-Test "Cross tenant bloque" {
    Test-SandboxOutputRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestCrossTenantOutput $true
} $true

# 21
Run-Test "LIVE environment bloque" {
    Test-SandboxOutputRequest `
        -Environment "LIVE" `
        -Mode "LIVE"
} $true

# 22
Run-Test "Mode LIVE bloque" {
    Test-SandboxOutputRequest `
        -Environment "SANDBOX" `
        -Mode "LIVE"
} $true

# 23
Run-Test "Assert output neutre autorise" {
    $r = Assert-SandboxOutputRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX"

    if ($r.Isolated -ne $true) {
        throw "ASSERT_ISOLATION_FAILED"
    }
} $false

# 24
Run-Test "Fail closed exfiltration combinee" {
    Assert-SandboxOutputRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestExternalOutput $true `
        -RequestNetworkOutput $true `
        -RequestProviderOutput $true `
        -RequestConnectorOutput $true `
        -RequestExternalFileExport $true `
        -RequestClipboardExport $true `
        -RequestRedirectOutput $true `
        -RequestSecretOutput $true `
        -RequestCrossTenantOutput $true
} $true

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTAT 8B-09"
Write-Host "============================================================"
Write-Host ("TOTAL TESTS : {0}" -f $script:Total)
Write-Host ("PASS        : {0}" -f $script:Pass)
Write-Host ("FAIL        : {0}" -f $script:Fail)
Write-Host ""

if (($script:Total -eq 24) -and ($script:Pass -eq 24) -and ($script:Fail -eq 0)) {
    Write-Host "8B-09 : VALIDEE - 24/24" -ForegroundColor Green
}
else {
    Write-Host "8B-09 : NON VALIDEE" -ForegroundColor Red
}

Write-Host "============================================================"
Write-Host "8B-09 - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"