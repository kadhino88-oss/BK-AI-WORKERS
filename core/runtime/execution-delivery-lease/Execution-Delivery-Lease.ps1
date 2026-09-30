Set-StrictMode -Version 2.0

function Get-DeliveryLeaseConfig {

    $ConfigFile = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file missing: $ConfigFile"
    }

    return Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
}

function Get-DeliveryLeaseState {

    $StateFile = Join-Path $PSScriptRoot "state\lease-records.json"

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

function Save-DeliveryLeaseState {

    param(
        [Parameter(Mandatory=$true)]
        $Records
    )

    $StateFile = Join-Path $PSScriptRoot "state\lease-records.json"
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

function Get-DeliveryLease {

    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$LeaseId
    )

    if ([string]::IsNullOrWhiteSpace($LeaseId)) {
        return $null
    }

    $Records = @(Get-DeliveryLeaseState)

    $Record = @(
        $Records |
        Where-Object {
            [string]$_.LeaseId -eq $LeaseId
        }
    ) | Select-Object -First 1

    if ($null -eq $Record) {
        return $null
    }

    return $Record
}

function Acquire-DeliveryLease {

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

    $Config = Get-DeliveryLeaseConfig

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

    $Records = @(Get-DeliveryLeaseState)

    foreach ($Record in $Records) {

        if ([string]$Record.DeliveryId -eq $DeliveryId -and
            [string]$Record.Status -eq "ACTIVE") {

            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "ACTIVE_LEASE_EXISTS"
            }
        }
    }

    $Now = [DateTime]::UtcNow
    $Expires = $Now.AddSeconds([int]$Config.leaseDurationSeconds)

    $Lease = [pscustomobject][ordered]@{
        LeaseId         = [guid]::NewGuid().ToString("N")
        DeliveryId      = $DeliveryId
        ExecutionId     = $ExecutionId
        TenantId        = $TenantId
        ClientId        = $ClientId
        ProjectId       = $ProjectId
        Status          = "ACTIVE"
        AcquiredAtUtc   = $Now.ToString("o")
        ExpiresAtUtc    = $Expires.ToString("o")
        RenewalCount    = 0
        LastRenewedUtc  = ""
    }

    $Records += ,$Lease

    $null = Save-DeliveryLeaseState -Records $Records

    return [pscustomobject]@{
        Success     = $true
        Status      = "ACTIVE"
        LeaseId     = $Lease.LeaseId
        DeliveryId  = $DeliveryId
        ExecutionId = $ExecutionId
        ExpiresAtUtc = $Lease.ExpiresAtUtc
        Reason      = "LEASE_ACQUIRED"
    }
}

function Test-DeliveryLease {

    param(
        [Parameter()]
        $Lease,

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

    if ($null -eq $Lease) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "LEASE_NULL"
        }
    }

    if ([string]$Lease.Status -ne "ACTIVE") {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "LEASE_NOT_ACTIVE"
        }
    }

    if ([string]$Lease.DeliveryId -ne $DeliveryId) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "DELIVERY_ID_MISMATCH"
        }
    }

    if ([string]$Lease.ExecutionId -ne $ExecutionId) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "EXECUTION_ID_MISMATCH"
        }
    }

    if ([string]$Lease.TenantId -ne $TenantId) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "TENANT_MISMATCH"
        }
    }

    if ([string]$Lease.ClientId -ne $ClientId) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "CLIENT_MISMATCH"
        }
    }

    if ([string]$Lease.ProjectId -ne $ProjectId) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "PROJECT_MISMATCH"
        }
    }

    $Expires = [DateTime]::Parse(
        [string]$Lease.ExpiresAtUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )

    if ([DateTime]::UtcNow -ge $Expires) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "EXPIRED"
            Reason = "LEASE_EXPIRED"
        }
    }

    return [pscustomobject]@{
        Valid  = $true
        Status = "ACTIVE"
        Reason = "LEASE_VALID"
    }
}

function Renew-DeliveryLease {

    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$LeaseId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ExecutionId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$TenantId
    )

    $Config = Get-DeliveryLeaseConfig
    $Lease = Get-DeliveryLease -LeaseId $LeaseId

    if ($null -eq $Lease) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "LEASE_NOT_FOUND"
        }
    }

    if ([string]$Lease.ExecutionId -ne $ExecutionId) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "EXECUTION_ID_MISMATCH"
        }
    }

    if ([string]$Lease.TenantId -ne $TenantId) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "TENANT_MISMATCH"
        }
    }

    if ([string]$Lease.Status -ne "ACTIVE") {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "LEASE_NOT_ACTIVE"
        }
    }

    if ([int]$Lease.RenewalCount -ge [int]$Config.maxRenewals) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason = "MAX_RENEWALS_REACHED"
        }
    }

    $Expires = [DateTime]::Parse(
        [string]$Lease.ExpiresAtUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )

    if ([DateTime]::UtcNow -ge $Expires) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "LEASE_EXPIRED"
        }
    }

    $Records = @(Get-DeliveryLeaseState)

    $NewExpiry = [DateTime]::UtcNow.AddSeconds(
        [int]$Config.leaseDurationSeconds
    )

    foreach ($Record in $Records) {

        if ([string]$Record.LeaseId -eq $LeaseId) {

            $Record.RenewalCount = [int]$Record.RenewalCount + 1
            $Record.LastRenewedUtc = [DateTime]::UtcNow.ToString("o")
            $Record.ExpiresAtUtc = $NewExpiry.ToString("o")

            break
        }
    }

    $null = Save-DeliveryLeaseState -Records $Records

    return [pscustomobject]@{
        Success      = $true
        Status       = "ACTIVE"
        LeaseId      = $LeaseId
        RenewalCount = [int]$Lease.RenewalCount + 1
        ExpiresAtUtc = $NewExpiry.ToString("o")
        Reason       = "LEASE_RENEWED"
    }
}

function Release-DeliveryLease {

    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$LeaseId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ExecutionId
    )

    $Lease = Get-DeliveryLease -LeaseId $LeaseId

    if ($null -eq $Lease) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "LEASE_NOT_FOUND"
        }
    }

    if ([string]$Lease.ExecutionId -ne $ExecutionId) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "EXECUTION_ID_MISMATCH"
        }
    }

    if ([string]$Lease.Status -ne "ACTIVE") {
        return [pscustomobject]@{
            Success = $true
            Status  = "ALREADY_RELEASED"
            Reason  = "LEASE_ALREADY_RELEASED"
        }
    }

    $Records = @(Get-DeliveryLeaseState)

    foreach ($Record in $Records) {

        if ([string]$Record.LeaseId -eq $LeaseId) {
            $Record.Status = "RELEASED"
            break
        }
    }

    $null = Save-DeliveryLeaseState -Records $Records

    return [pscustomobject]@{
        Success = $true
        Status  = "RELEASED"
        Reason  = "LEASE_RELEASED"
    }
}

function Reset-DeliveryLeases {

    $null = Save-DeliveryLeaseState -Records @()

    return
}