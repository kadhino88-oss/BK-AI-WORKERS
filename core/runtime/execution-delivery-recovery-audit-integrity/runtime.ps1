function Get-RecoveryAuditIntegrityConfig {
    $path = Join-Path $PSScriptRoot "config.json"

    return (
        Get-Content -Raw -Path $path |
        ConvertFrom-Json
    )
}

function Get-RecoveryAuditIntegrityField {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $cfg = Get-RecoveryAuditIntegrityConfig

    $prop = $cfg.PSObject.Properties[$Name]

    if ($null -eq $prop) {
        return $null
    }

    return $prop.Value
}

function Get-RecoveryAuditIntegrityEvents {
    $path = Join-Path $PSScriptRoot "state\integrity-events.json"

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

function Save-RecoveryAuditIntegrityEvents {
    param(
        [Parameter(Mandatory=$false)]
        $Events
    )

    $path = Join-Path $PSScriptRoot "state\integrity-events.json"

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

function Get-RecoveryAuditIntegrityEvent {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$EventId
    )

    if ([string]::IsNullOrWhiteSpace($EventId)) {
        return $null
    }

    $events = @(Get-RecoveryAuditIntegrityEvents)

    foreach ($event in $events) {
        if ([string]$event.EventId -eq $EventId) {
            return $event
        }
    }

    return $null
}

function Get-RecoveryAuditIntegrityCanonicalContent {
    param(
        [Parameter(Mandatory=$false)]
        $Event
    )

    if ($null -eq $Event) {
        return ""
    }

    return (
        "{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}|{12}|{13}" -f
        [string]$Event.EventId,
        [string]$Event.Sequence,
        [string]$Event.CorrelationId,
        [string]$Event.DeliveryId,
        [string]$Event.ExecutionId,
        [string]$Event.TenantId,
        [string]$Event.ClientId,
        [string]$Event.ProjectId,
        [string]$Event.RecoveryId,
        [string]$Event.AuthorizationId,
        [string]$Event.FinalizationId,
        [string]$Event.ClosureId,
        [string]$Event.LifecycleState,
        [string]$Event.EventType
    )
}

function Get-SHA256 {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Content
    )

    $sha = New-Object System.Security.Cryptography.SHA256Managed

    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(
            [string]$Content
        )

        return (
            [System.BitConverter]::ToString(
                $sha.ComputeHash($bytes)
            ) -replace "-", ""
        ).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Test-RecoveryAuditIntegrityContext {
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

    $cfg = Get-RecoveryAuditIntegrityConfig

    if (-not $cfg.enabled -or -not $cfg.integrityGuardEnabled) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "INTEGRITY_GUARD_DISABLED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($EventId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "EVENT_ID_REQUIRED"
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

    if ([string]::IsNullOrWhiteSpace($RecoveryId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RECOVERY_ID_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($AuthorizationId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "AUTHORIZATION_ID_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($FinalizationId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "FINALIZATION_ID_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ClosureId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CLOSURE_ID_REQUIRED"
        }
    }

    if ($cfg.requireLifecycleState) {
        if ([string]::IsNullOrWhiteSpace($LifecycleState)) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "LIFECYCLE_STATE_REQUIRED"
            }
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
        Reason  = "INTEGRITY_CONTEXT_VALID"
    }
}

function Add-RecoveryAuditIntegrityEvent {
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

    $check = Test-RecoveryAuditIntegrityContext `
        -EventId $EventId `
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

    $events = @(Get-RecoveryAuditIntegrityEvents)
    $eventCount = @($events).Length
    $cfg = Get-RecoveryAuditIntegrityConfig

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

    if ($eventCount -ge [int]$cfg.maxEvents) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "AUDIT_EVENT_LIMIT_REACHED"
        }
    }

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

    $previousHash = ""

    if ($eventCount -gt 0) {
        $last = $events[$eventCount - 1]

        if ($null -ne $last.EventHash) {
            $previousHash = [string]$last.EventHash
        }
    }

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
        PreviousHash     = $previousHash
    }

    $canonical = Get-RecoveryAuditIntegrityCanonicalContent $event

    $hashInput = "{0}|{1}" -f $previousHash, $canonical

    $eventHash = Get-SHA256 $hashInput

    $event | Add-Member -MemberType NoteProperty `
        -Name EventHash `
        -Value $eventHash `
        -Force

    $event | Add-Member -MemberType NoteProperty `
        -Name CreatedAtUtc `
        -Value ([DateTime]::UtcNow.ToString("o")) `
        -Force

    $newEvents = @()

    foreach ($existing in @($events)) {
        $newEvents += ,$existing
    }

    $newEvents += ,$event

    $null = Save-RecoveryAuditIntegrityEvents $newEvents

    return [pscustomobject]@{
        Success       = $true
        Status        = "RECORDED"
        Reason        = "INTEGRITY_EVENT_RECORDED"
        EventId       = $EventId
        Sequence      = $sequence
        PreviousHash  = $previousHash
        EventHash     = $eventHash
        CorrelationId = $CorrelationId
    }
}

function Test-RecoveryAuditIntegrityChain {
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

    $events = @(
        Get-RecoveryAuditIntegrityEvents |
        Where-Object {
            [string]$_.CorrelationId -eq $CorrelationId
        }
    )

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

    $expectedSequence = 1
    $previousHash = ""

    foreach ($event in $ordered) {

        try {
            $actualSequence = [int]$event.Sequence
        }
        catch {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "SEQUENCE_INVALID"
            }
        }

        if ($actualSequence -ne $expectedSequence) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "SEQUENCE_GAP_OR_REORDER"
            }
        }

        if ([string]$event.PreviousHash -ne $previousHash) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "PREVIOUS_HASH_MISMATCH"
            }
        }

        $canonical = Get-RecoveryAuditIntegrityCanonicalContent $event

        $expectedHash = Get-SHA256 (
            "{0}|{1}" -f
            $previousHash,
            $canonical
        )

        if ([string]$event.EventHash -ne $expectedHash) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "EVENT_HASH_MISMATCH"
            }
        }

        $previousHash = [string]$event.EventHash

        $expectedSequence++
    }

    return [pscustomobject]@{
        Success     = $true
        Status      = "VALID"
        Reason      = "INTEGRITY_CHAIN_VALID"
        EventCount  = @($ordered).Length
        FinalHash   = $previousHash
    }
}

function Reset-RecoveryAuditIntegrity {
    $null = Save-RecoveryAuditIntegrityEvents @()
    return $true
}