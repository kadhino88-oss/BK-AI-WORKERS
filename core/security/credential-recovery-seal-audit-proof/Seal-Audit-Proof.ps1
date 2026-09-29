function Get-SealAuditProofConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "SEAL_AUDIT_PROOF_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "SEAL_AUDIT_PROOF_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-SealAuditProofEvents {

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

    return @($data)
}

function Save-SealAuditProofEvents {

    param(
        [AllowEmptyCollection()]
        [object[]]$Events = @()
    )

    $config = Get-SealAuditProofConfig
    $path = Join-Path $PSScriptRoot "state\events.json"

    if ($Events.Count -gt [int]$config.maxRecords) {
        throw "SEAL_AUDIT_PROOF_RECORD_LIMIT"
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
        -Depth 40

    Set-Content `
        -LiteralPath $path `
        -Value $json `
        -Encoding UTF8
}

function Get-SealAuditProofHash {

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

function New-SealAuditProofEventId {

    return "TRACE-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Write-SealAuditProofEvent {

    param(
        [Parameter(Mandatory)][string]$SealId,
        [Parameter(Mandatory)][string]$LifecycleId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$ExecutionId,
        [Parameter(Mandatory)][string]$EventType,
        [Parameter(Mandatory)][string]$LifecycleState,
        [Parameter(Mandatory)][string]$Actor
    )

    $config = Get-SealAuditProofConfig

    if (-not $config.enabled) {
        throw "SEAL_AUDIT_PROOF_DISABLED"
    }

    if (-not $config.auditEnabled) {
        throw "SEAL_AUDIT_DISABLED"
    }

    $required = @(
        $SealId
        $LifecycleId
        $TenantId
        $ClientId
        $ProjectId
        $ExecutionId
        $EventType
        $LifecycleState
        $Actor
    )

    foreach ($value in $required) {

        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "TRACE_FIELD_REQUIRED"
        }
    }

    $validEventTypes = @(
        "SEAL_CREATED"
        "SEAL_ACTIVATED"
        "SEAL_REVOKED"
        "SEAL_CLOSED"
    )

    if ($validEventTypes -notcontains $EventType) {
        throw "INVALID_LIFECYCLE_EVENT"
    }

    $events = @(Get-SealAuditProofEvents)

    foreach ($existing in $events) {

        if (
            $existing.SealId -eq $SealId -and
            $existing.EventType -eq $EventType
        ) {
            throw "DUPLICATE_LIFECYCLE_EVENT"
        }
    }

    $expectedSequence = 1

    if ($events.Count -gt 0) {
        $expectedSequence = $events[$events.Count - 1].Sequence + 1
    }

    if ($EventType -eq "SEAL_CREATED") {

        if ($events.Count -gt 0) {
            throw "CREATE_EVENT_MUST_BE_FIRST"
        }

        if ($LifecycleState -ne "SEALED") {
            throw "CREATE_STATE_INVALID"
        }
    }

    if ($EventType -eq "SEAL_ACTIVATED") {

        if ($LifecycleState -ne "ACTIVE") {
            throw "ACTIVATION_STATE_INVALID"
        }
    }

    if ($EventType -eq "SEAL_REVOKED") {

        if ($LifecycleState -ne "REVOKED") {
            throw "REVOCATION_STATE_INVALID"
        }
    }

    if ($EventType -eq "SEAL_CLOSED") {

        if ($LifecycleState -ne "CLOSED") {
            throw "CLOSURE_STATE_INVALID"
        }
    }

    if ($events.Count -gt 0) {

        $last = $events[$events.Count - 1]

        $allowedTransition = $false

        if (
            $last.EventType -eq "SEAL_CREATED" -and
            $EventType -eq "SEAL_ACTIVATED"
        ) {
            $allowedTransition = $true
        }

        if (
            $last.EventType -eq "SEAL_ACTIVATED" -and
            $EventType -eq "SEAL_REVOKED"
        ) {
            $allowedTransition = $true
        }

        if (
            $last.EventType -eq "SEAL_REVOKED" -and
            $EventType -eq "SEAL_CLOSED"
        ) {
            $allowedTransition = $true
        }

        if (-not $allowedTransition) {
            throw "INVALID_LIFECYCLE_TRANSITION"
        }
    }

    $prevHash = $config.genesisPrevHash

    if ($events.Count -gt 0) {
        $prevHash = $events[$events.Count - 1].EventHash
    }

    $now = (Get-Date).ToUniversalTime().ToString("o")
    $eventId = New-SealAuditProofEventId

    $canonical = (
        $eventId + "|" +
        $expectedSequence + "|" +
        $SealId + "|" +
        $LifecycleId + "|" +
        $TenantId + "|" +
        $ClientId + "|" +
        $ProjectId + "|" +
        $ExecutionId + "|" +
        $EventType + "|" +
        $LifecycleState + "|" +
        $Actor + "|" +
        $now + "|" +
        $prevHash
    )

    $eventHash = Get-SealAuditProofHash `
        -Value $canonical

    $event = [pscustomobject][ordered]@{
        EventId         = $eventId
        Sequence        = $expectedSequence
        EventHash       = $eventHash
        PreviousHash    = $prevHash

        SealId          = $SealId
        LifecycleId     = $LifecycleId

        TenantId        = $TenantId
        ClientId        = $ClientId
        ProjectId       = $ProjectId
        ExecutionId     = $ExecutionId

        EventType       = $EventType
        LifecycleState  = $LifecycleState
        Actor           = $Actor

        Immutable       = $true
        AppendOnly      = $true
        PermanentProof  = $true

        CreatedAtUtc    = $now

        RawSecret       = $null
        RawCredential   = $null
    }

    $events += $event

    Save-SealAuditProofEvents -Events $events

    return $event
}

function Test-SealAuditProofIntegrity {

    $config = Get-SealAuditProofConfig
    $events = @(Get-SealAuditProofEvents)

    if ($events.Count -eq 0) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "AUDIT_TRACE_EMPTY"
        }
    }

    $expectedSequence = 1
    $expectedPreviousHash = $config.genesisPrevHash

    foreach ($event in $events) {

        if ($event.Sequence -ne $expectedSequence) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "TRACE_SEQUENCE_INVALID"
                EventId = $event.EventId
            }
        }

        if ($event.PreviousHash -ne $expectedPreviousHash) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "TRACE_CHAIN_BROKEN"
                EventId = $event.EventId
            }
        }

        $canonical = (
            $event.EventId + "|" +
            $event.Sequence + "|" +
            $event.SealId + "|" +
            $event.LifecycleId + "|" +
            $event.TenantId + "|" +
            $event.ClientId + "|" +
            $event.ProjectId + "|" +
            $event.ExecutionId + "|" +
            $event.EventType + "|" +
            $event.LifecycleState + "|" +
            $event.Actor + "|" +
            $event.CreatedAtUtc + "|" +
            $event.PreviousHash
        )

        $expectedHash = Get-SealAuditProofHash `
            -Value $canonical

        if ($event.EventHash -ne $expectedHash) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "TRACE_HASH_INVALID"
                EventId = $event.EventId
            }
        }

        if ($event.Immutable -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "TRACE_NOT_IMMUTABLE"
            }
        }

        if ($event.AppendOnly -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "TRACE_NOT_APPEND_ONLY"
            }
        }

        $expectedPreviousHash = $event.EventHash
        $expectedSequence++
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "SEAL_AUDIT_TRACE_INTEGRITY_VALID"
        EventCount = $events.Count
    }
}

function Test-SealLifecycleClosureProof {

    param(
        [Parameter(Mandatory)]
        [string]$SealId
    )

    $events = @(
        Get-SealAuditProofEvents |
        Where-Object {
            $_.SealId -eq $SealId
        }
    )

    if ($events.Count -ne 4) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "LIFECYCLE_TRACE_INCOMPLETE"
        }
    }

    $expectedTypes = @(
        "SEAL_CREATED"
        "SEAL_ACTIVATED"
        "SEAL_REVOKED"
        "SEAL_CLOSED"
    )

    for ($i = 0; $i -lt 4; $i++) {

        if ($events[$i].EventType -ne $expectedTypes[$i]) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "LIFECYCLE_ORDER_INVALID"
            }
        }
    }

    if ($events[0].LifecycleState -ne "SEALED") {
        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "CREATED_STATE_INVALID"
        }
    }

    if ($events[1].LifecycleState -ne "ACTIVE") {
        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "ACTIVATED_STATE_INVALID"
        }
    }

    if ($events[2].LifecycleState -ne "REVOKED") {
        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "REVOKED_STATE_INVALID"
        }
    }

    if ($events[3].LifecycleState -ne "CLOSED") {
        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "CLOSED_STATE_INVALID"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "BLOCK"
        Code = "SEAL_CLOSURE_PROOF_VALID"
    }
}

function Test-SealAuditProofScope {

    param(
        [Parameter(Mandatory)][string]$SealId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$ExecutionId
    )

    $events = @(
        Get-SealAuditProofEvents |
        Where-Object {
            $_.SealId -eq $SealId
        }
    )

    if ($events.Count -eq 0) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "SEAL_NOT_FOUND"
        }
    }

    foreach ($event in $events) {

        if ($event.TenantId -ne $TenantId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_TENANT_TRACE"
            }
        }

        if ($event.ClientId -ne $ClientId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_CLIENT_TRACE"
            }
        }

        if ($event.ProjectId -ne $ProjectId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_PROJECT_TRACE"
            }
        }

        if ($event.ExecutionId -ne $ExecutionId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_EXECUTION_TRACE"
            }
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "SEAL_AUDIT_SCOPE_VALID"
    }
}

function Test-SealClosureProofFinality {

    param(
        [Parameter(Mandatory)]
        [string]$SealId
    )

    $events = @(
        Get-SealAuditProofEvents |
        Where-Object {
            $_.SealId -eq $SealId
        }
    )

    if ($events.Count -ne 4) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "FINAL_PROOF_INCOMPLETE"
        }
    }

    $last = $events[$events.Count - 1]

    if ($last.EventType -ne "SEAL_CLOSED") {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "CLOSURE_EVENT_MISSING"
        }
    }

    if ($last.LifecycleState -ne "CLOSED") {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "CLOSURE_STATE_INVALID"
        }
    }

    if ($last.Immutable -ne $true) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "CLOSURE_NOT_IMMUTABLE"
        }
    }

    if ($last.PermanentProof -ne $true) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "PERMANENT_PROOF_MISSING"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "BLOCK"
        Code = "SEAL_CLOSURE_FINAL_PROOF_VALID"
    }
}

function Reset-SealAuditProof {

    Save-SealAuditProofEvents
}
