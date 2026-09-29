function Get-CredentialUsageGuardConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "CREDENTIAL_USAGE_GUARD_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "CREDENTIAL_USAGE_GUARD_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-CredentialUsageGuardRecords {

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

function Save-CredentialUsageGuardRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-CredentialUsageGuardConfig

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "CREDENTIAL_USAGE_GUARD_RECORD_LIMIT"
    }

    $path = Join-Path $PSScriptRoot "state\records.json"

    if ($Records.Count -eq 0) {
        Set-Content -LiteralPath $path -Value "[]" -Encoding UTF8
        return
    }

    $json = ConvertTo-Json -InputObject @($Records) -Depth 20

    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
}

function Get-CredentialUsageGuardRecord {

    param(
        [Parameter(Mandatory)]
        [string]$UsageId
    )

    $records = @(Get-CredentialUsageGuardRecords)

    foreach ($record in $records) {

        if ($record.UsageId -eq $UsageId) {
            return $record
        }
    }

    return $null
}

function Get-CredentialUsageGuardHash {

    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $hash = $sha.ComputeHash($bytes)

        return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function New-CredentialUsageId {

    return "USE-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Ensure-CredentialMaterializationValidator {

    if (Get-Command Test-CredentialMaterialization -ErrorAction SilentlyContinue) {
        return
    }

    $materializationRuntime = Join-Path `
        (Split-Path $PSScriptRoot -Parent) `
        "credential-materialization\Credential-Materialization.ps1"

    if (-not (Test-Path -LiteralPath $materializationRuntime)) {
        throw "CREDENTIAL_MATERIALIZATION_RUNTIME_MISSING"
    }

    . $materializationRuntime

    if (-not (Get-Command Test-CredentialMaterialization -ErrorAction SilentlyContinue)) {
        throw "CREDENTIAL_MATERIALIZATION_VALIDATOR_MISSING"
    }
}

function Invoke-CredentialUsageGuard {

    param(
        [Parameter(Mandatory)]
        [string]$MaterializationId,

        [Parameter(Mandatory)]
        [string]$LeaseId,

        [Parameter(Mandatory)]
        [string]$CredentialRef,

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
        [string]$TenantId
    )

    $config = Get-CredentialUsageGuardConfig

    if (-not $config.enabled) {
        throw "CREDENTIAL_USAGE_GUARD_DISABLED"
    }

    if (-not $config.usageGuardEnabled) {
        throw "CREDENTIAL_USAGE_GUARD_DISABLED"
    }

    if ([string]::IsNullOrWhiteSpace($MaterializationId)) {
        throw "MATERIALIZATION_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($LeaseId)) {
        throw "LEASE_ID_REQUIRED"
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

    Ensure-CredentialMaterializationValidator

    $validator = Get-Command `
        Test-CredentialMaterialization `
        -ErrorAction Stop

    $materializationResult = & $validator `
        -MaterializationId $MaterializationId `
        -LeaseId $LeaseId `
        -CredentialRef $CredentialRef `
        -ExecutionId $ExecutionId `
        -WorkerId $WorkerId `
        -Action $Action `
        -Connector $Connector `
        -ProjectId $ProjectId `
        -ClientId $ClientId `
        -TenantId $TenantId

    if ($null -eq $materializationResult) {
        throw "MATERIALIZATION_VALIDATION_EMPTY"
    }

    if ($materializationResult.Allowed -ne $true) {
        throw "MATERIALIZATION_REVALIDATION_FAILED"
    }

    $now = (Get-Date).ToUniversalTime()
    $expires = $now.AddSeconds([int]$config.usageWindowSeconds)

    $usageId = New-CredentialUsageId

    $usageHash = Get-CredentialUsageGuardHash `
        -Value $usageId

    $records = @(Get-CredentialUsageGuardRecords)

    $existing = $null

    foreach ($item in $records) {

        if (
            $item.MaterializationId -eq $MaterializationId -and
            $item.Status -eq "AUTHORIZED"
        ) {
            $existing = $item
            break
        }
    }

    if ($null -ne $existing) {
        throw "ACTIVE_USAGE_ALREADY_EXISTS"
    }

    $record = [pscustomobject][ordered]@{
        UsageId             = $usageId
        UsageHash           = $usageHash
        MaterializationId   = $MaterializationId
        LeaseId             = $LeaseId
        ExecutionId         = $ExecutionId
        WorkerId            = $WorkerId
        Action              = $Action
        Connector           = $Connector
        ProjectId           = $ProjectId
        ClientId            = $ClientId
        TenantId            = $TenantId
        CreatedAtUtc        = $now.ToString("o")
        ExpiresAtUtc        = $expires.ToString("o")
        ConsumedAtUtc       = $null
        RevokedAtUtc        = $null
        Status              = "AUTHORIZED"
        Used                = $false
        Decision            = "ALLOW"
        RawSecret           = $null
        RawCredential       = $null
    }

    $records += $record

    Save-CredentialUsageGuardRecords -Records $records

    return [pscustomobject][ordered]@{
        Allowed             = $true
        UsageId             = $usageId
        UsageHash           = $usageHash
        MaterializationId   = $MaterializationId
        ExecutionId         = $ExecutionId
        WorkerId            = $WorkerId
        Action              = $Action
        Connector           = $Connector
        ProjectId           = $ProjectId
        ClientId            = $ClientId
        TenantId            = $TenantId
        ExpiresAtUtc        = $expires.ToString("o")
    }
}

function Test-CredentialUsageGuard {

    param(
        [Parameter(Mandatory)]
        [string]$UsageId,

        [Parameter(Mandatory)]
        [string]$MaterializationId,

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
        [string]$TenantId
    )

    $config = Get-CredentialUsageGuardConfig

    if (-not $config.enabled) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "DISABLED"
        }
    }

    $record = Get-CredentialUsageGuardRecord -UsageId $UsageId

    if ($null -eq $record) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_FOUND"
        }
    }

    if ($record.Status -ne "AUTHORIZED") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "INACTIVE"
        }
    }

    if ($record.Used -eq $true) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "ALREADY_USED"
        }
    }

    $now = (Get-Date).ToUniversalTime()

    $expires = [datetime]::Parse(
        $record.ExpiresAtUtc
    ).ToUniversalTime()

    if ($now -ge $expires) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "EXPIRED"
        }
    }

    if ($record.MaterializationId -ne $MaterializationId) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "MATERIALIZATION_SUBSTITUTION"
        }
    }

    if ($record.ExecutionId -ne $ExecutionId) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "EXECUTION_SUBSTITUTION"
        }
    }

    if ($record.WorkerId -ne $WorkerId) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "WORKER_SUBSTITUTION"
        }
    }

    if ($record.Action -ne $Action) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "ACTION_SUBSTITUTION"
        }
    }

    if ($record.Connector -ne $Connector) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "CONNECTOR_SUBSTITUTION"
        }
    }

    if ($record.ProjectId -ne $ProjectId) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "PROJECT_SUBSTITUTION"
        }
    }

    if ($record.ClientId -ne $ClientId) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "CLIENT_SUBSTITUTION"
        }
    }

    if ($record.TenantId -ne $TenantId) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "TENANT_SUBSTITUTION"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Code = "AUTHORIZED"
        UsageId = $record.UsageId
        UsageHash = $record.UsageHash
        ExpiresAtUtc = $record.ExpiresAtUtc
    }
}

function Consume-CredentialUsageGuard {

    param(
        [Parameter(Mandatory)]
        [string]$UsageId
    )

    $records = @(Get-CredentialUsageGuardRecords)

    $record = $null

    foreach ($item in $records) {

        if ($item.UsageId -eq $UsageId) {
            $record = $item
            break
        }
    }

    if ($null -eq $record) {
        throw "USAGE_NOT_FOUND"
    }

    if ($record.Status -ne "AUTHORIZED") {
        throw "USAGE_NOT_AUTHORIZED"
    }

    if ($record.Used -eq $true) {
        throw "USAGE_ALREADY_USED"
    }

    $record.Used = $true
    $record.Status = "CONSUMED"
    $record.ConsumedAtUtc = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    Save-CredentialUsageGuardRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Status = "CONSUMED"
        UsageId = $UsageId
    }
}

function Revoke-CredentialUsageGuard {

    param(
        [Parameter(Mandatory)]
        [string]$UsageId
    )

    $records = @(Get-CredentialUsageGuardRecords)

    $record = $null

    foreach ($item in $records) {

        if ($item.UsageId -eq $UsageId) {
            $record = $item
            break
        }
    }

    if ($null -eq $record) {
        throw "USAGE_NOT_FOUND"
    }

    $record.Status = "REVOKED"
    $record.RevokedAtUtc = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    Save-CredentialUsageGuardRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Status = "REVOKED"
        UsageId = $UsageId
    }
}

function Reset-CredentialUsageGuard {

    Save-CredentialUsageGuardRecords
}
