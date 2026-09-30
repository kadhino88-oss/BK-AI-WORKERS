function Get-RecoveryAuditRetentionConfig {
    $path = Join-Path $PSScriptRoot "config.json"

    return (
        Get-Content -Raw -Path $path |
        ConvertFrom-Json
    )
}

function Get-RecoveryAuditRetentionField {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $cfg = Get-RecoveryAuditRetentionConfig
    $prop = $cfg.PSObject.Properties[$Name]

    if ($null -eq $prop) {
        return $null
    }

    return $prop.Value
}

function Get-RecoveryAuditRetentionRecords {
    $path = Join-Path $PSScriptRoot "state\retention-records.json"

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

function Save-RecoveryAuditRetentionRecords {
    param(
        [Parameter(Mandatory=$false)]
        $Records
    )

    $path = Join-Path $PSScriptRoot "state\retention-records.json"

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

function Get-RecoveryAuditRetentionRecord {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RetentionId
    )

    if ([string]::IsNullOrWhiteSpace($RetentionId)) {
        return $null
    }

    $records = @(Get-RecoveryAuditRetentionRecords)

    foreach ($record in $records) {
        if ([string]$record.RetentionId -eq $RetentionId) {
            return $record
        }
    }

    return $null
}

function Test-RecoveryAuditRetentionContext {
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
        [string]$RetentionStatus
    )

    $cfg = Get-RecoveryAuditRetentionConfig

    if (-not $cfg.enabled -or -not $cfg.retentionGuardEnabled) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RETENTION_GUARD_DISABLED"
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

    if ([string]::IsNullOrWhiteSpace($RetentionStatus)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RETENTION_STATUS_REQUIRED"
        }
    }

    $allowed = @(
        "ACTIVE",
        "RETAINED",
        "EXPIRED"
    )

    $statusFound = $false

    foreach ($value in $allowed) {
        if ($value -eq $RetentionStatus) {
            $statusFound = $true
            break
        }
    }

    if (-not $statusFound) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RETENTION_STATUS_INVALID"
        }
    }

    return [pscustomobject]@{
        Success = $true
        Status  = "VALID"
        Reason  = "RETENTION_CONTEXT_VALID"
    }
}

function Register-RecoveryAuditRetention {
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
        [string]$RetentionStatus = "ACTIVE"
    )

    $check = Test-RecoveryAuditRetentionContext `
        -RetentionId $RetentionId `
        -EventId $EventId `
        -CorrelationId $CorrelationId `
        -DeliveryId $DeliveryId `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -RetentionStatus $RetentionStatus

    if (-not $check.Success) {
        return $check
    }

    $records = @(Get-RecoveryAuditRetentionRecords)

    foreach ($record in $records) {

        if ([string]$record.RetentionId -eq $RetentionId) {
            return [pscustomobject]@{
                Success     = $false
                Status      = "DUPLICATE"
                Reason      = "RETENTION_RECORD_ALREADY_EXISTS"
                RetentionId = $RetentionId
            }
        }
    }

    $cfg = Get-RecoveryAuditRetentionConfig
    $recordCount = @($records).Length

    if ($recordCount -ge [int]$cfg.maxRecords) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RETENTION_LIMIT_REACHED"
        }
    }

    $registeredAt = [DateTime]::UtcNow
    $expiresAt = $registeredAt.AddDays(
        [double]$cfg.retentionDays
    )

    $record = [pscustomobject]@{
        RetentionId   = $RetentionId
        EventId       = $EventId
        CorrelationId = $CorrelationId
        DeliveryId    = $DeliveryId
        ExecutionId   = $ExecutionId
        TenantId      = $TenantId
        ClientId      = $ClientId
        ProjectId     = $ProjectId
        RetentionStatus = $RetentionStatus
        Immutable     = [bool]$cfg.immutabilityEnabled
        ExpiresAtUtc  = $expiresAt.ToString("o")
        RegisteredAtUtc = $registeredAt.ToString("o")
    }

    $records += ,$record

    $null = Save-RecoveryAuditRetentionRecords $records

    return [pscustomobject]@{
        Success       = $true
        Status        = "REGISTERED"
        Reason        = "RETENTION_REGISTERED"
        RetentionId   = $RetentionId
        EventId       = $EventId
        CorrelationId = $CorrelationId
        ExpiresAtUtc  = $expiresAt.ToString("o")
        Immutable     = [bool]$cfg.immutabilityEnabled
    }
}

function Test-RecoveryAuditRetention {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RetentionId,

        [Parameter(Mandatory=$false)]
        [datetime]$ReferenceTime = [DateTime]::UtcNow
    )

    if ([string]::IsNullOrWhiteSpace($RetentionId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RETENTION_ID_REQUIRED"
        }
    }

    $record = Get-RecoveryAuditRetentionRecord `
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

    if ($ReferenceTime -ge $expires) {
        return [pscustomobject]@{
            Success = $true
            Status  = "EXPIRED"
            Reason  = "RETENTION_EXPIRED"
            RetentionId = $RetentionId
        }
    }

    return [pscustomobject]@{
        Success = $true
        Status  = "RETAINED"
        Reason  = "RETENTION_ACTIVE"
        RetentionId = $RetentionId
        ExpiresAtUtc = $expires.ToString("o")
    }
}

function Test-RecoveryAuditMutation {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RetentionId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RequestedStatus
    )

    $cfg = Get-RecoveryAuditRetentionConfig

    if (-not $cfg.mutationProtectionEnabled) {
        return [pscustomobject]@{
            Success = $true
            Status  = "ALLOWED"
            Reason  = "MUTATION_PROTECTION_DISABLED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($RetentionId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RETENTION_ID_REQUIRED"
        }
    }

    $record = Get-RecoveryAuditRetentionRecord `
        -RetentionId $RetentionId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RETENTION_RECORD_NOT_FOUND"
        }
    }

    if ($record.Immutable -eq $true -and
        $RequestedStatus -ne $record.RetentionStatus) {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "IMMUTABLE_RECORD_MUTATION_BLOCKED"
        }
    }

    return [pscustomobject]@{
        Success = $true
        Status  = "UNCHANGED"
        Reason  = "IMMUTABLE_RECORD_UNCHANGED"
    }
}

function Test-RecoveryAuditDeletion {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RetentionId,

        [Parameter(Mandatory=$false)]
        [bool]$Expired = $false
    )

    $cfg = Get-RecoveryAuditRetentionConfig

    if ([string]::IsNullOrWhiteSpace($RetentionId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RETENTION_ID_REQUIRED"
        }
    }

    $record = Get-RecoveryAuditRetentionRecord `
        -RetentionId $RetentionId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RETENTION_RECORD_NOT_FOUND"
        }
    }

    if (-not $cfg.allowManualDelete) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "MANUAL_DELETE_DISABLED"
        }
    }

    if ($record.Immutable -eq $true) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "IMMUTABLE_RECORD_DELETE_BLOCKED"
        }
    }

    if ($Expired -and -not $cfg.allowExpiredPurge) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "EXPIRED_PURGE_DISABLED"
        }
    }

    return [pscustomobject]@{
        Success = $true
        Status  = "AUTHORIZED"
        Reason  = "DELETE_ALLOWED_BY_POLICY"
    }
}

function Reset-RecoveryAuditRetention {
    $null = Save-RecoveryAuditRetentionRecords @()
    return $true
}