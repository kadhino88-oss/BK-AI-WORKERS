Set-StrictMode -Version 2.0

function Get-DeliveryRecoveryAuthorizationConfig {

    $ConfigFile = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file missing: $ConfigFile"
    }

    return Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
}

function Get-DeliveryRecoveryAuthorizationState {

    $StateFile = Join-Path $PSScriptRoot "state\authorization-records.json"

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

function Save-DeliveryRecoveryAuthorizationState {

    param(
        [Parameter(Mandatory=$true)]
        $Records
    )

    $StateFile = Join-Path $PSScriptRoot "state\authorization-records.json"
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

function New-RecoveryAuthorizationRecord {

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
        [int]$RetryCount
    )

    return [pscustomobject][ordered]@{
        AuthorizationId = [guid]::NewGuid().ToString("N")
        DeliveryId      = $DeliveryId
        ExecutionId     = $ExecutionId
        TenantId        = $TenantId
        ClientId        = $ClientId
        ProjectId       = $ProjectId
        LeaseId         = $LeaseId
        RetryCount      = $RetryCount
        Status          = "AUTHORIZED"
        AuthorizedAtUtc = [DateTime]::UtcNow.ToString("o")
    }
}

function Test-RecoveryAuthorization {

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
            Reason = "AUTHORIZATION_RECORD_NULL"
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

    if ([int]$Record.RetryCount -lt 1) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "RETRY_COUNT_INVALID"
        }
    }

    if ([string]$Record.Status -ne "AUTHORIZED") {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "AUTHORIZATION_STATUS_INVALID"
        }
    }

    return [pscustomobject]@{
        Valid  = $true
        Status = "VALID"
        Reason = "RECOVERY_AUTHORIZATION_VALID"
    }
}

function Authorize-DeliveryRecovery {

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
        [int]$RetryCount
    )

    $Config = Get-DeliveryRecoveryAuthorizationConfig

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

    if ($RetryCount -lt 1) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason = "RETRY_COUNT_INVALID"
        }
    }

    $Records = @(Get-DeliveryRecoveryAuthorizationState)

    foreach ($Record in $Records) {

        if (
            [string]$Record.DeliveryId -eq $DeliveryId -and
            [string]$Record.ExecutionId -eq $ExecutionId -and
            [string]$Record.LeaseId -eq $LeaseId
        ) {

            return [pscustomobject]@{
                Success = $true
                Status  = "DUPLICATE"
                AuthorizationId = [string]$Record.AuthorizationId
                Reason = "RECOVERY_AUTHORIZATION_ALREADY_EXISTS"
            }
        }
    }

    if ($Records.Count -ge [int]$Config.maxAuthorizations) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason = "MAX_AUTHORIZATIONS_REACHED"
        }
    }

    $Record = New-RecoveryAuthorizationRecord `
        -DeliveryId $DeliveryId `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -LeaseId $LeaseId `
        -RetryCount $RetryCount

    $Records += ,$Record

    $null = Save-DeliveryRecoveryAuthorizationState -Records $Records

    return [pscustomobject]@{
        Success         = $true
        Status          = "AUTHORIZED"
        AuthorizationId = $Record.AuthorizationId
        Reason          = "RECOVERY_AUTHORIZED"
    }
}

function Reset-DeliveryRecoveryAuthorization {

    $null = Save-DeliveryRecoveryAuthorizationState -Records @()

    return
}