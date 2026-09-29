function Get-CredentialRevocationClosureConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "CLOSURE_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "CLOSURE_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-CredentialRevocationClosureRecords {

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

function Save-CredentialRevocationClosureRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-CredentialRevocationClosureConfig

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "CLOSURE_RECORD_LIMIT"
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

function Get-CredentialRevocationClosureRecord {

    param(
        [Parameter(Mandatory)]
        [string]$ClosureId
    )

    $records = @(Get-CredentialRevocationClosureRecords)

    foreach ($record in $records) {

        if ($record.ClosureId -eq $ClosureId) {
            return $record
        }
    }

    return $null
}

function Get-CredentialClosureHash {

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

function New-CredentialClosureId {

    return "CLOSE-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function New-CredentialRevocationClosure {

    param(
        [Parameter(Mandatory)][string]$CredentialRef,
        [Parameter(Mandatory)][string]$LeaseId,
        [Parameter(Mandatory)][string]$MaterializationId,
        [Parameter(Mandatory)][string]$UsageId,
        [Parameter(Mandatory)][string]$ExecutionId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Connector,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$TenantId
    )

    $config = Get-CredentialRevocationClosureConfig

    if (-not $config.enabled) {
        throw "CLOSURE_DISABLED"
    }

    if (-not $config.closureGuardEnabled) {
        throw "CLOSURE_GUARD_DISABLED"
    }

    if ([string]::IsNullOrWhiteSpace($CredentialRef)) {
        throw "CREDENTIAL_REF_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($LeaseId)) {
        throw "LEASE_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($MaterializationId)) {
        throw "MATERIALIZATION_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($UsageId)) {
        throw "USAGE_ID_REQUIRED"
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

    $records = @(Get-CredentialRevocationClosureRecords)

    foreach ($existing in $records) {

        if (
            $existing.ExecutionId -eq $ExecutionId -and
            $existing.Status -eq "CLOSED"
        ) {
            throw "EXECUTION_ALREADY_CLOSED"
        }
    }

    $now = (Get-Date).ToUniversalTime()

    $closureId = New-CredentialClosureId

    $binding = (
        $CredentialRef + "|" +
        $LeaseId + "|" +
        $MaterializationId + "|" +
        $UsageId + "|" +
        $ExecutionId + "|" +
        $WorkerId + "|" +
        $Action + "|" +
        $Connector + "|" +
        $ProjectId + "|" +
        $ClientId + "|" +
        $TenantId
    )

    $closureHash = Get-CredentialClosureHash -Value $binding

    $record = [pscustomobject][ordered]@{
        ClosureId             = $closureId
        ClosureHash           = $closureHash
        CredentialRefHash     = Get-CredentialClosureHash -Value $CredentialRef
        LeaseId               = $LeaseId
        MaterializationId     = $MaterializationId
        UsageId               = $UsageId
        ExecutionId           = $ExecutionId
        WorkerId              = $WorkerId
        Action                = $Action
        Connector             = $Connector
        ProjectId             = $ProjectId
        ClientId              = $ClientId
        TenantId              = $TenantId
        CredentialStatus      = "REVOKED"
        LeaseStatus           = "REVOKED"
        MaterializationStatus = "REVOKED"
        UsageStatus           = "REVOKED"
        ExecutionStatus       = "CLOSED"
        Status                = "CLOSED"
        Decision              = "BLOCK"
        CreatedAtUtc          = $now.ToString("o")
        ClosedAtUtc           = $now.ToString("o")
        ReactivationAllowed   = $false
        RawSecret             = $null
        RawCredential         = $null
    }

    $records += $record

    Save-CredentialRevocationClosureRecords -Records $records

    return [pscustomobject][ordered]@{
        Allowed = $true
        ClosureId = $closureId
        ClosureHash = $closureHash
        Status = "CLOSED"
        Decision = "BLOCK"
    }
}

function Test-CredentialRevocationClosure {

    param(
        [Parameter(Mandatory)][string]$ClosureId,
        [Parameter(Mandatory)][string]$CredentialRef,
        [Parameter(Mandatory)][string]$LeaseId,
        [Parameter(Mandatory)][string]$MaterializationId,
        [Parameter(Mandatory)][string]$UsageId,
        [Parameter(Mandatory)][string]$ExecutionId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Connector,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$TenantId
    )

    $config = Get-CredentialRevocationClosureConfig

    if (-not $config.enabled) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "DISABLED"
        }
    }

    $record = Get-CredentialRevocationClosureRecord `
        -ClosureId $ClosureId

    if ($null -eq $record) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_FOUND"
        }
    }

    if ($record.Status -eq "CLOSED") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "CLOSED"
        }
    }

    if ($record.LeaseId -ne $LeaseId) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "LEASE_SUBSTITUTION"
        }
    }

    if ($record.MaterializationId -ne $MaterializationId) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "MATERIALIZATION_SUBSTITUTION"
        }
    }

    if ($record.UsageId -ne $UsageId) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "USAGE_SUBSTITUTION"
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

    $candidateHash = Get-CredentialClosureHash -Value $CredentialRef

    if ($candidateHash -ne $record.CredentialRefHash) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "CREDENTIAL_SUBSTITUTION"
        }
    }

    $binding = (
        $CredentialRef + "|" +
        $LeaseId + "|" +
        $MaterializationId + "|" +
        $UsageId + "|" +
        $ExecutionId + "|" +
        $WorkerId + "|" +
        $Action + "|" +
        $Connector + "|" +
        $ProjectId + "|" +
        $ClientId + "|" +
        $TenantId
    )

    $candidateClosureHash = Get-CredentialClosureHash -Value $binding

    if ($candidateClosureHash -ne $record.ClosureHash) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "CLOSURE_INTEGRITY_FAILURE"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Code = "AUTHORIZED"
        ClosureId = $ClosureId
    }
}

function Close-CredentialRevocationClosure {

    param(
        [Parameter(Mandatory)]
        [string]$ClosureId
    )

    $records = @(Get-CredentialRevocationClosureRecords)

    $record = $null

    foreach ($item in $records) {

        if ($item.ClosureId -eq $ClosureId) {
            $record = $item
            break
        }
    }

    if ($null -eq $record) {
        throw "CLOSURE_NOT_FOUND"
    }

    if ($record.Status -eq "CLOSED") {

        return [pscustomobject]@{
            Allowed = $true
            Status = "CLOSED"
            ClosureId = $ClosureId
        }
    }

    $record.Status = "CLOSED"
    $record.Decision = "BLOCK"
    $record.ExecutionStatus = "CLOSED"
    $record.ReactivationAllowed = $false
    $record.ClosedAtUtc = (Get-Date).ToUniversalTime().ToString("o")

    Save-CredentialRevocationClosureRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Status = "CLOSED"
        ClosureId = $ClosureId
    }
}

function Test-CredentialReactivation {

    param(
        [Parameter(Mandatory)]
        [string]$ClosureId
    )

    $record = Get-CredentialRevocationClosureRecord `
        -ClosureId $ClosureId

    if ($null -eq $record) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_FOUND"
        }
    }

    if ($record.ReactivationAllowed -ne $true) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "REACTIVATION_BLOCKED"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Code = "REACTIVATION_ALLOWED"
    }
}

function Reset-CredentialRevocationClosure {

    Save-CredentialRevocationClosureRecords
}
