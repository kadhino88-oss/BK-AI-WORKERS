Set-StrictMode -Version 2.0

function Get-DeliveryRecoveryConfig {

    $ConfigFile = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file missing: $ConfigFile"
    }

    return Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
}

function Get-DeliveryRecoveryState {

    $StateFile = Join-Path $PSScriptRoot "state\recovery-records.json"

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

function Save-DeliveryRecoveryState {

    param(
        [Parameter(Mandatory=$true)]
        $Records
    )

    $StateFile = Join-Path $PSScriptRoot "state\recovery-records.json"
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

function Get-DeliveryRecoveryRecord {

    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$DeliveryId
    )

    if ([string]::IsNullOrWhiteSpace($DeliveryId)) {
        return $null
    }

    $Records = @(Get-DeliveryRecoveryState)

    $Record = @(
        $Records |
        Where-Object {
            [string]$_.DeliveryId -eq $DeliveryId
        }
    ) | Select-Object -First 1

    if ($null -eq $Record) {
        return $null
    }

    return $Record
}

function Initialize-DeliveryRecovery {

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
        [string]$ProjectId
    )

    if ([string]::IsNullOrWhiteSpace($DeliveryId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "DELIVERY_ID_MISSING"
        }
    }

    $Existing = Get-DeliveryRecoveryRecord -DeliveryId $DeliveryId

    if ($null -ne $Existing) {
        return [pscustomobject]@{
            Success = $true
            Status  = "EXISTS"
            Reason  = "RECOVERY_ALREADY_INITIALIZED"
        }
    }

    $Records = @(Get-DeliveryRecoveryState)

    $Record = [pscustomobject][ordered]@{
        RecoveryId      = [guid]::NewGuid().ToString("N")
        DeliveryId      = $DeliveryId
        ExecutionId     = $ExecutionId
        TenantId        = $TenantId
        ClientId        = $ClientId
        ProjectId       = $ProjectId
        RetryCount      = 0
        LastState       = "REGISTERED"
        RecoveryState   = "READY"
        UpdatedAtUtc    = [DateTime]::UtcNow.ToString("o")
    }

    $Records += ,$Record

    $null = Save-DeliveryRecoveryState -Records $Records

    return [pscustomobject]@{
        Success = $true
        Status  = "READY"
        Reason  = "RECOVERY_INITIALIZED"
    }
}

function Register-DeliveryFailure {

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
        [string]$ProjectId
    )

    $Record = Get-DeliveryRecoveryRecord -DeliveryId $DeliveryId

    if ($null -eq $Record) {
        $Init = Initialize-DeliveryRecovery `
            -DeliveryId $DeliveryId `
            -ExecutionId $ExecutionId `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -ProjectId $ProjectId

        if (-not $Init.Success) {
            return $Init
        }

        $Record = Get-DeliveryRecoveryRecord -DeliveryId $DeliveryId
    }

    if ([string]$Record.ExecutionId -ne $ExecutionId) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "EXECUTION_ID_MISMATCH"
        }
    }

    if ([string]$Record.TenantId -ne $TenantId) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "TENANT_MISMATCH"
        }
    }

    $Records = @(Get-DeliveryRecoveryState)

    foreach ($Item in $Records) {

        if ([string]$Item.DeliveryId -eq $DeliveryId) {

            $Item.LastState = "FAILED"
            $Item.RecoveryState = "FAILED"
            $Item.UpdatedAtUtc = [DateTime]::UtcNow.ToString("o")

            break
        }
    }

    $null = Save-DeliveryRecoveryState -Records $Records

    return [pscustomobject]@{
        Success = $true
        Status  = "FAILED"
        Reason  = "FAILURE_REGISTERED"
    }
}

function Request-DeliveryRetry {

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
        [string]$ProjectId
    )

    $Config = Get-DeliveryRecoveryConfig

    if ([string]::IsNullOrWhiteSpace($DeliveryId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "DELIVERY_ID_MISSING"
        }
    }

    $Record = Get-DeliveryRecoveryRecord -DeliveryId $DeliveryId

    if ($null -eq $Record) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RECOVERY_NOT_INITIALIZED"
        }
    }

    if ([string]$Record.ExecutionId -ne $ExecutionId) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "EXECUTION_ID_MISMATCH"
        }
    }

    if ([string]$Record.TenantId -ne $TenantId) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "TENANT_MISMATCH"
        }
    }

    if ([string]$Record.ClientId -ne $ClientId) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CLIENT_MISMATCH"
        }
    }

    if ([string]$Record.ProjectId -ne $ProjectId) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "PROJECT_MISMATCH"
        }
    }

    if ([bool]$Config.allowRetryFromFailedOnly) {

        if ([string]$Record.RecoveryState -ne "FAILED") {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "RETRY_REQUIRES_FAILED_STATE"
            }
        }
    }

    if ([int]$Record.RetryCount -ge [int]$Config.maxRetries) {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "MAX_RETRIES_REACHED"
        }
    }

    $Records = @(Get-DeliveryRecoveryState)

    foreach ($Item in $Records) {

        if ([string]$Item.DeliveryId -eq $DeliveryId) {

            $Item.RetryCount = [int]$Item.RetryCount + 1
            $Item.LastState = "FAILED"
            $Item.RecoveryState = "AUTHORIZED"
            $Item.UpdatedAtUtc = [DateTime]::UtcNow.ToString("o")

            break
        }
    }

    $null = Save-DeliveryRecoveryState -Records $Records

    return [pscustomobject]@{
        Success   = $true
        Status    = "AUTHORIZED"
        RetryCount = [int]$Record.RetryCount + 1
        Reason    = "RETRY_AUTHORIZED"
    }
}

function Reset-DeliveryRecovery {

    $null = Save-DeliveryRecoveryState -Records @()

    return
}