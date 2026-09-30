$ErrorActionPreference = "Stop"

$script:ResourceStateDir = Join-Path $PSScriptRoot "state"
$script:ResourceStateFile = Join-Path $script:ResourceStateDir "resource-quota-state.json"

function Initialize-SandboxResourceGuard {

    New-Item -ItemType Directory -Force -Path $script:ResourceStateDir | Out-Null

    $State = [ordered]@{
        Schema = "BK-AI-WORKERS-SANDBOX-RESOURCE-QUOTA"
        Version = "1.0"
        Mode = "SANDBOX"

        MaxConcurrentExecutions = 4
        MaxExecutionDurationSeconds = 300
        MaxMemoryMb = 512
        MaxOutputBytes = 10485760
        MaxInputBytes = 10485760
        MaxProcessCount = 0
        MaxNetworkRequests = 0

        ResourceUnlimited = $false
        QuotaBypassAllowed = $false
        Records = @()
    }

    [System.IO.File]::WriteAllText(
        $script:ResourceStateFile,
        ($State | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )

    return $State
}

function Get-SandboxResourceGuardState {

    if (-not (Test-Path -LiteralPath $script:ResourceStateFile -PathType Leaf)) {
        return Initialize-SandboxResourceGuard
    }

    $Raw = Get-Content -LiteralPath $script:ResourceStateFile -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "RESOURCE_STATE_EMPTY"
    }

    return ($Raw | ConvertFrom-Json)
}

function Test-SandboxResourceRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [int]$ConcurrentExecutions = 1,
        [int]$DurationSeconds = 1,
        [int]$MemoryMb = 1,
        [long]$OutputBytes = 1,
        [long]$InputBytes = 1,
        [int]$ProcessCount = 0,
        [int]$NetworkRequests = 0,
        [bool]$QuotaBypass = $false
    )

    if ([string]::IsNullOrWhiteSpace($Environment)) {
        throw "RESOURCE_ENVIRONMENT_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        throw "RESOURCE_MODE_REQUIRED"
    }

    $EnvUpper = $Environment.ToUpperInvariant()
    $ModeUpper = $Mode.ToUpperInvariant()

    if ($EnvUpper -ne "SANDBOX") {
        throw "SANDBOX_ENVIRONMENT_REQUIRED"
    }

    if ($ModeUpper -ne "SANDBOX") {
        throw "SANDBOX_MODE_REQUIRED"
    }

    $State = Get-SandboxResourceGuardState

    if ($State.Mode -ne "SANDBOX") {
        throw "RESOURCE_GUARD_MODE_INVALID"
    }

    if ($State.ResourceUnlimited -eq $true) {
        throw "RESOURCE_UNLIMITED_FORBIDDEN"
    }

    if ($State.QuotaBypassAllowed -eq $true) {
        throw "QUOTA_BYPASS_CONFIGURATION_INVALID"
    }

    if ($QuotaBypass) {
        throw "SANDBOX_QUOTA_BYPASS_FORBIDDEN"
    }

    if ($ConcurrentExecutions -lt 1) {
        throw "CONCURRENT_EXECUTIONS_INVALID"
    }

    if ($DurationSeconds -lt 1) {
        throw "DURATION_INVALID"
    }

    if ($MemoryMb -lt 1) {
        throw "MEMORY_INVALID"
    }

    if ($OutputBytes -lt 0) {
        throw "OUTPUT_SIZE_INVALID"
    }

    if ($InputBytes -lt 0) {
        throw "INPUT_SIZE_INVALID"
    }

    if ($ProcessCount -lt 0) {
        throw "PROCESS_COUNT_INVALID"
    }

    if ($NetworkRequests -lt 0) {
        throw "NETWORK_REQUEST_COUNT_INVALID"
    }

    if ($ConcurrentExecutions -gt [int]$State.MaxConcurrentExecutions) {
        throw "SANDBOX_CONCURRENT_QUOTA_EXCEEDED"
    }

    if ($DurationSeconds -gt [int]$State.MaxExecutionDurationSeconds) {
        throw "SANDBOX_DURATION_QUOTA_EXCEEDED"
    }

    if ($MemoryMb -gt [int]$State.MaxMemoryMb) {
        throw "SANDBOX_MEMORY_QUOTA_EXCEEDED"
    }

    if ($OutputBytes -gt [long]$State.MaxOutputBytes) {
        throw "SANDBOX_OUTPUT_QUOTA_EXCEEDED"
    }

    if ($InputBytes -gt [long]$State.MaxInputBytes) {
        throw "SANDBOX_INPUT_QUOTA_EXCEEDED"
    }

    if ($ProcessCount -gt [int]$State.MaxProcessCount) {
        throw "SANDBOX_PROCESS_QUOTA_EXCEEDED"
    }

    if ($NetworkRequests -gt [int]$State.MaxNetworkRequests) {
        throw "SANDBOX_NETWORK_QUOTA_EXCEEDED"
    }

    return [pscustomobject]@{
        Decision = "ALLOW"
        Valid = $true
        Environment = "SANDBOX"
        Mode = "SANDBOX"
        ConcurrentExecutions = $ConcurrentExecutions
        DurationSeconds = $DurationSeconds
        MemoryMb = $MemoryMb
        OutputBytes = $OutputBytes
        InputBytes = $InputBytes
        ProcessCount = $ProcessCount
        NetworkRequests = $NetworkRequests
        QuotaBypass = $false
        Reason = "SANDBOX_RESOURCE_QUOTA_VALID"
    }
}

function Assert-SandboxResourceRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [int]$ConcurrentExecutions = 1,
        [int]$DurationSeconds = 1,
        [int]$MemoryMb = 1,
        [long]$OutputBytes = 1,
        [long]$InputBytes = 1,
        [int]$ProcessCount = 0,
        [int]$NetworkRequests = 0,
        [bool]$QuotaBypass = $false
    )

    return Test-SandboxResourceRequest @PSBoundParameters
}