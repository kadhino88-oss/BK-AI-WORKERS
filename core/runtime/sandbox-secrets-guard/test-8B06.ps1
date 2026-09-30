$ErrorActionPreference = "Stop"

$Module = Join-Path $PSScriptRoot "SANDBOX-MEMORY-SECRETS-GUARD.ps1"

. $Module

Initialize-SandboxSecretsGuard | Out-Null

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

Run-Test "Module present" {
    if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) {
        throw "MODULE_MISSING"
    }
} $false

Run-Test "State SANDBOX" {
    $s = Get-SandboxSecretsGuardState
    if ($s.Mode -ne "SANDBOX") { throw "BAD_MODE" }
} $false

Run-Test "Secrets disabled" {
    $s = Get-SandboxSecretsGuardState
    if ($s.SecretsAllowed -ne $false) { throw "SECRETS_ENABLED" }
} $false

Run-Test "Environment secrets disabled" {
    $s = Get-SandboxSecretsGuardState
    if ($s.EnvironmentSecretsAllowed -ne $false) { throw "ENVIRONMENT_SECRETS_ENABLED" }
} $false

Run-Test "Provider secrets disabled" {
    $s = Get-SandboxSecretsGuardState
    if ($s.ProviderSecretsAllowed -ne $false) { throw "PROVIDER_SECRETS_ENABLED" }
} $false

Run-Test "Connector secrets disabled" {
    $s = Get-SandboxSecretsGuardState
    if ($s.ConnectorSecretsAllowed -ne $false) { throw "CONNECTOR_SECRETS_ENABLED" }
} $false

Run-Test "Credential materialization disabled" {
    $s = Get-SandboxSecretsGuardState
    if ($s.CredentialMaterializationAllowed -ne $false) { throw "CREDENTIAL_MATERIALIZATION_ENABLED" }
} $false

Run-Test "Secret export disabled" {
    $s = Get-SandboxSecretsGuardState
    if ($s.SecretExportAllowed -ne $false) { throw "SECRET_EXPORT_ENABLED" }
} $false

Run-Test "Secret logging disabled" {
    $s = Get-SandboxSecretsGuardState
    if ($s.SecretLoggingAllowed -ne $false) { throw "SECRET_LOGGING_ENABLED" }
} $false

Run-Test "Memory secret persistence disabled" {
    $s = Get-SandboxSecretsGuardState
    if ($s.MemorySecretPersistenceAllowed -ne $false) { throw "MEMORY_SECRET_ENABLED" }
} $false

Run-Test "Request neutre autorisee" {
    $r = Test-SandboxSecretRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX"

    if ($r.Decision -ne "ALLOW") {
        throw "NEUTRAL_REQUEST_BLOCKED"
    }
} $false

Run-Test "Secrets bloque" {
    Test-SandboxSecretRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestSecrets $true
} $true

Run-Test "Secrets environnement bloques" {
    Test-SandboxSecretRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestEnvironmentSecrets $true
} $true

Run-Test "Secrets provider bloques" {
    Test-SandboxSecretRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestProviderSecrets $true
} $true

Run-Test "Secrets connector bloques" {
    Test-SandboxSecretRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestConnectorSecrets $true
} $true

Run-Test "Materialisation credential bloquee" {
    Test-SandboxSecretRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestCredentialMaterialization $true
} $true

Run-Test "Export secret bloque" {
    Test-SandboxSecretRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestSecretExport $true
} $true

Run-Test "Logging secret bloque" {
    Test-SandboxSecretRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestSecretLogging $true
} $true

Run-Test "Persistence secret memoire bloquee" {
    Test-SandboxSecretRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestMemorySecretPersistence $true
} $true

Run-Test "LIVE environment bloque" {
    Test-SandboxSecretRequest `
        -Environment "LIVE" `
        -Mode "LIVE"
} $true

Run-Test "Mode LIVE bloque" {
    Test-SandboxSecretRequest `
        -Environment "SANDBOX" `
        -Mode "LIVE"
} $true


Run-Test "Mode vide bloque" {
    Test-SandboxSecretRequest `
        -Environment "SANDBOX" `
        -Mode ""
} $true

Run-Test "Assert neutre autorise" {
    $r = Assert-SandboxSecretRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX"

    if ($r.Isolated -ne $true) {
        throw "ASSERT_ISOLATION_FAILED"
    }
} $false

Run-Test "Fail closed combinaison secrets" {
    Assert-SandboxSecretRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestSecrets $true `
        -RequestEnvironmentSecrets $true `
        -RequestProviderSecrets $true `
        -RequestConnectorSecrets $true `
        -RequestCredentialMaterialization $true `
        -RequestSecretExport $true `
        -RequestSecretLogging $true `
        -RequestMemorySecretPersistence $true
} $true

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTAT 8B-06"
Write-Host "============================================================"
Write-Host ("TOTAL TESTS : {0}" -f $script:Total)
Write-Host ("PASS        : {0}" -f $script:Pass)
Write-Host ("FAIL        : {0}" -f $script:Fail)
Write-Host ""

if (($script:Total -eq 24) -and ($script:Pass -eq 24) -and ($script:Fail -eq 0)) {
    Write-Host "8B-06 : VALIDEE - 24/24" -ForegroundColor Green
}
else {
    Write-Host "8B-06 : NON VALIDEE" -ForegroundColor Red
}

Write-Host "============================================================"
Write-Host "8B-06 - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"