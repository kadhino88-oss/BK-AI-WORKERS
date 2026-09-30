function Get-ExecutionControlsConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Execution Controls Config introuvable : $ConfigPath"
    }

    try {
        return (
            Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        )
    }
    catch {
        throw "Execution Controls Config invalide."
    }
}

function Get-TimeoutDecision {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [int]$TimeoutSeconds = 30
    )

    $config = Get-ExecutionControlsConfig -ConfigPath $ConfigPath

    if ($config.timeout.enabled -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "TIMEOUT_CONTROL_DISABLED"
        }
    }

    if ($TimeoutSeconds -lt [int]$config.timeout.minimumSeconds) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "TIMEOUT_TOO_LOW"
        }
    }

    if ($TimeoutSeconds -gt [int]$config.timeout.maximumSeconds) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "TIMEOUT_TOO_HIGH"
        }
    }

    return [pscustomobject]@{
        status = "VALID"
        timeoutSeconds = $TimeoutSeconds
        minimumSeconds = [int]$config.timeout.minimumSeconds
        maximumSeconds = [int]$config.timeout.maximumSeconds
    }
}

function Get-RetryDecision {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [int]$Attempt = 1,

        [bool]$PreviousAttemptFailed = $false
    )

    $config = Get-ExecutionControlsConfig -ConfigPath $ConfigPath

    if ($config.retry.enabled -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "RETRY_DISABLED"
        }
    }

    if ($Attempt -lt 1) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "INVALID_ATTEMPT"
        }
    }

    $maxAttempts = [int]$config.retry.maxAttempts

    if ($Attempt -gt $maxAttempts) {
        return [pscustomobject]@{
            status = "EXHAUSTED"
            attempt = $Attempt
            maxAttempts = $maxAttempts
            retryAllowed = $false
        }
    }

    if (-not $PreviousAttemptFailed) {
        return [pscustomobject]@{
            status = "INITIAL"
            attempt = $Attempt
            maxAttempts = $maxAttempts
            retryAllowed = $false
            backoffSeconds = 0
        }
    }

    if ($Attempt -eq $maxAttempts) {
        $backoff = [Math]::Min(
            (
                [int]$config.retry.backoffSeconds *
                [Math]::Pow(2, $Attempt - 1)
            ),
            [int]$config.retry.maxBackoffSeconds
        )

        return [pscustomobject]@{
            status = "FINAL_RETRY"
            attempt = $Attempt
            maxAttempts = $maxAttempts
            retryAllowed = $true
            backoffSeconds = $backoff
        }
    }

    $backoff = [Math]::Min(
        (
            [int]$config.retry.backoffSeconds *
            [Math]::Pow(2, $Attempt - 1)
        ),
        [int]$config.retry.maxBackoffSeconds
    )

    return [pscustomobject]@{
        status = "RETRY"
        attempt = $Attempt
        maxAttempts = $maxAttempts
        retryAllowed = $true
        backoffSeconds = $backoff
    }
}

function New-IdempotencyKey {
    param(
        [AllowEmptyString()]
        [string]$TenantId,

        [AllowEmptyString()]
        [string]$ClientId,

        [AllowEmptyString()]
        [string]$ProjectId,

        [AllowEmptyString()]
        [string]$Operation,

        [AllowEmptyString()]
        [string]$TaskId,

        [AllowEmptyString()]
        [string]$ExecutionId
    )

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "TenantId"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "ClientId"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ProjectId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "ProjectId"
        }
    }

    if ([string]::IsNullOrWhiteSpace($Operation)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "OPERATION_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "TASK_ID_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "EXECUTION_ID_REQUIRED"
        }
    }

    $material = "$TenantId|$ClientId|$ProjectId|$Operation|$TaskId|$ExecutionId"

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($material)
        $hash = $sha.ComputeHash($bytes)
        $hex = [System.BitConverter]::ToString($hash).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }

    return [pscustomobject]@{
        status = "CREATED"
        idempotencyKey = "IDEMP-$hex"
        tenantId = $TenantId
        clientId = $ClientId
        projectId = $ProjectId
        operation = $Operation
        taskId = $TaskId
        executionId = $ExecutionId
    }
}

function Validate-IdempotencyKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [AllowEmptyString()]
        [string]$IdempotencyKey
    )

    $config = Get-ExecutionControlsConfig -ConfigPath $ConfigPath

    if ($config.idempotency.enabled -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "IDEMPOTENCY_DISABLED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($IdempotencyKey)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "IDEMPOTENCY_KEY_REQUIRED"
        }
    }

    if ($IdempotencyKey.Length -gt [int]$config.idempotency.keyMaximumLength) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "IDEMPOTENCY_KEY_TOO_LONG"
        }
    }

    if ($IdempotencyKey -notmatch '^IDEMP-[a-f0-9]{64}$') {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "IDEMPOTENCY_KEY_INVALID"
        }
    }

    return [pscustomobject]@{
        status = "VALID"
        idempotencyKey = $IdempotencyKey
    }
}

function Test-IdempotencyDuplicate {
    param(
        [AllowEmptyString()]
        [string]$IdempotencyKey,

        [string[]]$KnownKeys = @()
    )

    if ([string]::IsNullOrWhiteSpace($IdempotencyKey)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "IDEMPOTENCY_KEY_REQUIRED"
        }
    }

    if ($KnownKeys -contains $IdempotencyKey) {
        return [pscustomobject]@{
            status = "DUPLICATE"
            executionAllowed = $false
            idempotencyKey = $IdempotencyKey
        }
    }

    return [pscustomobject]@{
        status = "NEW"
        executionAllowed = $true
        idempotencyKey = $IdempotencyKey
    }
}

function Get-ExecutionControlDecision {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [AllowEmptyString()]
        [string]$ExecutionId,

        [AllowEmptyString()]
        [string]$TenantId,

        [AllowEmptyString()]
        [string]$ClientId,

        [AllowEmptyString()]
        [string]$ProjectId,

        [AllowEmptyString()]
        [string]$Operation,

        [AllowEmptyString()]
        [string]$TaskId,

        [AllowEmptyString()]
        [string]$IdempotencyKey,

        [int]$TimeoutSeconds = 30,

        [int]$Attempt = 1,

        [bool]$PreviousAttemptFailed = $false,

        [string[]]$KnownIdempotencyKeys = @(),

        [ValidateSet("SIMULATION","CONTROLLED","LIVE")]
        [string]$Mode = "SIMULATION"
    )

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "ExecutionId"
        }
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "TenantId"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "ClientId"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ProjectId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "ProjectId"
        }
    }

    if ([string]::IsNullOrWhiteSpace($Operation)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "OPERATION_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "TASK_ID_REQUIRED"
        }
    }

    # Timeout
    $timeout = Get-TimeoutDecision `
        -ConfigPath $ConfigPath `
        -TimeoutSeconds $TimeoutSeconds

    if ($timeout.status -ne "VALID") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = $timeout.reason
        }
    }

    # Idempotency
    $idempotency = Validate-IdempotencyKey `
        -ConfigPath $ConfigPath `
        -IdempotencyKey $IdempotencyKey

    if ($idempotency.status -ne "VALID") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = $idempotency.reason
        }
    }

    $duplicate = Test-IdempotencyDuplicate `
        -IdempotencyKey $IdempotencyKey `
        -KnownKeys $KnownIdempotencyKeys

    if ($duplicate.status -eq "DUPLICATE") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "DUPLICATE_EXECUTION"
            idempotencyKey = $IdempotencyKey
        }
    }

    # Retry
    $retry = Get-RetryDecision `
        -ConfigPath $ConfigPath `
        -Attempt $Attempt `
        -PreviousAttemptFailed $PreviousAttemptFailed

    if (
        $retry.status -eq "EXHAUSTED"
    ) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "RETRY_EXHAUSTED"
        }
    }

    # LIVE reste fermé dans 7H-23
    if ($Mode -eq "LIVE") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "LIVE_EXECUTION_DISABLED"
        }
    }

    return [pscustomobject]@{
        status = "AUTHORIZED"
        executionId = $ExecutionId
        tenantId = $TenantId
        clientId = $ClientId
        projectId = $ProjectId
        operation = $Operation
        taskId = $TaskId
        idempotencyKey = $IdempotencyKey
        timeoutSeconds = $timeout.timeoutSeconds
        attempt = $Attempt
        retryStatus = $retry.status
        retryAllowed = $retry.retryAllowed
        backoffSeconds = $retry.backoffSeconds
        duplicate = $false
        mode = $Mode
        externalCallAllowed = $false
    }
}