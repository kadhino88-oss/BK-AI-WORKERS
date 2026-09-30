Set-StrictMode -Version 2.0

function Get-DeliveryExpirationConfig {

    $ConfigFile = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file missing: $ConfigFile"
    }

    return Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
}

function Get-DeliveryExpirationState {

    $StateFile = Join-Path $PSScriptRoot "state\expiration-records.json"

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

function Save-DeliveryExpirationState {

    param(
        [Parameter(Mandatory=$true)]
        $Records
    )

    $StateFile = Join-Path $PSScriptRoot "state\expiration-records.json"
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

function New-DeliveryExpirationRecord {

    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$LeaseId,

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

    return [pscustomobject][ordered]@{
        ExpirationId    = [guid]::NewGuid().ToString("N")
        LeaseId         = $LeaseId
        DeliveryId      = $DeliveryId
        ExecutionId     = $ExecutionId
        TenantId        = $TenantId
        ClientId        = $ClientId
        ProjectId       = $ProjectId
        Status          = "EXPIRED"
        ExpiredAtUtc    = [DateTime]::UtcNow.ToString("o")
        Reason          = "LEASE_TIMEOUT"
    }
}

function Register-DeliveryExpiration {

    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$LeaseId,

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
        [string]$ExpiresAtUtc
    )

    $Config = Get-DeliveryExpirationConfig

    if ([bool]$Config.requireLeaseId -and
        [string]::IsNullOrWhiteSpace($LeaseId)) {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "LEASE_ID_MISSING"
        }
    }

    if ([string]::IsNullOrWhiteSpace($DeliveryId)) {
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

    if ([string]::IsNullOrWhiteSpace($ExpiresAtUtc)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "EXPIRATION_MISSING"
        }
    }

    try {
        $Expiration = [DateTime]::Parse(
            $ExpiresAtUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "EXPIRATION_INVALID"
        }
    }

    if ([DateTime]::UtcNow -lt $Expiration) {
        return [pscustomobject]@{
            Success = $false
            Status  = "ACTIVE"
            Reason  = "LEASE_NOT_EXPIRED"
        }
    }

    $Records = @(Get-DeliveryExpirationState)

    foreach ($Record in $Records) {

        if ([string]$Record.LeaseId -eq $LeaseId) {

            return [pscustomobject]@{
                Success = $true
                Status  = "DUPLICATE"
                ExpirationId = [string]$Record.ExpirationId
                Reason  = "EXPIRATION_ALREADY_REGISTERED"
            }
        }
    }

    $ExpirationRecord = New-DeliveryExpirationRecord `
        -LeaseId $LeaseId `
        -DeliveryId $DeliveryId `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    $Records += ,$ExpirationRecord

    $null = Save-DeliveryExpirationState -Records $Records

    return [pscustomobject]@{
        Success      = $true
        Status       = "EXPIRED"
        ExpirationId = $ExpirationRecord.ExpirationId
        Reason       = "LEASE_EXPIRED"
    }
}

function Test-DeliveryExpiration {

    param(
        [Parameter()]
        $Record,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$LeaseId,

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

    if ($null -eq $Record) {
        return [pscustomobject]@{
            Valid  = $false
            Reason = "EXPIRATION_RECORD_NULL"
        }
    }

    if ([string]$Record.LeaseId -ne $LeaseId) {
        return [pscustomobject]@{
            Valid  = $false
            Reason = "LEASE_ID_MISMATCH"
        }
    }

    if ([string]$Record.ExecutionId -ne $ExecutionId) {
        return [pscustomobject]@{
            Valid  = $false
            Reason = "EXECUTION_ID_MISMATCH"
        }
    }

    if ([string]$Record.TenantId -ne $TenantId) {
        return [pscustomobject]@{
            Valid  = $false
            Reason = "TENANT_MISMATCH"
        }
    }

    if ([string]$Record.ClientId -ne $ClientId) {
        return [pscustomobject]@{
            Valid  = $false
            Reason = "CLIENT_MISMATCH"
        }
    }

    if ([string]$Record.ProjectId -ne $ProjectId) {
        return [pscustomobject]@{
            Valid  = $false
            Reason = "PROJECT_MISMATCH"
        }
    }

    if ([string]$Record.Status -ne "EXPIRED") {
        return [pscustomobject]@{
            Valid  = $false
            Reason = "EXPIRATION_STATUS_INVALID"
        }
    }

    return [pscustomobject]@{
        Valid  = $true
        Reason = "EXPIRATION_VALID"
    }
}

function Reset-DeliveryExpiration {

    $null = Save-DeliveryExpirationState -Records @()

    return
}