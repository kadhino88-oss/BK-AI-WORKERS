$ErrorActionPreference = "Stop"

$script:IsolationStateDir = Join-Path $PSScriptRoot "state"
$script:IsolationStateFile = Join-Path $script:IsolationStateDir "isolation-state.json"

function Initialize-SandboxIsolationState {

    New-Item -ItemType Directory -Force -Path $script:IsolationStateDir | Out-Null

    $State = [ordered]@{
        Schema = "BK-AI-WORKERS-SANDBOX-LIVE-ISOLATION"
        Version = "1.0"
        SandboxEnabled = $true
        LiveEnabled = $false
        SandboxMayInvokeLive = $false
        SandboxMayUseLiveProvider = $false
        SandboxMayUseLiveConnector = $false
        CrossEnvironmentExecution = $false
        Records = @()
    }

    [System.IO.File]::WriteAllText(
        $script:IsolationStateFile,
        ($State | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )

    return $State
}

function Get-SandboxIsolationState {

    if (-not (Test-Path -LiteralPath $script:IsolationStateFile -PathType Leaf)) {
        return Initialize-SandboxIsolationState
    }

    $Raw = Get-Content -LiteralPath $script:IsolationStateFile -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "ISOLATION_STATE_EMPTY"
    }

    return ($Raw | ConvertFrom-Json)
}

function Save-SandboxIsolationState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    $Temp = "$($script:IsolationStateFile).tmp-$([Guid]::NewGuid().ToString('N'))"

    [System.IO.File]::WriteAllText(
        $Temp,
        ($State | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )

    Move-Item -LiteralPath $Temp -Destination $script:IsolationStateFile -Force
}

function Test-SandboxLiveIsolation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [bool]$RequestLive = $false,
        [bool]$UseLiveProvider = $false,
        [bool]$UseLiveConnector = $false,
        [bool]$CrossEnvironmentExecution = $false
    )

    if ([string]::IsNullOrWhiteSpace($Environment)) {
        throw "ISOLATION_ENVIRONMENT_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        throw "ISOLATION_MODE_REQUIRED"
    }

    $Env = $Environment.ToUpperInvariant()
    $ModeUpper = $Mode.ToUpperInvariant()

    $State = Get-SandboxIsolationState

    if ($State.SandboxEnabled -ne $true) {
        throw "SANDBOX_DISABLED"
    }

    if ($State.LiveEnabled -ne $false) {
        throw "LIVE_STATE_INVALID"
    }

    if ($Env -eq "SANDBOX") {

        if ($ModeUpper -ne "SANDBOX") {
            throw "SANDBOX_MODE_MISMATCH"
        }

        if ($RequestLive -eq $true) {
            throw "SANDBOX_LIVE_REQUEST_FORBIDDEN"
        }

        if ($UseLiveProvider -eq $true) {
            throw "SANDBOX_LIVE_PROVIDER_FORBIDDEN"
        }

        if ($UseLiveConnector -eq $true) {
            throw "SANDBOX_LIVE_CONNECTOR_FORBIDDEN"
        }

        if ($CrossEnvironmentExecution -eq $true) {
            throw "CROSS_ENVIRONMENT_EXECUTION_FORBIDDEN"
        }

        return [pscustomobject]@{
            Decision = "ALLOW"
            Isolated = $true
            Environment = "SANDBOX"
            Mode = "SANDBOX"
            LiveEnabled = $false
            CrossEnvironmentExecution = $false
            LiveProviderAllowed = $false
            LiveConnectorAllowed = $false
            Reason = "SANDBOX_ISOLATED"
        }
    }

    if ($Env -eq "LIVE") {
        throw "LIVE_NOT_ALLOWED_BY_SANDBOX_ISOLATION"
    }

    throw "UNKNOWN_ENVIRONMENT"
}

function Assert-SandboxLiveIsolation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [bool]$RequestLive = $false,
        [bool]$UseLiveProvider = $false,
        [bool]$UseLiveConnector = $false,
        [bool]$CrossEnvironmentExecution = $false
    )

    $Result = Test-SandboxLiveIsolation `
        -Environment $Environment `
        -Mode $Mode `
        -RequestLive $RequestLive `
        -UseLiveProvider $UseLiveProvider `
        -UseLiveConnector $UseLiveConnector `
        -CrossEnvironmentExecution $CrossEnvironmentExecution

    if ($Result.Isolated -ne $true) {
        throw "SANDBOX_ISOLATION_BLOCKED"
    }

    return $Result
}