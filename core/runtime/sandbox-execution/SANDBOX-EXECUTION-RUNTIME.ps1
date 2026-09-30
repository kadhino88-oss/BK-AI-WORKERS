$ErrorActionPreference = "Stop"

$script:SandboxRoot = $PSScriptRoot
$script:SandboxStateDir = Join-Path $PSScriptRoot "state"
$script:SandboxStateFile = Join-Path $script:SandboxStateDir "sandbox-state.json"

function Initialize-SandboxState {

    New-Item -ItemType Directory -Force -Path $script:SandboxStateDir | Out-Null

    $State = [ordered]@{
        Schema = "BK-AI-WORKERS-SANDBOX-EXECUTION"
        Version = "1.0"
        Mode = "SANDBOX"
        LiveEnabled = $false
        ExternalActionsEnabled = $false
        SecretsAllowed = $false
        ProviderLiveEnabled = $false
        ConnectorLiveEnabled = $false
        Executions = @()
    }

    [System.IO.File]::WriteAllText(
        $script:SandboxStateFile,
        ($State | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )

    return $State
}

function Get-SandboxState {

    if (-not (Test-Path -LiteralPath $script:SandboxStateFile -PathType Leaf)) {
        return Initialize-SandboxState
    }

    $Raw = Get-Content -LiteralPath $script:SandboxStateFile -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "SANDBOX_STATE_EMPTY"
    }

    return ($Raw | ConvertFrom-Json)
}

function Save-SandboxState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    $Temp = "$($script:SandboxStateFile).tmp-$([Guid]::NewGuid().ToString('N'))"

    [System.IO.File]::WriteAllText(
        $Temp,
        ($State | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )

    Move-Item -LiteralPath $Temp -Destination $script:SandboxStateFile -Force
}

function Get-SandboxExecutionKey {
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$ExecutionId,
        [Parameter(Mandatory = $true)][string]$UserId,
        [Parameter(Mandatory = $true)][string]$TaskId
    )

    $Canonical = "$TenantId|$ClientId|$ProjectId|$ExecutionId|$UserId|$TaskId"

    $Sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Canonical)
        $HashBytes = $Sha.ComputeHash($Bytes)

        return (($HashBytes | ForEach-Object {
            $_.ToString("x2")
        }) -join "")
    }
    finally {
        $Sha.Dispose()
    }
}

function Invoke-SandboxExecution {
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$ExecutionId,
        [Parameter(Mandatory = $true)][string]$UserId,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$OperationName,

        [string]$Environment = "SANDBOX",
        [string]$Mode = "SANDBOX",

        [bool]$SessionValid = $true,
        [bool]$AuthorizationValid = $true,
        [bool]$CapabilityAuthorized = $true,
        [bool]$AuthorityAuthorized = $true,
        [bool]$PolicyAuthorized = $true,
        [bool]$WorkerTaskAuthorized = $true,

        [bool]$DirectProviderExecution = $false,
        [bool]$DirectConnectorExecution = $false,
        [bool]$SecretsPresent = $false
    )

    foreach ($Item in @(
        @{ Name = "TenantId"; Value = $TenantId },
        @{ Name = "ClientId"; Value = $ClientId },
        @{ Name = "ProjectId"; Value = $ProjectId },
        @{ Name = "ExecutionId"; Value = $ExecutionId },
        @{ Name = "UserId"; Value = $UserId },
        @{ Name = "TaskId"; Value = $TaskId },
        @{ Name = "OperationName"; Value = $OperationName }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$Item.Value)) {
            throw "SANDBOX_CONTEXT_MISSING:$($Item.Name)"
        }
    }

    $EnvironmentUpper = $Environment.ToUpperInvariant()
    $ModeUpper = $Mode.ToUpperInvariant()

    if ($EnvironmentUpper -ne "SANDBOX") {
        throw "SANDBOX_ENVIRONMENT_REQUIRED"
    }

    if ($ModeUpper -ne "SANDBOX") {
        throw "SANDBOX_MODE_REQUIRED"
    }

    if ($SessionValid -ne $true) {
        throw "SANDBOX_SESSION_REQUIRED"
    }

    if ($AuthorizationValid -ne $true) {
        throw "SANDBOX_AUTHORIZATION_REQUIRED"
    }

    if ($CapabilityAuthorized -ne $true) {
        throw "SANDBOX_CAPABILITY_REQUIRED"
    }

    if ($AuthorityAuthorized -ne $true) {
        throw "SANDBOX_AUTHORITY_REQUIRED"
    }

    if ($PolicyAuthorized -ne $true) {
        throw "SANDBOX_POLICY_REQUIRED"
    }

    if ($WorkerTaskAuthorized -ne $true) {
        throw "SANDBOX_WORKER_TASK_REQUIRED"
    }

    if ($DirectProviderExecution -eq $true) {
        throw "SANDBOX_DIRECT_PROVIDER_FORBIDDEN"
    }

    if ($DirectConnectorExecution -eq $true) {
        throw "SANDBOX_DIRECT_CONNECTOR_FORBIDDEN"
    }

    if ($SecretsPresent -eq $true) {
        throw "SANDBOX_SECRETS_FORBIDDEN"
    }

    $State = Get-SandboxState

    if ($State.Mode -ne "SANDBOX") {
        throw "SANDBOX_STATE_MODE_INVALID"
    }

    if ($State.LiveEnabled -eq $true) {
        throw "SANDBOX_LIVE_MUST_REMAIN_DISABLED"
    }

    if ($State.ExternalActionsEnabled -eq $true) {
        throw "SANDBOX_EXTERNAL_ACTIONS_MUST_REMAIN_DISABLED"
    }

    if ($State.SecretsAllowed -eq $true) {
        throw "SANDBOX_SECRETS_MUST_REMAIN_DISABLED"
    }

    $Key = Get-SandboxExecutionKey `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -ExecutionId $ExecutionId `
        -UserId $UserId `
        -TaskId $TaskId

    $Record = [pscustomobject]@{
        Key = $Key
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        ExecutionId = $ExecutionId
        UserId = $UserId
        TaskId = $TaskId
        OperationName = $OperationName
        Environment = "SANDBOX"
        Mode = "SANDBOX"
        ProviderExecution = "SIMULATED"
        ConnectorExecution = "SIMULATED"
        ExternalActionExecuted = $false
        SecretsUsed = $false
        LiveExecution = $false
        Status = "SIMULATED_SUCCESS"
        CreatedAtUtc = [DateTime]::UtcNow.ToString("o")
    }

    $Records = @($State.Executions)

    $Existing = @(
        $Records | Where-Object {
            $_.Key -eq $Key
        }
    )

    if ($Existing.Count -gt 0) {
        throw "SANDBOX_EXECUTION_REPLAY_BLOCKED"
    }

    $Records += $Record
    $State.Executions = $Records

    Save-SandboxState -State $State

    return [pscustomobject]@{
        Schema = "BK-AI-WORKERS-SANDBOX-EXECUTION-RESULT"
        Decision = "ALLOW"
        Authorized = $true
        Environment = "SANDBOX"
        Mode = "SANDBOX"
        ExecutionId = $ExecutionId
        TaskId = $TaskId
        ProviderExecution = "SIMULATED"
        ConnectorExecution = "SIMULATED"
        ExternalActionExecuted = $false
        SecretsUsed = $false
        LiveExecution = $false
        Status = "SIMULATED_SUCCESS"
    }
}

function Test-SandboxRuntime {

    $State = Get-SandboxState

    return [pscustomobject]@{
        Ready = (
            ($State.Mode -eq "SANDBOX") -and
            ($State.LiveEnabled -eq $false) -and
            ($State.ExternalActionsEnabled -eq $false) -and
            ($State.SecretsAllowed -eq $false) -and
            ($State.ProviderLiveEnabled -eq $false) -and
            ($State.ConnectorLiveEnabled -eq $false)
        )
        Mode = $State.Mode
        LiveEnabled = $State.LiveEnabled
        ExternalActionsEnabled = $State.ExternalActionsEnabled
        SecretsAllowed = $State.SecretsAllowed
        ProviderLiveEnabled = $State.ProviderLiveEnabled
        ConnectorLiveEnabled = $State.ConnectorLiveEnabled
    }
}