function Get-PermanentLockAuditConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "LOCK_AUDIT_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "LOCK_AUDIT_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-PermanentLockAuditEvents {

    $path = Join-Path $PSScriptRoot "state\events.json"

    if (-not (Test-Path -LiteralPath $path)) {
        return @()
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $data = $raw | ConvertFrom-Json

    if ($null -eq $data) {
        return @()
    }

    if ($data -is [System.Array]) {
        return @($data)
    }

    return @($data)
}

function Save-PermanentLockAuditEvents {

    param(
        [AllowEmptyCollection()]
        [object[]]$Events = @()
    )

    $config = Get-PermanentLockAuditConfig
    $path = Join-Path $PSScriptRoot "state\events.json"

    if ($Events.Count -gt [int]$config.maxRecords) {
        throw "LOCK_AUDIT_RECORD_LIMIT"
    }

    if ($Events.Count -eq 0) {
        Set-Content `
            -LiteralPath $path `
            -Value "[]" `
            -Encoding UTF8
        return
    }

    $json = ConvertTo-Json `
        -InputObject @($Events) `
        -Depth 30

    Set-Content `
        -LiteralPath $path `
        -Value $json `
        -Encoding UTF8
}

function Get-PermanentLockAuditHash {

    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $digest = $sha.ComputeHash($bytes)

        return ([System.BitConverter]::ToString($digest)).Replace("-", "").ToLowerInvariant()
    }
    finally {

        $sha.Dispose()
    }
}

function New-PermanentLockAuditEventId {

    return "AUDIT-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Write-PermanentLockAuditEvent {

    param(
        [Parameter(Mandatory)][string]$FinalizationId,
        [Parameter(Mandatory)][string]$RecoveryId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$EventType,
        [Parameter(Mandatory)][string]$Decision,
        [Parameter(Mandatory)][string]$Actor
    )

    $config = Get-PermanentLockAuditConfig

    if (-not $config.enabled) {
        throw "LOCK_AUDIT_DISABLED"
    }

    if (-not $config.auditEnabled) {
        throw "AUDIT_DISABLED"
    }

    $required = @(
        $FinalizationId
        $RecoveryId
        $TenantId
        $ClientId
        $ProjectId
        $WorkerId
        $EventType
        $Decision
        $Actor
    )

    foreach ($value in $required) {

        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "AUDIT_FIELD_REQUIRED"
        }
    }

    $events = @(Get-PermanentLockAuditEvents)

    $prevHash = $config.genesisPrevHash

    if ($events.Count -gt 0) {
        $prevHash = $events[$events.Count - 1].EventHash
    }

    $eventId = New-PermanentLockAuditEventId
    $now = (Get-Date).ToUniversalTime().ToString("o")

    $canonical = (
        $eventId + "|" +
        $FinalizationId + "|" +
        $RecoveryId + "|" +
        $TenantId + "|" +
        $ClientId + "|" +
        $ProjectId + "|" +
        $WorkerId + "|" +
        $EventType + "|" +
        $Decision + "|" +
        $Actor + "|" +
        $now + "|" +
        $prevHash
    )

    $eventHash = Get-PermanentLockAuditHash -Value $canonical

    $event = [pscustomobject][ordered]@{
        EventId        = $eventId
        FinalizationId = $FinalizationId
        RecoveryId     = $RecoveryId
        TenantId       = $TenantId
        ClientId       = $ClientId
        ProjectId      = $ProjectId
        WorkerId       = $WorkerId
        EventType      = $EventType
        Decision       = $Decision
        Actor          = $Actor
        TimestampUtc   = $now
        PreviousHash   = $prevHash
        EventHash      = $eventHash
        Immutable      = $true
        AppendOnly     = $true
        RawSecret      = $null
        RawCredential  = $null
    }

    $events += $event

    Save-PermanentLockAuditEvents -Events $events

    return $event
}

function Test-PermanentLockAuditIntegrity {

    $config = Get-PermanentLockAuditConfig
    $events = @(Get-PermanentLockAuditEvents)

    if ($events.Count -eq 0) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = $config.tamperedDecision
            Code = "AUDIT_EMPTY"
        }
    }

    $expectedPreviousHash = $config.genesisPrevHash

    foreach ($event in $events) {

        if ($event.PreviousHash -ne $expectedPreviousHash) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = $config.tamperedDecision
                Code = "HASH_CHAIN_BROKEN"
                EventId = $event.EventId
            }
        }

        $canonical = (
            $event.EventId + "|" +
            $event.FinalizationId + "|" +
            $event.RecoveryId + "|" +
            $event.TenantId + "|" +
            $event.ClientId + "|" +
            $event.ProjectId + "|" +
            $event.WorkerId + "|" +
            $event.EventType + "|" +
            $event.Decision + "|" +
            $event.Actor + "|" +
            $event.TimestampUtc + "|" +
            $event.PreviousHash
        )

        $expectedHash = Get-PermanentLockAuditHash -Value $canonical

        if ($event.EventHash -ne $expectedHash) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = $config.tamperedDecision
                Code = "EVENT_HASH_INVALID"
                EventId = $event.EventId
            }
        }

        if ($event.Immutable -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = $config.tamperedDecision
                Code = "IMMUTABLE_FLAG_INVALID"
                EventId = $event.EventId
            }
        }

        if ($event.AppendOnly -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = $config.tamperedDecision
                Code = "APPEND_ONLY_FLAG_INVALID"
                EventId = $event.EventId
            }
        }

        $expectedPreviousHash = $event.EventHash
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "AUDIT_INTEGRITY_VALID"
        EventCount = $events.Count
    }
}

function Test-PermanentLockAuditFinalizedState {

    param(
        [Parameter(Mandatory)]
        [string]$FinalizationId
    )

    $events = @(Get-PermanentLockAuditEvents)

    $matching = @(
        $events |
        Where-Object {
            $_.FinalizationId -eq $FinalizationId
        }
    )

    if ($matching.Count -eq 0) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "FINALIZATION_AUDIT_NOT_FOUND"
        }
    }

    # IMPORTANT :
    # La finalisation peut être suivie d'autres événements.
    # On recherche donc l'événement FINALIZED dans toute la chaîne.

    $finalizationEvents = @(
        $matching |
        Where-Object {
            $_.EventType -eq "PERMANENT_LOCK_FINALIZED"
        }
    )

    if ($finalizationEvents.Count -eq 0) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "FINALIZATION_EVENT_MISSING"
        }
    }

    $finalizationEvent = $finalizationEvents[0]

    if ($finalizationEvent.Decision -ne "ALLOW") {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "INVALID_FINALIZATION_DECISION"
        }
    }

    if ($finalizationEvent.Immutable -ne $true) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "FINALIZATION_NOT_IMMUTABLE"
        }
    }

    if ($finalizationEvent.AppendOnly -ne $true) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "FINALIZATION_NOT_APPEND_ONLY"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "FINALIZATION_AUDITED"
        EventId = $finalizationEvent.EventId
    }
}

function Test-PermanentLockTamper {

    param(
        [Parameter(Mandatory)]
        [string]$FinalizationId
    )

    $integrity = Test-PermanentLockAuditIntegrity

    if ($integrity.Allowed -ne $true) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = $integrity.Code
        }
    }

    $finalized = Test-PermanentLockAuditFinalizedState `
        -FinalizationId $FinalizationId

    if ($finalized.Allowed -ne $true) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = $finalized.Code
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "LOCK_AUDIT_TRUSTED"
    }
}

function Reset-PermanentLockAudit {

    Save-PermanentLockAuditEvents
}
