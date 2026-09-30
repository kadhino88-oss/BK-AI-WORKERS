$ErrorActionPreference = "Stop"

$script:TimeoutStateDir = Join-Path $PSScriptRoot "state"
$script:TimeoutStateFile = Join-Path $script:TimeoutStateDir "timeout-state.json"

function Initialize-SandboxTimeoutGuard {

    New-Item -ItemType Directory -Force -Path $script:TimeoutStateDir | Out-Null

    $State = [ordered]@{
        Schema = "BK-AI-WORKERS-SANDBOX-TIMEOUT-DEADLINE"
        Version = "1.0"
        Mode = "SANDBOX"
        MaxExecutionDurationSeconds = 300
        MinimumTimeoutSeconds = 1
        TimeoutBypassAllowed = $false
        DeadlineBypassAllowed = $false
        InfiniteExecutionAllowed = $false
        Records = @()
    }

    [System.IO.File]::WriteAllText(
        $script:TimeoutStateFile,
        ($State | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )

    return $State
}

function Get-SandboxTimeoutGuardState {

    if (-not (Test-Path -LiteralPath $script:TimeoutStateFile -PathType Leaf)) {
        return Initialize-SandboxTimeoutGuard
    }

    $Raw = Get-Content -LiteralPath $script:TimeoutStateFile -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "TIMEOUT_STATE_EMPTY"
    }

    return ($Raw | ConvertFrom-Json)
}

function Test-SandboxExecutionDeadline {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [int]$RequestedDurationSeconds = 1,
        [int]$ElapsedSeconds = 0,
        [bool]$TimeoutBypass = $false,
        [bool]$DeadlineBypass = $false,
        [bool]$InfiniteExecution = $false
    )

    if ([string]::IsNullOrWhiteSpace($Environment)) {
        throw "TIMEOUT_ENVIRONMENT_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        throw "TIMEOUT_MODE_REQUIRED"
    }

    $EnvUpper = $Environment.ToUpperInvariant()
    $ModeUpper = $Mode.ToUpperInvariant()

    if ($EnvUpper -ne "SANDBOX") {
        throw "SANDBOX_ENVIRONMENT_REQUIRED"
    }

    if ($ModeUpper -ne "SANDBOX") {
        throw "SANDBOX_MODE_REQUIRED"
    }

    $State = Get-SandboxTimeoutGuardState

    if ($State.Mode -ne "SANDBOX") {
        throw "TIMEOUT_GUARD_MODE_INVALID"
    }

    if ($State.TimeoutBypassAllowed -ne $false) {
        throw "TIMEOUT_BYPASS_CONFIGURATION_INVALID"
    }

    if ($State.DeadlineBypassAllowed -ne $false) {
        throw "DEADLINE_BYPASS_CONFIGURATION_INVALID"
    }

    if ($State.InfiniteExecutionAllowed -ne $false) {
        throw "INFINITE_EXECUTION_CONFIGURATION_INVALID"
    }

    if ($TimeoutBypass) {
        throw "SANDBOX_TIMEOUT_BYPASS_FORBIDDEN"
    }

    if ($DeadlineBypass) {
        throw "SANDBOX_DEADLINE_BYPASS_FORBIDDEN"
    }

    if ($InfiniteExecution) {
        throw "SANDBOX_INFINITE_EXECUTION_FORBIDDEN"
    }

    if ($RequestedDurationSeconds -lt [int]$State.MinimumTimeoutSeconds) {
        throw "SANDBOX_TIMEOUT_TOO_SHORT"
    }

    if ($RequestedDurationSeconds -gt [int]$State.MaxExecutionDurationSeconds) {
        throw "SANDBOX_DEADLINE_EXCEEDED"
    }

    if ($ElapsedSeconds -lt 0) {
        throw "SANDBOX_ELAPSED_TIME_INVALID"
    }

    if ($ElapsedSeconds -gt $RequestedDurationSeconds) {
        throw "SANDBOX_EXECUTION_TIMEOUT"
    }

    $RemainingSeconds = $RequestedDurationSeconds - $ElapsedSeconds

    return [pscustomobject]@{
        Decision = "ALLOW"
        Valid = $true
        Environment = "SANDBOX"
        Mode = "SANDBOX"
        RequestedDurationSeconds = $RequestedDurationSeconds
        ElapsedSeconds = $ElapsedSeconds
        RemainingSeconds = $RemainingSeconds
        TimeoutBypass = $false
        DeadlineBypass = $false
        InfiniteExecution = $false
        Reason = "SANDBOX_DEADLINE_VALID"
    }
}

function Assert-SandboxExecutionDeadline {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [int]$RequestedDurationSeconds = 1,
        [int]$ElapsedSeconds = 0,
        [bool]$TimeoutBypass = $false,
        [bool]$DeadlineBypass = $false,
        [bool]$InfiniteExecution = $false
    )

    return Test-SandboxExecutionDeadline @PSBoundParameters
}