$ErrorActionPreference = "Stop"

$script:SecretsStateDir = Join-Path $PSScriptRoot "state"
$script:SecretsStateFile = Join-Path $script:SecretsStateDir "secrets-guard-state.json"

function Initialize-SandboxSecretsGuard {

    New-Item -ItemType Directory -Force -Path $script:SecretsStateDir | Out-Null

    $State = [ordered]@{
        Schema = "BK-AI-WORKERS-SANDBOX-SECRETS-GUARD"
        Version = "1.0"
        Mode = "SANDBOX"
        SecretsAllowed = $false
        EnvironmentSecretsAllowed = $false
        ProviderSecretsAllowed = $false
        ConnectorSecretsAllowed = $false
        CredentialMaterializationAllowed = $false
        SecretExportAllowed = $false
        SecretLoggingAllowed = $false
        MemorySecretPersistenceAllowed = $false
        Records = @()
    }

    [System.IO.File]::WriteAllText(
        $script:SecretsStateFile,
        ($State | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )

    return $State
}

function Get-SandboxSecretsGuardState {

    if (-not (Test-Path -LiteralPath $script:SecretsStateFile -PathType Leaf)) {
        return Initialize-SandboxSecretsGuard
    }

    $Raw = Get-Content -LiteralPath $script:SecretsStateFile -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "SECRETS_GUARD_STATE_EMPTY"
    }

    return ($Raw | ConvertFrom-Json)
}

function Test-SandboxSecretRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [bool]$RequestSecrets = $false,
        [bool]$RequestEnvironmentSecrets = $false,
        [bool]$RequestProviderSecrets = $false,
        [bool]$RequestConnectorSecrets = $false,
        [bool]$RequestCredentialMaterialization = $false,
        [bool]$RequestSecretExport = $false,
        [bool]$RequestSecretLogging = $false,
        [bool]$RequestMemorySecretPersistence = $false
    )

    if ([string]::IsNullOrWhiteSpace($Environment)) {
        throw "SECRETS_ENVIRONMENT_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        throw "SECRETS_MODE_REQUIRED"
    }

    $Env = $Environment.ToUpperInvariant()
    $ModeUpper = $Mode.ToUpperInvariant()

    if ($Env -ne "SANDBOX") {
        throw "SANDBOX_ENVIRONMENT_REQUIRED"
    }

    if ($ModeUpper -ne "SANDBOX") {
        throw "SANDBOX_MODE_REQUIRED"
    }

    $State = Get-SandboxSecretsGuardState

    if ($State.Mode -ne "SANDBOX") {
        throw "SECRETS_GUARD_MODE_INVALID"
    }

    if ($State.SecretsAllowed -ne $false) {
        throw "SECRETS_CONFIGURATION_INVALID"
    }

    if ($State.EnvironmentSecretsAllowed -ne $false) {
        throw "ENVIRONMENT_SECRETS_CONFIGURATION_INVALID"
    }

    if ($State.ProviderSecretsAllowed -ne $false) {
        throw "PROVIDER_SECRETS_CONFIGURATION_INVALID"
    }

    if ($State.ConnectorSecretsAllowed -ne $false) {
        throw "CONNECTOR_SECRETS_CONFIGURATION_INVALID"
    }

    if ($State.CredentialMaterializationAllowed -ne $false) {
        throw "CREDENTIAL_MATERIALIZATION_CONFIGURATION_INVALID"
    }

    if ($State.SecretExportAllowed -ne $false) {
        throw "SECRET_EXPORT_CONFIGURATION_INVALID"
    }

    if ($State.SecretLoggingAllowed -ne $false) {
        throw "SECRET_LOGGING_CONFIGURATION_INVALID"
    }

    if ($State.MemorySecretPersistenceAllowed -ne $false) {
        throw "MEMORY_SECRET_CONFIGURATION_INVALID"
    }

    if ($RequestSecrets) {
        throw "SANDBOX_SECRETS_FORBIDDEN"
    }

    if ($RequestEnvironmentSecrets) {
        throw "SANDBOX_ENVIRONMENT_SECRETS_FORBIDDEN"
    }

    if ($RequestProviderSecrets) {
        throw "SANDBOX_PROVIDER_SECRETS_FORBIDDEN"
    }

    if ($RequestConnectorSecrets) {
        throw "SANDBOX_CONNECTOR_SECRETS_FORBIDDEN"
    }

    if ($RequestCredentialMaterialization) {
        throw "SANDBOX_CREDENTIAL_MATERIALIZATION_FORBIDDEN"
    }

    if ($RequestSecretExport) {
        throw "SANDBOX_SECRET_EXPORT_FORBIDDEN"
    }

    if ($RequestSecretLogging) {
        throw "SANDBOX_SECRET_LOGGING_FORBIDDEN"
    }

    if ($RequestMemorySecretPersistence) {
        throw "SANDBOX_MEMORY_SECRET_PERSISTENCE_FORBIDDEN"
    }

    return [pscustomobject]@{
        Decision = "ALLOW"
        Isolated = $true
        Environment = "SANDBOX"
        Mode = "SANDBOX"
        SecretsAllowed = $false
        EnvironmentSecretsAllowed = $false
        ProviderSecretsAllowed = $false
        ConnectorSecretsAllowed = $false
        CredentialMaterializationAllowed = $false
        SecretExportAllowed = $false
        SecretLoggingAllowed = $false
        MemorySecretPersistenceAllowed = $false
        Reason = "SANDBOX_SECRETS_ISOLATED"
    }
}

function Assert-SandboxSecretRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [bool]$RequestSecrets = $false,
        [bool]$RequestEnvironmentSecrets = $false,
        [bool]$RequestProviderSecrets = $false,
        [bool]$RequestConnectorSecrets = $false,
        [bool]$RequestCredentialMaterialization = $false,
        [bool]$RequestSecretExport = $false,
        [bool]$RequestSecretLogging = $false,
        [bool]$RequestMemorySecretPersistence = $false
    )

    return Test-SandboxSecretRequest @PSBoundParameters
}