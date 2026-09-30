$ErrorActionPreference = "Stop"

$script:OutputStateDir = Join-Path $PSScriptRoot "state"
$script:OutputStateFile = Join-Path $script:OutputStateDir "output-guard-state.json"

function Initialize-SandboxOutputGuard {

    New-Item -ItemType Directory -Force -Path $script:OutputStateDir | Out-Null

    $State = [ordered]@{
        Schema = "BK-AI-WORKERS-SANDBOX-OUTPUT-DATA-EXFILTRATION"
        Version = "1.0"
        Mode = "SANDBOX"

        ExternalOutputAllowed = $false
        NetworkOutputAllowed = $false
        ProviderOutputAllowed = $false
        ConnectorOutputAllowed = $false
        ExternalFileExportAllowed = $false
        ClipboardExportAllowed = $false
        RedirectOutputAllowed = $false
        SecretOutputAllowed = $false
        CrossTenantOutputAllowed = $false

        Records = @()
    }

    [System.IO.File]::WriteAllText(
        $script:OutputStateFile,
        ($State | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )

    return $State
}

function Get-SandboxOutputGuardState {

    if (-not (Test-Path -LiteralPath $script:OutputStateFile -PathType Leaf)) {
        return Initialize-SandboxOutputGuard
    }

    $Raw = Get-Content -LiteralPath $script:OutputStateFile -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "OUTPUT_GUARD_STATE_EMPTY"
    }

    return ($Raw | ConvertFrom-Json)
}

function Test-SandboxOutputRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [bool]$RequestExternalOutput = $false,
        [bool]$RequestNetworkOutput = $false,
        [bool]$RequestProviderOutput = $false,
        [bool]$RequestConnectorOutput = $false,
        [bool]$RequestExternalFileExport = $false,
        [bool]$RequestClipboardExport = $false,
        [bool]$RequestRedirectOutput = $false,
        [bool]$RequestSecretOutput = $false,
        [bool]$RequestCrossTenantOutput = $false
    )

    if ([string]::IsNullOrWhiteSpace($Environment)) {
        throw "OUTPUT_ENVIRONMENT_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        throw "OUTPUT_MODE_REQUIRED"
    }

    $EnvUpper = $Environment.ToUpperInvariant()
    $ModeUpper = $Mode.ToUpperInvariant()

    if ($EnvUpper -ne "SANDBOX") {
        throw "SANDBOX_ENVIRONMENT_REQUIRED"
    }

    if ($ModeUpper -ne "SANDBOX") {
        throw "SANDBOX_MODE_REQUIRED"
    }

    $State = Get-SandboxOutputGuardState

    if ($State.Mode -ne "SANDBOX") {
        throw "OUTPUT_GUARD_MODE_INVALID"
    }

    if ($State.ExternalOutputAllowed -ne $false) {
        throw "EXTERNAL_OUTPUT_CONFIGURATION_INVALID"
    }

    if ($State.NetworkOutputAllowed -ne $false) {
        throw "NETWORK_OUTPUT_CONFIGURATION_INVALID"
    }

    if ($State.ProviderOutputAllowed -ne $false) {
        throw "PROVIDER_OUTPUT_CONFIGURATION_INVALID"
    }

    if ($State.ConnectorOutputAllowed -ne $false) {
        throw "CONNECTOR_OUTPUT_CONFIGURATION_INVALID"
    }

    if ($State.ExternalFileExportAllowed -ne $false) {
        throw "EXTERNAL_FILE_EXPORT_CONFIGURATION_INVALID"
    }

    if ($State.ClipboardExportAllowed -ne $false) {
        throw "CLIPBOARD_EXPORT_CONFIGURATION_INVALID"
    }

    if ($State.RedirectOutputAllowed -ne $false) {
        throw "REDIRECT_OUTPUT_CONFIGURATION_INVALID"
    }

    if ($State.SecretOutputAllowed -ne $false) {
        throw "SECRET_OUTPUT_CONFIGURATION_INVALID"
    }

    if ($State.CrossTenantOutputAllowed -ne $false) {
        throw "CROSS_TENANT_OUTPUT_CONFIGURATION_INVALID"
    }

    if ($RequestExternalOutput) {
        throw "SANDBOX_EXTERNAL_OUTPUT_FORBIDDEN"
    }

    if ($RequestNetworkOutput) {
        throw "SANDBOX_NETWORK_OUTPUT_FORBIDDEN"
    }

    if ($RequestProviderOutput) {
        throw "SANDBOX_PROVIDER_OUTPUT_FORBIDDEN"
    }

    if ($RequestConnectorOutput) {
        throw "SANDBOX_CONNECTOR_OUTPUT_FORBIDDEN"
    }

    if ($RequestExternalFileExport) {
        throw "SANDBOX_EXTERNAL_FILE_EXPORT_FORBIDDEN"
    }

    if ($RequestClipboardExport) {
        throw "SANDBOX_CLIPBOARD_EXPORT_FORBIDDEN"
    }

    if ($RequestRedirectOutput) {
        throw "SANDBOX_OUTPUT_REDIRECT_FORBIDDEN"
    }

    if ($RequestSecretOutput) {
        throw "SANDBOX_SECRET_OUTPUT_FORBIDDEN"
    }

    if ($RequestCrossTenantOutput) {
        throw "SANDBOX_CROSS_TENANT_OUTPUT_FORBIDDEN"
    }

    return [pscustomobject]@{
        Decision = "ALLOW"
        Valid = $true
        Isolated = $true
        Environment = "SANDBOX"
        Mode = "SANDBOX"
        ExternalOutputAllowed = $false
        NetworkOutputAllowed = $false
        ProviderOutputAllowed = $false
        ConnectorOutputAllowed = $false
        ExternalFileExportAllowed = $false
        ClipboardExportAllowed = $false
        RedirectOutputAllowed = $false
        SecretOutputAllowed = $false
        CrossTenantOutputAllowed = $false
        Reason = "SANDBOX_OUTPUT_ISOLATED"
    }
}

function Assert-SandboxOutputRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [bool]$RequestExternalOutput = $false,
        [bool]$RequestNetworkOutput = $false,
        [bool]$RequestProviderOutput = $false,
        [bool]$RequestConnectorOutput = $false,
        [bool]$RequestExternalFileExport = $false,
        [bool]$RequestClipboardExport = $false,
        [bool]$RequestRedirectOutput = $false,
        [bool]$RequestSecretOutput = $false,
        [bool]$RequestCrossTenantOutput = $false
    )

    return Test-SandboxOutputRequest @PSBoundParameters
}