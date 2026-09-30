Set-StrictMode -Version 2.0

function Get-DeliveryRecoveryConsistencyConfig {

    $ConfigFile = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file missing: $ConfigFile"
    }

    return Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
}

function Get-DeliveryRecoveryConsistencyState {

    $StateFile = Join-Path $PSScriptRoot "state\consistency-records.json"

    if (-not (Test-Path $StateFile)) {
        return @()
    }

    $Raw = Get-Content -Raw -Path $StateFile

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return @()
    }

    $Parsed = ConvertFrom-Json $Raw

    if ($null -eq $Parsed) {
        return @()
    }

    return @($Parsed)
}

function Save-DeliveryRecoveryConsistencyState {

    param(
        [Parameter(Mandatory=$true)]
        $Records
    )

    $StateFile = Join-Path $PSScriptRoot "state\consistency-records.json"
    $Array = @($Records)

    if ($Array.Count -eq 0) {

        [System.IO.File]::WriteAllText(
            $StateFile,
            "[]",
            [System.Text.UTF8Encoding]::new($false)
        )

        return
    }

    $Json = ConvertTo-Json -InputObject $Array -Depth 20

    [System.IO.File]::WriteAllText(
        $StateFile,
        $Json,
        [System.Text.UTF8Encoding]::new($false)
    )

    return
}

function New-RecoveryConsistencyRecord {

    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$DeliveryId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ExecutionId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$TenantId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ClientId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ProjectId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$LeaseId,

        [Parameter(Mandatory=$true)]
        [int]$RetryCount,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$RecoveryState
    )

    return [pscustomobject][ordered]@{
        ConsistencyId = [guid]::NewGuid().ToString("N")
        DeliveryId    = $DeliveryId
        ExecutionId   = $ExecutionId
        TenantId      = $TenantId
        ClientId      = $ClientId
        ProjectId     = $ProjectId
        LeaseId       = $LeaseId
        RetryCount    = $RetryCount
        RecoveryState = $RecoveryState
        RecordedAtUtc = [DateTime]::UtcNow.ToString("o")
    }
}

function Test-RecoveryConsistency {

    param(
        [Parameter()]
        $Record,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$DeliveryId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ExecutionId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$TenantId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ClientId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ProjectId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$LeaseId
    )

    if ($null -eq $Record) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "RECORD_NULL"
        }
    }

    if ([string]::IsNullOrWhiteSpace($DeliveryId)) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "DELIVERY_ID_MISSING"
        }
    }

    if ([string]$Record.DeliveryId -ne $DeliveryId) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "DELIVERY_ID_MISMATCH"
        }
    }

    if ([string]$Record.ExecutionId -ne $ExecutionId) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "EXECUTION_ID_MISMATCH"
        }
    }

    if ([string]$Record.TenantId -ne $TenantId) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "TENANT_MISMATCH"
        }
    }

    if ([string]$Record.ClientId -ne $ClientId) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "CLIENT_MISMATCH"
        }
    }

    if ([string]$Record.ProjectId -ne $ProjectId) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "PROJECT_MISMATCH"
        }
    }

    if ([string]$Record.LeaseId -ne $LeaseId) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "LEASE_MISMATCH"
        }
    }

    if ([int]$Record.RetryCount -lt 0) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "RETRY_COUNT_INVALID"
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$Record.RecoveryState)) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "RECOVERY_STATE_MISSING"
        }
    }

    return [pscustomobject]@{
        Valid  = $true
        Status = "VALID"
        Reason = "RECOVERY_CONTEXT_CONSISTENT"
    }
}

function Register-RecoveryConsistency {

    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$DeliveryId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ExecutionId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$TenantId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ClientId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ProjectId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$LeaseId,

        [Parameter(Mandatory=$true)]
        [int]$RetryCount,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$RecoveryState
    )

    $Config = Get-DeliveryRecoveryConsistencyConfig

    if ([bool]$Config.requireDeliveryId -and
        [string]::IsNullOrWhiteSpace($DeliveryId)) {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "DELIVERY_ID_MISSING"
        }
    }

    if ([bool]$Config.requireExecutionId -and
        [string]::IsNullOrWhiteSpace($ExecutionId)) {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "EXECUTION_ID_MISSING"
        }
    }

    if ([bool]$Config.requireTenantId -and
        [string]::IsNullOrWhiteSpace($TenantId)) {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "TENANT_ID_MISSING"
        }
    }

    if ([bool]$Config.requireClientId -and
        [string]::IsNullOrWhiteSpace($ClientId)) {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CLIENT_ID_MISSING"
        }
    }

    if ([bool]$Config.requireProjectId -and
        [string]::IsNullOrWhiteSpace($ProjectId)) {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "PROJECT_ID_MISSING"
        }
    }

    if ([bool]$Config.requireLeaseId -and
        [string]::IsNullOrWhiteSpace($LeaseId)) {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "LEASE_ID_MISSING"
        }
    }

    if ($RetryCount -lt 0) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RETRY_COUNT_INVALID"
        }
    }

    if ([string]::IsNullOrWhiteSpace($RecoveryState)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RECOVERY_STATE_MISSING"
        }
    }

    $Records = @(Get-DeliveryRecoveryConsistencyState)

    if ($Records.Count -ge [int]$Config.maxRecoveryRecords) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "MAX_RECORDS_REACHED"
        }
    }

    $Record = New-RecoveryConsistencyRecord `
        -DeliveryId $DeliveryId `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -LeaseId $LeaseId `
        -RetryCount $RetryCount `
        -RecoveryState $RecoveryState

    $Records += ,$Record

    $null = Save-DeliveryRecoveryConsistencyState -Records $Records

    return [pscustomobject]@{
        Success       = $true
        Status        = "RECORDED"
        ConsistencyId = $Record.ConsistencyId
        Reason        = "RECOVERY_CONTEXT_RECORDED"
    }
}

function Reset-RecoveryConsistency {

    $null = Save-DeliveryRecoveryConsistencyState -Records @()

    return
}