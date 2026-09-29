function Get-CredentialRecoveryActivationAuditConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "ACTIVATION_AUDIT_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "ACTIVATION_AUDIT_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-CredentialRecoveryActivationAuditRecords {

    $path = Join-Path $PSScriptRoot "state\records.json"

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

function Save-CredentialRecoveryActivationAuditRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-CredentialRecoveryActivationAuditConfig

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "ACTIVATION_AUDIT_RECORD_LIMIT"
    }

    $path = Join-Path $PSScriptRoot "state\records.json"

    if ($Records.Count -eq 0) {
        Set-Content -LiteralPath $path -Value "[]" -Encoding UTF8
        return
    }

    $json = ConvertTo-Json -InputObject @($Records) -Depth 30

    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
}

function Get-CredentialRecoveryActivationAuditRecord {

    param(
        [Parameter(Mandatory)]
        [string]$EventId
    )

    $records = @(Get-CredentialRecoveryActivationAuditRecords)

    foreach ($record in $records) {

        if ($record.EventId -eq $EventId) {
            return $record
        }
    }

    return $null
}

function Get-ActivationAuditHash {

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

function New-ActivationAuditEventId {

    return "AEVENT-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Get-ActivationAuditPreviousHash {

    $records = @(Get-CredentialRecoveryActivationAuditRecords)

    if ($records.Count -eq 0) {
        return "GENESIS"
    }

    $last = $records[$records.Count - 1]

    if ([string]::IsNullOrWhiteSpace($last.EventHash)) {
        throw "AUDIT_CHAIN_CORRUPTED"
    }

    return $last.EventHash
}

function Write-CredentialRecoveryActivationAuditEvent {

    param(
        [Parameter(Mandatory)][string]$EventType,
        [Parameter(Mandatory)][string]$ActivationId,
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$ContextId,
        [Parameter(Mandatory)][string]$OldChainId,
        [Parameter(Mandatory)][string]$NewChainId,
        [Parameter(Mandatory)][string]$NewLeaseId,
        [Parameter(Mandatory)][string]$NewMaterializationId,
        [Parameter(Mandatory)][string]$NewUsageId,
        [Parameter(Mandatory)][string]$NewExecutionId,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Connector,
        [Parameter(Mandatory)][string]$Decision,
        [Parameter(Mandatory)][string]$Reason
    )

    $config = Get-CredentialRecoveryActivationAuditConfig

    if (-not $config.enabled) {
        throw "AUDIT_DISABLED"
    }

    if (-not $config.auditEnabled) {
        throw "AUDIT_DISABLED"
    }

    if ([string]::IsNullOrWhiteSpace($EventType)) {
        throw "EVENT_TYPE_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($ActivationId)) {
        throw "ACTIVATION_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($AuthorizationId)) {
        throw "AUTHORIZATION_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($ContextId)) {
        throw "CONTEXT_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($NewChainId)) {
        throw "NEW_CHAIN_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($NewExecutionId)) {
        throw "NEW_EXECUTION_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($UserId)) {
        throw "USER_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw "TENANT_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        throw "CLIENT_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($ProjectId)) {
        throw "PROJECT_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($WorkerId)) {
        throw "WORKER_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Action)) {
        throw "ACTION_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Connector)) {
        throw "CONNECTOR_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Decision)) {
        throw "DECISION_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        throw "REASON_REQUIRED"
    }

    $now = (Get-Date).ToUniversalTime()
    $eventId = New-ActivationAuditEventId
    $previousHash = Get-ActivationAuditPreviousHash

    $canonical = (
        $eventId + "|" +
        $EventType + "|" +
        $ActivationId + "|" +
        $AuthorizationId + "|" +
        $ContextId + "|" +
        $OldChainId + "|" +
        $NewChainId + "|" +
        $NewLeaseId + "|" +
        $NewMaterializationId + "|" +
        $NewUsageId + "|" +
        $NewExecutionId + "|" +
        $UserId + "|" +
        $TenantId + "|" +
        $ClientId + "|" +
        $ProjectId + "|" +
        $WorkerId + "|" +
        $Action + "|" +
        $Connector + "|" +
        $Decision + "|" +
        $Reason + "|" +
        $now.ToString("o") + "|" +
        $previousHash
    )

    $eventHash = Get-ActivationAuditHash -Value $canonical

    $record = [pscustomobject][ordered]@{
        EventId             = $eventId
        EventType           = $EventType
        ActivationId        = $ActivationId
        AuthorizationId     = $AuthorizationId
        ContextId           = $ContextId
        OldChainId          = $OldChainId
        NewChainId          = $NewChainId
        NewLeaseId          = $NewLeaseId
        NewMaterializationId = $NewMaterializationId
        NewUsageId          = $NewUsageId
        NewExecutionId      = $NewExecutionId
        UserId              = $UserId
        TenantId            = $TenantId
        ClientId            = $ClientId
        ProjectId           = $ProjectId
        WorkerId            = $WorkerId
        Action              = $Action
        Connector           = $Connector
        Decision            = $Decision
        Reason              = $Reason
        CreatedAtUtc        = $now.ToString("o")
        PreviousEventHash   = $previousHash
        EventHash           = $eventHash
        Immutable           = $true
        RawSecret           = $null
        RawCredential       = $null
    }

    $records = @(Get-CredentialRecoveryActivationAuditRecords)

    $records += $record

    Save-CredentialRecoveryActivationAuditRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        EventId = $eventId
        EventHash = $eventHash
        PreviousEventHash = $previousHash
    }
}

function Test-CredentialRecoveryActivationAuditIntegrity {

    param(
        [Parameter(Mandatory)]
        [string]$EventId
    )

    $record = Get-CredentialRecoveryActivationAuditRecord `
        -EventId $EventId

    if ($null -eq $record) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_FOUND"
        }
    }

    if ($record.Immutable -ne $true) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "IMMUTABILITY_FAILURE"
        }
    }

    if ([string]::IsNullOrWhiteSpace($record.EventHash)) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "EVENT_HASH_MISSING"
        }
    }

    if ([string]::IsNullOrWhiteSpace($record.PreviousEventHash)) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "PREVIOUS_HASH_MISSING"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Code = "INTEGRITY_VALID"
        EventId = $record.EventId
        EventHash = $record.EventHash
    }
}

function Test-CredentialRecoveryActivationAuditChain {

    $records = @(Get-CredentialRecoveryActivationAuditRecords)

    if ($records.Count -eq 0) {

        return [pscustomobject]@{
            Allowed = $true
            Code = "EMPTY_CHAIN"
            Count = 0
        }
    }

    $previous = "GENESIS"

    foreach ($record in $records) {

        if ($record.PreviousEventHash -ne $previous) {

            return [pscustomobject]@{
                Allowed = $false
                Code = "CHAIN_LINK_FAILURE"
                EventId = $record.EventId
            }
        }

        if ($record.Immutable -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Code = "IMMUTABILITY_FAILURE"
                EventId = $record.EventId
            }
        }

        $previous = $record.EventHash
    }

    return [pscustomobject]@{
        Allowed = $true
        Code = "CHAIN_VALID"
        Count = $records.Count
    }
}

function Test-CredentialRecoveryActivationLifecycle {

    param(
        [Parameter(Mandatory)]
        [string]$ActivationId
    )

    $records = @(Get-CredentialRecoveryActivationAuditRecords)

    $events = @()

    foreach ($record in $records) {

        if ($record.ActivationId -eq $ActivationId) {
            $events += $record
        }
    }

    if ($events.Count -eq 0) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "ACTIVATION_NOT_FOUND"
        }
    }

    $sequence = @(
        "ACTIVATION_CREATED",
        "ACTIVATION_VALIDATED",
        "ACTIVATION_CONSUMED"
    )

    if ($events.Count -ne 3) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "INVALID_EVENT_COUNT"
        }
    }

    for ($i = 0; $i -lt 3; $i++) {

        if ($events[$i].EventType -ne $sequence[$i]) {

            return [pscustomobject]@{
                Allowed = $false
                Code = "INVALID_LIFECYCLE_SEQUENCE"
            }
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Code = "LIFECYCLE_VALID"
        Count = $events.Count
    }
}

function Reset-CredentialRecoveryActivationAudit {

    Save-CredentialRecoveryActivationAuditRecords
}
