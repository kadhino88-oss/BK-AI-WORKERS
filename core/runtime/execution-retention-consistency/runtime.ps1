function Get-RetentionConsistencyConfig {
    $path = Join-Path $PSScriptRoot "config.json"

    return (
        Get-Content -Raw -Path $path |
        ConvertFrom-Json
    )
}

function Get-RetentionConsistencyField {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $cfg = Get-RetentionConsistencyConfig
    $prop = $cfg.PSObject.Properties[$Name]

    if ($null -eq $prop) {
        return $null
    }

    return $prop.Value
}

function Get-RetentionConsistencyRecords {
    $path = Join-Path $PSScriptRoot "state\consistency-records.json"

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

function Save-RetentionConsistencyRecords {
    param(
        [Parameter(Mandatory=$false)]
        $Records
    )

    $path = Join-Path $PSScriptRoot "state\consistency-records.json"

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

function Get-RetentionConsistencyRecord {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ConsistencyId
    )

    if ([string]::IsNullOrWhiteSpace($ConsistencyId)) {
        return $null
    }

    $records = @(Get-RetentionConsistencyRecords)

    foreach ($record in $records) {
        if ([string]$record.ConsistencyId -eq $ConsistencyId) {
            return $record
        }
    }

    return $null
}

function Test-RetentionConsistencyContext {
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
        [string]$LifecycleState
    )

    $cfg = Get-RetentionConsistencyConfig

    if (-not $cfg.enabled -or -not $cfg.consistencyGuardEnabled) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CONSISTENCY_GUARD_DISABLED"
        }
    }

    if ($cfg.requireRetentionId) {
        if ([string]::IsNullOrWhiteSpace($RetentionId)) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "RETENTION_ID_REQUIRED"
            }
        }
    }

    if ($cfg.requireEventId) {
        if ([string]::IsNullOrWhiteSpace($EventId)) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "EVENT_ID_REQUIRED"
            }
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

    if ($cfg.requireLifecycleState) {

        if ([string]::IsNullOrWhiteSpace($LifecycleState)) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "LIFECYCLE_STATE_REQUIRED"
            }
        }

        $allowedStates = @($cfg.allowedStates)
        $stateFound = $false

        foreach ($allowed in $allowedStates) {
            if ([string]$allowed -eq $LifecycleState) {
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
    }

    return [pscustomobject]@{
        Success = $true
        Status  = "VALID"
        Reason  = "RETENTION_CONSISTENCY_CONTEXT_VALID"
    }
}

function Register-RetentionConsistency {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ConsistencyId,

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
        [string]$LifecycleState
    )

    $check = Test-RetentionConsistencyContext `
        -RetentionId $RetentionId `
        -EventId $EventId `
        -CorrelationId $CorrelationId `
        -DeliveryId $DeliveryId `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -LifecycleState $LifecycleState

    if (-not $check.Success) {
        return $check
    }

    if ([string]::IsNullOrWhiteSpace($ConsistencyId)) {
        $ConsistencyId = [guid]::NewGuid().ToString()
    }

    $records = @(Get-RetentionConsistencyRecords)

    foreach ($existing in $records) {

        if ([string]$existing.ConsistencyId -eq $ConsistencyId) {
            return [pscustomobject]@{
                Success       = $false
                Status        = "DUPLICATE"
                Reason        = "CONSISTENCY_ID_ALREADY_EXISTS"
                ConsistencyId = $ConsistencyId
            }
        }

        if ([string]$existing.RetentionId -eq $RetentionId) {
            return [pscustomobject]@{
                Success       = $false
                Status        = "DUPLICATE"
                Reason        = "RETENTION_CONSISTENCY_ALREADY_REGISTERED"
                RetentionId   = $RetentionId
            }
        }
    }

    $cfg = Get-RetentionConsistencyConfig

    if (@($records).Length -ge [int]$cfg.maxRecords) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CONSISTENCY_RECORD_LIMIT_REACHED"
        }
    }

    $record = [pscustomobject]@{
        ConsistencyId  = $ConsistencyId
        RetentionId    = $RetentionId
        EventId        = $EventId
        CorrelationId  = $CorrelationId
        DeliveryId     = $DeliveryId
        ExecutionId    = $ExecutionId
        TenantId       = $TenantId
        ClientId       = $ClientId
        ProjectId      = $ProjectId
        LifecycleState = $LifecycleState
        Status         = "CONSISTENT"
        CreatedAtUtc   = [DateTime]::UtcNow.ToString("o")
    }

    $records += ,$record

    $null = Save-RetentionConsistencyRecords $records

    return [pscustomobject]@{
        Success       = $true
        Status        = "REGISTERED"
        Reason        = "RETENTION_CONSISTENCY_REGISTERED"
        ConsistencyId = $ConsistencyId
        RetentionId   = $RetentionId
        EventId       = $EventId
        CorrelationId = $CorrelationId
    }
}

function Test-RetentionConsistencyLink {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ConsistencyId,

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

    if ([string]::IsNullOrWhiteSpace($ConsistencyId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CONSISTENCY_ID_REQUIRED"
        }
    }

    $record = Get-RetentionConsistencyRecord `
        -ConsistencyId $ConsistencyId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CONSISTENCY_RECORD_NOT_FOUND"
        }
    }

    $pairs = @(
        @{ Name = "RetentionId"; Stored = $record.RetentionId; Input = $RetentionId },
        @{ Name = "EventId"; Stored = $record.EventId; Input = $EventId },
        @{ Name = "CorrelationId"; Stored = $record.CorrelationId; Input = $CorrelationId },
        @{ Name = "DeliveryId"; Stored = $record.DeliveryId; Input = $DeliveryId },
        @{ Name = "ExecutionId"; Stored = $record.ExecutionId; Input = $ExecutionId },
        @{ Name = "TenantId"; Stored = $record.TenantId; Input = $TenantId },
        @{ Name = "ClientId"; Stored = $record.ClientId; Input = $ClientId },
        @{ Name = "ProjectId"; Stored = $record.ProjectId; Input = $ProjectId }
    )

    foreach ($pair in $pairs) {

        if ([string]$pair.Stored -ne [string]$pair.Input) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "AUDIT_LINK_MISMATCH"
                Field   = $pair.Name
            }
        }
    }

    if ([string]$record.Status -ne "CONSISTENT") {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CONSISTENCY_STATUS_INVALID"
        }
    }

    return [pscustomobject]@{
        Success       = $true
        Status        = "VALID"
        Reason        = "AUDIT_LINK_CONSISTENT"
        ConsistencyId = $ConsistencyId
    }
}

function Reset-RetentionConsistency {
    $null = Save-RetentionConsistencyRecords @()
    return $true
}