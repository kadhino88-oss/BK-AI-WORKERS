function Get-CredentialRevocationCascadeIntegrityConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "CASCADE_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "CASCADE_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-CredentialRevocationCascadeIntegrityRecords {

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

function Save-CredentialRevocationCascadeIntegrityRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-CredentialRevocationCascadeIntegrityConfig

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "CASCADE_RECORD_LIMIT"
    }

    $path = Join-Path $PSScriptRoot "state\records.json"

    if ($Records.Count -eq 0) {
        Set-Content -LiteralPath $path -Value "[]" -Encoding UTF8
        return
    }

    $json = ConvertTo-Json -InputObject @($Records) -Depth 20

    Set-Content `
        -LiteralPath $path `
        -Value $json `
        -Encoding UTF8
}

function Get-CredentialRevocationCascadeIntegrityRecord {

    param(
        [Parameter(Mandatory)]
        [string]$CascadeId
    )

    $records = @(Get-CredentialRevocationCascadeIntegrityRecords)

    foreach ($record in $records) {

        if ($record.CascadeId -eq $CascadeId) {
            return $record
        }
    }

    return $null
}

function Get-CascadeHash {

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

function New-CascadeId {

    return "CASCADE-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function New-ExecutionCredentialCascade {

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

    $config = Get-CredentialRevocationCascadeIntegrityConfig

    if (-not $config.enabled) {
        throw "CASCADE_DISABLED"
    }

    if (-not $config.cascadeIntegrityEnabled) {
        throw "CASCADE_INTEGRITY_DISABLED"
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

    $now = (Get-Date).ToUniversalTime()

    $cascadeId = New-CascadeId

    $bindingString = (
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

    $cascadeHash = Get-CascadeHash -Value $bindingString

    $record = [pscustomobject][ordered]@{
        CascadeId             = $cascadeId
        CascadeHash           = $cascadeHash
        CredentialRefHash     = Get-CascadeHash -Value $CredentialRef
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
        CredentialStatus      = "ACTIVE"
        LeaseStatus           = "ACTIVE"
        MaterializationStatus = "ACTIVE"
        UsageStatus           = "ACTIVE"
        ExecutionStatus       = "AUTHORIZED"
        CascadeStatus         = "ACTIVE"
        Decision              = "ALLOW"
        CreatedAtUtc          = $now.ToString("o")
        RevokedAtUtc          = $null
        RevocationReason      = $null
        RawSecret             = $null
        RawCredential         = $null
    }

    $records = @(Get-CredentialRevocationCascadeIntegrityRecords)
    $records += $record

    Save-CredentialRevocationCascadeIntegrityRecords -Records $records

    return [pscustomobject]@{
        Allowed   = $true
        CascadeId = $cascadeId
        CascadeHash = $cascadeHash
        Status    = "ACTIVE"
    }
}

function Revoke-CredentialCascade {

    param(
        [Parameter(Mandatory)]
        [string]$CredentialRef,

        [Parameter(Mandatory)]
        [string]$Reason
    )

    $config = Get-CredentialRevocationCascadeIntegrityConfig

    if (-not $config.enabled) {
        throw "CASCADE_DISABLED"
    }

    if (-not $config.propagateRevocation) {
        throw "CASCADE_PROPAGATION_DISABLED"
    }

    if ([string]::IsNullOrWhiteSpace($CredentialRef)) {
        throw "CREDENTIAL_REF_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        throw "REVOCATION_REASON_REQUIRED"
    }

    $credentialHash = Get-CascadeHash -Value $CredentialRef
    $records = @(Get-CredentialRevocationCascadeIntegrityRecords)
    $now = (Get-Date).ToUniversalTime()

    $affected = 0

    foreach ($record in $records) {

        if ($record.CredentialRefHash -eq $credentialHash) {

            if ($record.CascadeStatus -eq "ACTIVE") {

                $record.CredentialStatus = "REVOKED"
                $record.LeaseStatus = "REVOKED"
                $record.MaterializationStatus = "REVOKED"
                $record.UsageStatus = "REVOKED"
                $record.ExecutionStatus = "BLOCKED"
                $record.CascadeStatus = "REVOKED"
                $record.Decision = "BLOCK"
                $record.RevokedAtUtc = $now.ToString("o")
                $record.RevocationReason = $Reason

                $affected++
            }
        }
    }

    Save-CredentialRevocationCascadeIntegrityRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Status = "REVOKED"
        AffectedCascadeCount = $affected
        CredentialRefHash = $credentialHash
    }
}

function Test-CredentialRevocationCascadeIntegrity {

    param(
        [Parameter(Mandatory)]
        [string]$CascadeId,

        [Parameter(Mandatory)]
        [string]$CredentialRef,

        [Parameter(Mandatory)]
        [string]$LeaseId,

        [Parameter(Mandatory)]
        [string]$MaterializationId,

        [Parameter(Mandatory)]
        [string]$UsageId,

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

    $record = Get-CredentialRevocationCascadeIntegrityRecord `
        -CascadeId $CascadeId

    if ($null -eq $record) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_FOUND"
        }
    }

    if ($record.CascadeStatus -ne "ACTIVE") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "CASCADE_REVOKED"
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

    $credentialHash = Get-CascadeHash -Value $CredentialRef

    if ($credentialHash -ne $record.CredentialRefHash) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "CREDENTIAL_SUBSTITUTION"
        }
    }

    $bindingString = (
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

    $bindingHash = Get-CascadeHash -Value $bindingString

    if ($bindingHash -ne $record.CascadeHash) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "CASCADE_INTEGRITY_FAILURE"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Code = "AUTHORIZED"
        CascadeId = $CascadeId
    }
}

function Reset-CredentialRevocationCascadeIntegrity {

    Save-CredentialRevocationCascadeIntegrityRecords
}
