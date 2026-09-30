function Get-RecoveryAuditConfig {
    $path = Join-Path $PSScriptRoot "config.json"

    return (
        Get-Content -Raw -Path $path |
        ConvertFrom-Json
    )
}

function Get-RecoveryAuditField {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $cfg = Get-RecoveryAuditConfig
    $prop = $cfg.PSObject.Properties[$Name]

    if ($null -eq $prop) {
        return $null
    }

    return $prop.Value
}

function Get-RecoveryAuditEvents {
    $path = Join-Path $PSScriptRoot "state\audit-events.json"

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

function Save-RecoveryAuditEvents {
    param(
        [Parameter(Mandatory=$false)]
        $Events
    )

    $path = Join-Path $PSScriptRoot "state\audit-events.json"

    $normalized = @()

    foreach ($item in @($Events)) {
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

function Get-RecoveryAuditEvent {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$EventId
    )

    if ([string]::IsNullOrWhiteSpace($EventId)) {
        return $null
    }

    $events = @(Get-RecoveryAuditEvents)

    foreach ($event in $events) {
        if ([string]$event.EventId -eq $EventId) {
            return $event
        }
    }

    return $null
}

function Get-RecoveryAuditCorrelation {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$CorrelationId
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationId)) {
        return @()
    }

    $events = @(Get-RecoveryAuditEvents)
    $matches = @()

    foreach ($event in $events) {
        if ([string]$event.CorrelationId -eq $CorrelationId) {
            $matches += ,$event
        }
    }

    return $matches
}

function Test-RecoveryAuditTrace {
    param(
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
        [string]$RecoveryId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$AuthorizationId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$FinalizationId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClosureId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$LifecycleState,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$EventType
    )

    $cfg = Get-RecoveryAuditConfig

    if (-not $cfg.enabled -or -not $cfg.auditGuardEnabled) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "AUDIT_GUARD_DISABLED"
        }
    }

    if ($cfg.requireCorrelationId) {
        if ([string]::IsNullOrWhiteSpace($CorrelationId)) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "CORRELATION_ID_REQUIRED"
            }
        }
    }

    if ($cfg.requireDeliveryContext) {
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

    if ($cfg.requireRecoveryId) {
        if ([string]::IsNullOrWhiteSpace($RecoveryId)) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "RECOVERY_ID_REQUIRED"
            }
        }
    }

    if ($cfg.requireAuthorizationId) {
        if ([string]::IsNullOrWhiteSpace($AuthorizationId)) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "AUTHORIZATION_ID_REQUIRED"
            }
        }
    }

    if ($cfg.requireFinalizationId) {
        if ([string]::IsNullOrWhiteSpace($FinalizationId)) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "FINALIZATION_ID_REQUIRED"
            }
        }
    }

    if ($cfg.requireClosureId) {
        if ([string]::IsNullOrWhiteSpace($ClosureId)) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "CLOSURE_ID_REQUIRED"
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($LifecycleState)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "LIFECYCLE_STATE_REQUIRED"
        }
    }

    $allowedStates = @($cfg.allowedLifecycle)

    $stateFound = $false

    foreach ($allowedState in $allowedStates) {
        if ([string]$allowedState -eq $LifecycleState) {
            $stateFound = $true
            break
        }
    }

    if (-not $stateFound) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "LIFECYCLE_STATE_INVALID"
        }
    }

    if ([string]::IsNullOrWhiteSpace($EventType)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "EVENT_TYPE_REQUIRED"
        }
    }

    return [pscustomobject]@{
        Success = $true
        Status  = "VALID"
        Reason  = "RECOVERY_AUDIT_TRACE_VALID"
    }
}

function Add-RecoveryAuditEvent {
    param(
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
        [string]$RecoveryId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$AuthorizationId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$FinalizationId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClosureId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$LifecycleState,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$EventType
    )

    $check = Test-RecoveryAuditTrace `
        -CorrelationId $CorrelationId `
        -DeliveryId $DeliveryId `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -RecoveryId $RecoveryId `
        -AuthorizationId $AuthorizationId `
        -FinalizationId $FinalizationId `
        -ClosureId $ClosureId `
        -LifecycleState $LifecycleState `
        -EventType $EventType

    if (-not $check.Success) {
        return $check
    }

    $events = @(Get-RecoveryAuditEvents)

    # Count robuste
    $eventCount = @($events).Length

    # Vérification EventId
    if (-not [string]::IsNullOrWhiteSpace($EventId)) {

        foreach ($existing in @($events)) {

            if ([string]$existing.EventId -eq $EventId) {

                return [pscustomobject]@{
                    Success = $false
                    Status  = "DUPLICATE"
                    Reason  = "EVENT_ALREADY_EXISTS"
                    EventId = $EventId
                }
            }
        }
    }
    else {
        $EventId = [guid]::NewGuid().ToString()
    }

    $cfg = Get-RecoveryAuditConfig

    if ($eventCount -ge [int]$cfg.maxEvents) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "AUDIT_EVENT_LIMIT_REACHED"
        }
    }

    # Séquence robuste basée sur le maximum existant
    $maxSequence = 0

    foreach ($existing in @($events)) {

        try {
            $seq = [int]$existing.Sequence

            if ($seq -gt $maxSequence) {
                $maxSequence = $seq
            }
        }
        catch {
        }
    }

    $sequence = $maxSequence + 1

    $event = [pscustomobject]@{
        EventId          = $EventId
        Sequence         = $sequence
        CorrelationId    = $CorrelationId
        DeliveryId       = $DeliveryId
        ExecutionId      = $ExecutionId
        TenantId         = $TenantId
        ClientId         = $ClientId
        ProjectId        = $ProjectId
        RecoveryId       = $RecoveryId
        AuthorizationId  = $AuthorizationId
        FinalizationId   = $FinalizationId
        ClosureId        = $ClosureId
        LifecycleState   = $LifecycleState
        EventType        = $EventType
        CreatedAtUtc     = [DateTime]::UtcNow.ToString("o")
    }

    $newEvents = @()

    foreach ($existing in @($events)) {
        $newEvents += ,$existing
    }

    $newEvents += ,$event

    $null = Save-RecoveryAuditEvents $newEvents

    return [pscustomobject]@{
        Success       = $true
        Status        = "RECORDED"
        Reason        = "RECOVERY_AUDIT_EVENT_RECORDED"
        EventId       = $EventId
        Sequence      = $sequence
        CorrelationId = $CorrelationId
    }
}

function Test-RecoveryLifecycleTrace {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$CorrelationId
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CORRELATION_ID_REQUIRED"
        }
    }

    $events = @(Get-RecoveryAuditCorrelation -CorrelationId $CorrelationId)

    if (@($events).Length -eq 0) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "TRACE_NOT_FOUND"
        }
    }

    $ordered = @(
        $events |
        Sort-Object -Property @{
            Expression = {
                try {
                    [int]$_.Sequence
                }
                catch {
                    0
                }
            }
        }
    )

    $expected = @(
        "AUTHORIZED",
        "RECOVERING",
        "CONSISTENT",
        "FINALIZED",
        "CLOSED"
    )

    if (@($ordered).Length -ne 5) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "TRACE_INCOMPLETE"
        }
    }

    for ($i = 0; $i -lt 5; $i++) {

        $expectedSequence = $i + 1

        try {
            $actualSequence = [int]$ordered[$i].Sequence
        }
        catch {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason = "TRACE_SEQUENCE_INVALID"
            }
        }

        if ($actualSequence -ne $expectedSequence) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason = "TRACE_SEQUENCE_INVALID"
            }
        }

        $actualState = [string]$ordered[$i].LifecycleState

        if ($actualState -ne $expected[$i]) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason = "TRACE_ORDER_INVALID"
            }
        }
    }

    return [pscustomobject]@{
        Success    = $true
        Status     = "VALID"
        Reason     = "RECOVERY_LIFECYCLE_TRACE_VALID"
        EventCount = 5
    }
}

function Reset-RecoveryAudit {
    $null = Save-RecoveryAuditEvents @()
    return $true
}