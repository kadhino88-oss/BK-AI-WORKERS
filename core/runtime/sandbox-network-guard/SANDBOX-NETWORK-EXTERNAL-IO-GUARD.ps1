$ErrorActionPreference = "Stop"

$script:NetworkStateDir = Join-Path $PSScriptRoot "state"
$script:NetworkStateFile = Join-Path $script:NetworkStateDir "network-guard-state.json"

function Initialize-SandboxNetworkGuard {

    New-Item -ItemType Directory -Force -Path $script:NetworkStateDir | Out-Null

    $State = [ordered]@{
        Schema = "BK-AI-WORKERS-SANDBOX-NETWORK-EXTERNAL-IO"
        Version = "1.0"
        Mode = "SANDBOX"
        NetworkEnabled = $false
        ExternalIOEnabled = $false
        ProviderNetworkEnabled = $false
        ConnectorNetworkEnabled = $false
        FilesystemExternalWriteEnabled = $false
        ProcessSpawnEnabled = $false
        DNSResolutionEnabled = $false
        OutboundHTTPEnabled = $false
        Records = @()
    }

    [System.IO.File]::WriteAllText(
        $script:NetworkStateFile,
        ($State | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )

    return $State
}

function Get-SandboxNetworkGuardState {

    if (-not (Test-Path -LiteralPath $script:NetworkStateFile -PathType Leaf)) {
        return Initialize-SandboxNetworkGuard
    }

    $Raw = Get-Content -LiteralPath $script:NetworkStateFile -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "NETWORK_GUARD_STATE_EMPTY"
    }

    return ($Raw | ConvertFrom-Json)
}

function Test-SandboxNetworkAccess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [bool]$RequestNetwork = $false,
        [bool]$RequestExternalIO = $false,
        [bool]$ProviderNetwork = $false,
        [bool]$ConnectorNetwork = $false,
        [bool]$FilesystemExternalWrite = $false,
        [bool]$ProcessSpawn = $false,
        [bool]$DNSResolution = $false,
        [bool]$OutboundHTTP = $false
    )

    if ([string]::IsNullOrWhiteSpace($Environment)) {
        throw "NETWORK_ENVIRONMENT_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        throw "NETWORK_MODE_REQUIRED"
    }

    $Env = $Environment.ToUpperInvariant()
    $ModeUpper = $Mode.ToUpperInvariant()

    if ($Env -ne "SANDBOX") {
        throw "SANDBOX_ENVIRONMENT_REQUIRED"
    }

    if ($ModeUpper -ne "SANDBOX") {
        throw "SANDBOX_MODE_REQUIRED"
    }

    $State = Get-SandboxNetworkGuardState

    if ($State.Mode -ne "SANDBOX") {
        throw "NETWORK_GUARD_MODE_INVALID"
    }

    if ($State.NetworkEnabled -ne $false) {
        throw "SANDBOX_NETWORK_NOT_DISABLED"
    }

    if ($State.ExternalIOEnabled -ne $false) {
        throw "SANDBOX_EXTERNAL_IO_NOT_DISABLED"
    }

    if ($State.ProviderNetworkEnabled -ne $false) {
        throw "PROVIDER_NETWORK_NOT_DISABLED"
    }

    if ($State.ConnectorNetworkEnabled -ne $false) {
        throw "CONNECTOR_NETWORK_NOT_DISABLED"
    }

    if ($State.FilesystemExternalWriteEnabled -ne $false) {
        throw "FILESYSTEM_EXTERNAL_WRITE_NOT_DISABLED"
    }

    if ($State.ProcessSpawnEnabled -ne $false) {
        throw "PROCESS_SPAWN_NOT_DISABLED"
    }

    if ($State.DNSResolutionEnabled -ne $false) {
        throw "DNS_NOT_DISABLED"
    }

    if ($State.OutboundHTTPEnabled -ne $false) {
        throw "OUTBOUND_HTTP_NOT_DISABLED"
    }

    if ($RequestNetwork) {
        throw "SANDBOX_NETWORK_FORBIDDEN"
    }

    if ($RequestExternalIO) {
        throw "SANDBOX_EXTERNAL_IO_FORBIDDEN"
    }

    if ($ProviderNetwork) {
        throw "SANDBOX_PROVIDER_NETWORK_FORBIDDEN"
    }

    if ($ConnectorNetwork) {
        throw "SANDBOX_CONNECTOR_NETWORK_FORBIDDEN"
    }

    if ($FilesystemExternalWrite) {
        throw "SANDBOX_EXTERNAL_FILESYSTEM_WRITE_FORBIDDEN"
    }

    if ($ProcessSpawn) {
        throw "SANDBOX_PROCESS_SPAWN_FORBIDDEN"
    }

    if ($DNSResolution) {
        throw "SANDBOX_DNS_FORBIDDEN"
    }

    if ($OutboundHTTP) {
        throw "SANDBOX_OUTBOUND_HTTP_FORBIDDEN"
    }

    return [pscustomobject]@{
        Decision = "ALLOW"
        Isolated = $true
        Environment = "SANDBOX"
        Mode = "SANDBOX"
        NetworkAllowed = $false
        ExternalIOAllowed = $false
        ProviderNetworkAllowed = $false
        ConnectorNetworkAllowed = $false
        FilesystemExternalWriteAllowed = $false
        ProcessSpawnAllowed = $false
        DNSAllowed = $false
        OutboundHTTPAllowed = $false
        Reason = "SANDBOX_EXTERNAL_IO_ISOLATED"
    }
}

function Assert-SandboxNetworkAccess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [bool]$RequestNetwork = $false,
        [bool]$RequestExternalIO = $false,
        [bool]$ProviderNetwork = $false,
        [bool]$ConnectorNetwork = $false,
        [bool]$FilesystemExternalWrite = $false,
        [bool]$ProcessSpawn = $false,
        [bool]$DNSResolution = $false,
        [bool]$OutboundHTTP = $false
    )

    return Test-SandboxNetworkAccess @PSBoundParameters
}