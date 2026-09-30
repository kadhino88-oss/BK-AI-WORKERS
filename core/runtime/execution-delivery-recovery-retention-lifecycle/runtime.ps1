function Get-RetentionLifecycleConfig {
    $path = Join-Path $PSScriptRoot "config.json"

    return (
        Get-Content -Raw -Path $path |
        ConvertFrom-Json
    )
}

function Get-RetentionLifecycleField {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $cfg = Get-RetentionLifecycleConfig
    $prop = $cfg.PSObject.Properties[$Name]

    if ($null -eq $prop) {
        return $null
    }

    return $prop.Value
}

function Get-RetentionLifecycleRecords {
    $path = Join-Path $PSScriptRoot "state\lifecycle-records.json"

    if (-not (Test-Path $path)) {
        return @()
    }

    $raw = Get-Content -Raw -Path $path

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $parsed = $raw | ConvertFrom-Json

    if ($null -eq $parsed) {
        return @()
    }

    $result = @()

    foreach ($item in @($parsed)) {
        $result += ,$item
    }

    return $result
}

function Save-RetentionLifecycleRecords {
    param(
        [Parameter(Mandatory=$false)]
        $Records
    )

    $path = Join-Path $PSScriptRoot "state\lifecycle-records.json"

    $normalized = @()

    foreach ($item in @($Records)) {
        $normalized += ,$item
    }

    $json = ConvertTo-Json `
        -InputObject $normalized `
        -Depth 100

    [System.IO.File]::WriteAllText(
        $path,
        $json,
        [System.Text.Encoding]::UTF8
    )

    return $true
}

function Get-RetentionLifecycleRecord {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RetentionId
    )

    if ([string]::IsNullOrWhiteSpace($RetentionId)) {
        return $null
    }

    $records = @(Get-RetentionLifecycleRecords)

    foreach ($record in $records) {
        if ([string]$record.RetentionId -eq $RetentionId) {
            return $record
        }
    }

    return $null
}

function Test-RetentionLifecycleContext {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RetentionId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$EventId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$CorrelationId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$DeliveryId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ExecutionId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$TenantId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClientId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ProjectId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$State
    )

    $cfg = Get-RetentionLifecycleConfig

    if (-not $cfg.enabled -or -not $cfg.lifecycleGuardEnabled) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "LIFECYCLE_GUARD_DISABLED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($RetentionId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RETENTION_ID_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($EventId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "EVENT_ID_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($CorrelationId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CORRELATION_ID_REQUIRED"
        }
    }

    if ($cfg.requireRetentionContext) {

        if ([string]::IsNullOrWhiteSpace($DeliveryId) -or
            [string]::IsNullOrWhiteSpace($ExecutionId) -or
            [string]::IsNullOrWhiteSpace($TenantId) -or
            [string]::IsNullOrWhiteSpace($ClientId) -or
            [string]::IsNullOrWhiteSpace($ProjectId)) {

            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "CONTEXT_INCOMPLETE"
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($State)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "STATE_REQUIRED"
        }
    }

    $allowedStates = @(
        "ACTIVE",
        "RETAINED",
        "EXPIRED"
    )

    $validState = $false

    foreach ($allowed in $allowedStates) {
        if ($allowed -eq $State) {
            $validState = $true
            break
        }
    }

    if (-not $validState) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "STATE_INVALID"
        }
    }

    return [pscustomobject]@{
        Success = $true
        Status  = "VALID"
        Reason  = "RETENTION_LIFECYCLE_CONTEXT_VALID"
    }
}

function Test-RetentionLifecycleTransition {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RetentionId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$FromState,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ToState
    )

    $cfg = Get-RetentionLifecycleConfig

    if (-not $cfg.enabled -or -not $cfg.transitionGuardEnabled) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "TRANSITION_GUARD_DISABLED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($RetentionId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RETENTION_ID_REQUIRED"
        }
    }

    $allowedTransitions = @{
        "ACTIVE" = @("RETAINED")
        "RETAINED" = @("EXPIRED")
        "EXPIRED" = @()
    }

    if (-not $allowedTransitions.ContainsKey($FromState)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "SOURCE_STATE_INVALID"
        }
    }

    if (-not $allowedTransitions.ContainsKey($ToState)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "TARGET_STATE_INVALID"
        }
    }

    if ($cfg.preventBackwardTransition) {

        if ($FromState -eq "RETAINED" -and $ToState -eq "ACTIVE") {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "BACKWARD_TRANSITION_BLOCKED"
            }
        }

        if ($FromState -eq "EXPIRED") {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "EXPIRED_STATE_TERMINAL"
            }
        }
    }

    $targets = @($allowedTransitions[$FromState])

    $validTransition = $false

    foreach ($target in $targets) {
        if ($target -eq $ToState) {
            $validTransition = $true
            break
        }
    }

    if (-not $validTransition) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "TRANSITION_NOT_ALLOWED"
        }
    }

    if ($FromState -eq $ToState) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "IDENTICAL_STATE_TRANSITION_BLOCKED"
        }
    }

    return [pscustomobject]@{
        Success  = $true
        Status   = "AUTHORIZED"
        Reason   = "TRANSITION_ALLOWED"
        FromState = $FromState
        ToState   = $ToState
    }
}

function Initialize-RetentionLifecycle {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RetentionId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$EventId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$CorrelationId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$DeliveryId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ExecutionId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$TenantId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClientId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ProjectId
    )

    $check = Test-RetentionLifecycleContext `
        -RetentionId $RetentionId `
        -EventId $EventId `
        -CorrelationId $CorrelationId `
        -DeliveryId $DeliveryId `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -State "ACTIVE"

    if (-not $check.Success) {
        return $check
    }

    $records = @(Get-RetentionLifecycleRecords)

    foreach ($existing in $records) {
        if ([string]$existing.RetentionId -eq $RetentionId) {
            return [pscustomobject]@{
                Success = $false
                Status  = "DUPLICATE"
                Reason  = "RETENTION_LIFECYCLE_ALREADY_EXISTS"
                RetentionId = $RetentionId
            }
        }
    }

    $cfg = Get-RetentionLifecycleConfig
    $count = @($records).Length

    if ($count -ge [int]$cfg.maxTransitions) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "LIFECYCLE_LIMIT_REACHED"
        }
    }

    $now = [DateTime]::UtcNow
    $expires = $now.AddDays(
        [double]$cfg.retentionDays
    )

    $record = [pscustomobject]@{
        RetentionId    = $RetentionId
        EventId        = $EventId
        CorrelationId  = $CorrelationId
        DeliveryId     = $DeliveryId
        ExecutionId    = $ExecutionId
        TenantId       = $TenantId
        ClientId       = $ClientId
        ProjectId      = $ProjectId
        CurrentState   = "ACTIVE"
        CreatedAtUtc   = $now.ToString("o")
        RetainedAtUtc  = ""
        ExpiresAtUtc   = $expires.ToString("o")
        ExpiredAtUtc   = ""
        TransitionCount = 0
    }

    $newRecords = @($records)
    $newRecords += ,$record

    $null = Save-RetentionLifecycleRecords $newRecords

    return [pscustomobject]@{
        Success = $true
        Status  = "INITIALIZED"
        Reason  = "RETENTION_LIFECYCLE_INITIALIZED"
        RetentionId = $RetentionId
        CurrentState = "ACTIVE"
        ExpiresAtUtc = $expires.ToString("o")
    }
}

function Invoke-RetentionLifecycleTransition {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RetentionId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ToState,

        [Parameter(Mandatory=$false)]
        [datetime]$ReferenceTime = [DateTime]::UtcNow
    )

    $record = Get-RetentionLifecycleRecord `
        -RetentionId $RetentionId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RETENTION_RECORD_NOT_FOUND"
        }
    }

    $fromState = [string]$record.CurrentState

    $check = Test-RetentionLifecycleTransition `
        -RetentionId $RetentionId `
        -FromState $fromState `
        -ToState $ToState

    if (-not $check.Success) {
        return $check
    }

    if ($fromState -eq "RETAINED" -and
        $ToState -eq "EXPIRED") {

        try {
            $expires = [DateTime]::Parse(
                [string]$record.ExpiresAtUtc
            )
        }
        catch {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "EXPIRATION_TIMESTAMP_INVALID"
            }
        }

        if ($ReferenceTime -lt $expires) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "RETENTION_NOT_EXPIRED"
                ExpiresAtUtc = $expires.ToString("o")
            }
        }
    }

    $records = @(Get-RetentionLifecycleRecords)

    foreach ($item in $records) {

        if ([string]$item.RetentionId -eq $RetentionId) {

            $item.CurrentState = $ToState

            if ($ToState -eq "RETAINED") {
                $item.RetainedAtUtc = $ReferenceTime.ToString("o")
            }

            if ($ToState -eq "EXPIRED") {
                $item.ExpiredAtUtc = $ReferenceTime.ToString("o")
            }

            $currentCount = 0

            try {
                $currentCount = [int]$item.TransitionCount
            }
            catch {
                $currentCount = 0
            }

            $item.TransitionCount = $currentCount + 1
        }
    }

    $null = Save-RetentionLifecycleRecords $records

    return [pscustomobject]@{
        Success = $true
        Status  = "TRANSITIONED"
        Reason  = "RETENTION_LIFECYCLE_TRANSITIONED"
        RetentionId = $RetentionId
        FromState = $fromState
        ToState = $ToState
    }
}

function Test-RetentionExpirationEnforcement {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RetentionId,

        [Parameter(Mandatory=$false)]
        [datetime]$ReferenceTime = [DateTime]::UtcNow
    )

    $record = Get-RetentionLifecycleRecord `
        -RetentionId $RetentionId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RETENTION_RECORD_NOT_FOUND"
        }
    }

    try {
        $expires = [DateTime]::Parse(
            [string]$record.ExpiresAtUtc
        )
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "EXPIRATION_TIMESTAMP_INVALID"
        }
    }

    if ($record.CurrentState -eq "EXPIRED") {
        return [pscustomobject]@{
            Success = $true
            Status  = "EXPIRED"
            Reason  = "RETENTION_ALREADY_EXPIRED"
        }
    }

    if ($ReferenceTime -ge $expires) {
        return [pscustomobject]@{
            Success = $true
            Status  = "EXPIRATION_DUE"
            Reason  = "RETENTION_EXPIRATION_DUE"
            ExpiresAtUtc = $expires.ToString("o")
        }
    }

    return [pscustomobject]@{
        Success = $true
        Status  = "ACTIVE"
        Reason  = "RETENTION_NOT_EXPIRED"
        ExpiresAtUtc = $expires.ToString("o")
    }
}

function Reset-RetentionLifecycle {
    $null = Save-RetentionLifecycleRecords @()
    return $true
}