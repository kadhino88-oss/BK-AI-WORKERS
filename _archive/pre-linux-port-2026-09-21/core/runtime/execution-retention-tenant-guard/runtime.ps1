function Get-RetentionTenantGuardConfig {
    $path = Join-Path $PSScriptRoot "config.json"

    return (
        Get-Content -Raw -Path $path |
        ConvertFrom-Json
    )
}

function Get-RetentionTenantGuardField {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $cfg = Get-RetentionTenantGuardConfig
    $prop = $cfg.PSObject.Properties[$Name]

    if ($null -eq $prop) {
        return $null
    }

    return $prop.Value
}

function Get-RetentionTenantGuardRecords {
    $path = Join-Path $PSScriptRoot "state\tenant-records.json"

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

function Save-RetentionTenantGuardRecords {
    param(
        [Parameter(Mandatory=$false)]
        $Records
    )

    $path = Join-Path $PSScriptRoot "state\tenant-records.json"

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

function Get-RetentionTenantGuardRecord {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RetentionId
    )

    if ([string]::IsNullOrWhiteSpace($RetentionId)) {
        return $null
    }

    $records = @(Get-RetentionTenantGuardRecords)

    foreach ($record in $records) {
        if ([string]$record.RetentionId -eq $RetentionId) {
            return $record
        }
    }

    return $null
}

function Test-RetentionTenantContext {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RetentionId,

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

    $cfg = Get-RetentionTenantGuardConfig

    if (-not $cfg.enabled -or -not $cfg.tenantIsolationEnabled) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "TENANT_ISOLATION_DISABLED"
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

    if ($cfg.requireTenantId) {
        if ([string]::IsNullOrWhiteSpace($TenantId)) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "TENANT_ID_REQUIRED"
            }
        }
    }

    if ($cfg.requireClientId) {
        if ([string]::IsNullOrWhiteSpace($ClientId)) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "CLIENT_ID_REQUIRED"
            }
        }
    }

    if ($cfg.requireProjectId) {
        if ([string]::IsNullOrWhiteSpace($ProjectId)) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "PROJECT_ID_REQUIRED"
            }
        }
    }

    return [pscustomobject]@{
        Success = $true
        Status  = "VALID"
        Reason  = "TENANT_CONTEXT_VALID"
    }
}

function Register-RetentionTenantRecord {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RetentionId,

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

    $check = Test-RetentionTenantContext `
        -RetentionId $RetentionId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    if (-not $check.Success) {
        return $check
    }

    $records = @(Get-RetentionTenantGuardRecords)

    foreach ($record in $records) {

        if ([string]$record.RetentionId -eq $RetentionId) {
            return [pscustomobject]@{
                Success = $false
                Status  = "DUPLICATE"
                Reason  = "RETENTION_ID_ALREADY_REGISTERED"
                RetentionId = $RetentionId
            }
        }
    }

    $cfg = Get-RetentionTenantGuardConfig

    if (@($records).Length -ge [int]$cfg.maxRecords) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "TENANT_RECORD_LIMIT_REACHED"
        }
    }

    $record = [pscustomobject]@{
        RetentionId = $RetentionId
        TenantId    = $TenantId
        ClientId    = $ClientId
        ProjectId   = $ProjectId
        Status      = "AUTHORIZED"
        CreatedAtUtc = [DateTime]::UtcNow.ToString("o")
    }

    $records += ,$record

    $null = Save-RetentionTenantGuardRecords $records

    return [pscustomobject]@{
        Success    = $true
        Status     = "REGISTERED"
        Reason     = "TENANT_RECORD_REGISTERED"
        RetentionId = $RetentionId
        TenantId   = $TenantId
        ClientId   = $ClientId
        ProjectId  = $ProjectId
    }
}

function Test-RetentionTenantAuthorization {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RetentionId,

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
        [string]$Operation = "READ"
    )

    $cfg = Get-RetentionTenantGuardConfig

    if (-not $cfg.enabled -or -not $cfg.authorizationGuardEnabled) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "AUTHORIZATION_GUARD_DISABLED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($RetentionId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RETENTION_ID_REQUIRED"
        }
    }

    $record = Get-RetentionTenantGuardRecord `
        -RetentionId $RetentionId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RETENTION_RECORD_NOT_FOUND"
        }
    }

    if ($cfg.preventCrossTenantAccess) {
        if ([string]$record.TenantId -ne [string]$TenantId) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "CROSS_TENANT_ACCESS_BLOCKED"
            }
        }
    }

    if ($cfg.preventCrossClientAccess) {
        if ([string]$record.ClientId -ne [string]$ClientId) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "CROSS_CLIENT_ACCESS_BLOCKED"
            }
        }
    }

    if ($cfg.preventCrossProjectAccess) {
        if ([string]$record.ProjectId -ne [string]$ProjectId) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "CROSS_PROJECT_ACCESS_BLOCKED"
            }
        }
    }

    if ([string]$Operation -ne "READ" -and
        [string]$Operation -ne "MUTATE") {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "OPERATION_INVALID"
        }
    }

    if ($Operation -eq "READ" -and
        $cfg.preventUnauthorizedRead -and
        $record.Status -ne "AUTHORIZED") {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "UNAUTHORIZED_READ_BLOCKED"
        }
    }

    if ($Operation -eq "MUTATE" -and
        $cfg.preventUnauthorizedMutation -and
        $record.Status -ne "AUTHORIZED") {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "UNAUTHORIZED_MUTATION_BLOCKED"
        }
    }

    return [pscustomobject]@{
        Success    = $true
        Status     = "AUTHORIZED"
        Reason     = "TENANT_ACCESS_AUTHORIZED"
        RetentionId = $RetentionId
    }
}

function Test-RetentionTenantIsolation {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RetentionId,

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

    $auth = Test-RetentionTenantAuthorization `
        -RetentionId $RetentionId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -Operation "READ"

    if (-not $auth.Success) {
        return $auth
    }

    return [pscustomobject]@{
        Success = $true
        Status  = "ISOLATED"
        Reason  = "RETENTION_TENANT_ISOLATION_VALID"
    }
}

function Reset-RetentionTenantGuard {
    $null = Save-RetentionTenantGuardRecords @()
    return $true
}