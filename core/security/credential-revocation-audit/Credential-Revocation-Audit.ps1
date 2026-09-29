function Get-CredentialRevocationAuditConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "REVOCATION_AUDIT_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "REVOCATION_AUDIT_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-CredentialRevocationAuditRecords {

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

function Save-CredentialRevocationAuditRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-CredentialRevocationAuditConfig

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "REVOCATION_AUDIT_RECORD_LIMIT"
    }

    $path = Join-Path $PSScriptRoot "state\records.json"

    if ($Records.Count -eq 0) {
        Set-Content -LiteralPath $path -Value "[]" -Encoding UTF8
        return
    }

    $json = ConvertTo-Json -InputObject @($Records) -Depth 30

    Set-Content `
        -LiteralPath $path `
        -Value $json `
        -Encoding UTF8
}

function Get-CredentialRevocationAuditRecord {

    param(
        [Parameter(Mandatory)]
        [string]$EventId
    )

    $records = @(Get-CredentialRevocationAuditRecords)

    foreach ($record in $records) {

        if ($record.EventId -eq $EventId) {
            return $record
        }
    }

    return $null
}

function Get-CredentialAuditHash {

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

function New-CredentialAuditEventId {

    return "AUDIT-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Get-CredentialAuditPreviousHash {

    $records = @(Get-CredentialRevocationAuditRecords)

    if ($records.Count -eq 0) {
        return "GENESIS"
    }

    $last = $records[$records.Count - 1]

    if ([string]::IsNullOrWhiteSpace($last.EventHash)) {
        throw "AUDIT_CHAIN_CORRUPTED"
    }

    return $last.EventHash
}

function Write-CredentialRevocationAuditEvent {

    param(
        [Parameter(Mandatory)]
        [string]$EventType,

        [Parameter(Mandatory)]
        [string]$CredentialRef,

        [Parameter(Mandatory)]
        [string]$LeaseId,

        [Parameter(Mandatory)]
        [string]$MaterializationId,

        [Parameter(Mandatory)]
        [string]$UsageId,

        [Parameter(Mandatory)]
        [string]$ExecutionId,

        [Parameter(Mandatory)]
        [string]$WorkerId,

        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [string]$Connector,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$ClientId,

        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$Decision,

        [Parameter(Mandatory)]
        [string]$Reason
    )

    $config = Get-CredentialRevocationAuditConfig

    if (-not $config.enabled) {
        throw "REVOCATION_AUDIT_DISABLED"
    }

    if (-not $config.auditEnabled) {
        throw "REVOCATION_AUDIT_DISABLED"
    }

    if ([string]::IsNullOrWhiteSpace($EventType)) {
        throw "EVENT_TYPE_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($CredentialRef)) {
        throw "CREDENTIAL_REF_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "EXECUTION_ID_REQUIRED"
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

    if ([string]::IsNullOrWhiteSpace($ProjectId)) {
        throw "PROJECT_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        throw "CLIENT_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw "TENANT_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Decision)) {
        throw "DECISION_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        throw "REASON_REQUIRED"
    }

    $now = (Get-Date).ToUniversalTime()

    $eventId = New-CredentialAuditEventId
    $previousHash = Get-CredentialAuditPreviousHash

    $credentialHash = Get-CredentialAuditHash -Value $CredentialRef

    $payload = (
        $eventId + "|" +
        $EventType + "|" +
        $credentialHash + "|" +
        $LeaseId + "|" +
        $MaterializationId + "|" +
        $UsageId + "|" +
        $ExecutionId + "|" +
        $WorkerId + "|" +
        $Action + "|" +
        $Connector + "|" +
        $ProjectId + "|" +
        $ClientId + "|" +
        $TenantId + "|" +
        $Decision + "|" +
        $Reason + "|" +
        $now.ToString("o") + "|" +
        $previousHash
    )

    $eventHash = Get-CredentialAuditHash -Value $payload

    $record = [pscustomobject][ordered]@{
        EventId             = $eventId
        EventType           = $EventType
        CredentialRefHash   = $credentialHash
        LeaseId             = $LeaseId
        MaterializationId   = $MaterializationId
        UsageId             = $UsageId
        ExecutionId         = $ExecutionId
        WorkerId            = $WorkerId
        Action              = $Action
        Connector           = $Connector
        ProjectId           = $ProjectId
        ClientId            = $ClientId
        TenantId            = $TenantId
        Decision            = $Decision
        Reason              = $Reason
        CreatedAtUtc        = $now.ToString("o")
        PreviousEventHash   = $previousHash
        EventHash           = $eventHash
        Immutable           = $true
        RawSecret           = $null
        RawCredential       = $null
    }

    $records = @(Get-CredentialRevocationAuditRecords)

    $records += $record

    Save-CredentialRevocationAuditRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        EventId = $eventId
        EventHash = $eventHash
        PreviousEventHash = $previousHash
    }
}

function Test-CredentialRevocationAuditIntegrity {

    param(
        [Parameter(Mandatory)]
        [string]$EventId
    )

    $record = Get-CredentialRevocationAuditRecord -EventId $EventId

    if ($null -eq $record) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_FOUND"
        }
    }

    if ($record.Immutable -ne $true) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_IMMUTABLE"
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

function Test-CredentialRevocationAuditChain {

    $records = @(Get-CredentialRevocationAuditRecords)

    if ($records.Count -eq 0) {

        return [pscustomobject]@{
            Allowed = $true
            Code = "EMPTY_CHAIN"
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

function Reset-CredentialRevocationAudit {

    Save-CredentialRevocationAuditRecords
}
