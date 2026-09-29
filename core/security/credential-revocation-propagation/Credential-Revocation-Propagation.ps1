function Get-CredentialRevocationPropagationConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "CONFIG_MISSING"
    }

    $text = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "CONFIG_EMPTY"
    }

    return $text | ConvertFrom-Json
}

function Get-CredentialRevocationPropagationRecords {

    $path = Join-Path $PSScriptRoot "state\records.json"

    if (-not (Test-Path -LiteralPath $path)) {
        return @()
    }

    $text = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }

    $data = $text | ConvertFrom-Json

    if ($null -eq $data) {
        return @()
    }

    if ($data -is [System.Array]) {
        return @($data)
    }

    return @($data)
}

function Save-CredentialRevocationPropagationRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $path = Join-Path $PSScriptRoot "state\records.json"

    if ($Records.Count -eq 0) {
        Set-Content -LiteralPath $path -Value "[]" -Encoding UTF8
        return
    }

    $config = Get-CredentialRevocationPropagationConfig

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "RECORD_LIMIT"
    }

    $json = ConvertTo-Json -InputObject @($Records) -Depth 20

    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
}

function Get-CredentialRevocationPropagationRecord {

    param(
        [Parameter(Mandatory)]
        [string]$RecordId
    )

    $records = @(Get-CredentialRevocationPropagationRecords)

    foreach ($record in $records) {

        if ($record.RecordId -eq $RecordId) {
            return $record
        }
    }

    return $null
}

function Get-CredentialRevocationHash {

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

function New-CredentialRevocationRecordId {

    return "REV-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Register-CredentialActiveUsage {

    param(
        [Parameter(Mandatory)][string]$CredentialRef,
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

    $config = Get-CredentialRevocationPropagationConfig

    if (-not $config.enabled) {
        throw "MODULE_DISABLED"
    }

    if (-not $config.revocationPropagationEnabled) {
        throw "PROPAGATION_DISABLED"
    }

    if ([string]::IsNullOrWhiteSpace($CredentialRef)) {
        throw "CREDENTIAL_REF_REQUIRED"
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

    $records = @(Get-CredentialRevocationPropagationRecords)

    foreach ($existing in $records) {

        if ($existing.UsageId -eq $UsageId -and $existing.Status -eq "ACTIVE") {
            throw "ACTIVE_USAGE_ALREADY_REGISTERED"
        }
    }

    $now = (Get-Date).ToUniversalTime()

    $record = [pscustomobject][ordered]@{
        RecordId          = New-CredentialRevocationRecordId
        CredentialRefHash = Get-CredentialRevocationHash -Value $CredentialRef
        MaterializationId = $MaterializationId
        UsageId           = $UsageId
        ExecutionId       = $ExecutionId
        WorkerId          = $WorkerId
        Action            = $Action
        Connector         = $Connector
        ProjectId         = $ProjectId
        ClientId          = $ClientId
        TenantId          = $TenantId
        Status            = "ACTIVE"
        Decision          = "ALLOW"
        CreatedAtUtc      = $now.ToString("o")
        RevokedAtUtc      = $null
        RevocationReason  = $null
        RawSecret         = $null
        RawCredential     = $null
    }

    $records += $record

    Save-CredentialRevocationPropagationRecords -Records $records

    return [pscustomobject]@{
        Allowed  = $true
        RecordId = $record.RecordId
        UsageId  = $UsageId
        Status   = "ACTIVE"
    }
}

function Revoke-CredentialAndPropagate {

    param(
        [Parameter(Mandatory)]
        [string]$CredentialRef,

        [Parameter(Mandatory)]
        [string]$Reason
    )

    $config = Get-CredentialRevocationPropagationConfig

    if (-not $config.enabled) {
        throw "MODULE_DISABLED"
    }

    if (-not $config.revocationPropagationEnabled) {
        throw "PROPAGATION_DISABLED"
    }

    if ([string]::IsNullOrWhiteSpace($CredentialRef)) {
        throw "CREDENTIAL_REF_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        throw "REVOCATION_REASON_REQUIRED"
    }

    $targetHash = Get-CredentialRevocationHash -Value $CredentialRef
    $records = @(Get-CredentialRevocationPropagationRecords)
    $now = (Get-Date).ToUniversalTime()
    $affected = 0

    foreach ($record in $records) {

        if ($record.CredentialRefHash -eq $targetHash) {

            if ($record.Status -eq "ACTIVE") {

                $record.Status = "REVOKED"
                $record.Decision = "BLOCK"
                $record.RevokedAtUtc = $now.ToString("o")
                $record.RevocationReason = $Reason

                $affected++
            }
        }
    }

    Save-CredentialRevocationPropagationRecords -Records $records

    return [pscustomobject]@{
        Allowed            = $true
        Status             = "REVOKED"
        AffectedUsageCount = $affected
        CredentialRefHash  = $targetHash
    }
}

function Test-CredentialActiveUsage {

    param(
        [Parameter(Mandatory)][string]$RecordId,
        [Parameter(Mandatory)][string]$CredentialRef,
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

    $config = Get-CredentialRevocationPropagationConfig

    if (-not $config.enabled) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "DISABLED"
        }
    }

    $record = Get-CredentialRevocationPropagationRecord -RecordId $RecordId

    if ($null -eq $record) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_FOUND"
        }
    }

    if ($record.Status -ne "ACTIVE") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "REVOKED"
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

    $credentialHash = Get-CredentialRevocationHash -Value $CredentialRef

    if ($credentialHash -ne $record.CredentialRefHash) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "CREDENTIAL_SUBSTITUTION"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Code = "AUTHORIZED"
        RecordId = $RecordId
    }
}

function Reset-CredentialRevocationPropagation {

    Save-CredentialRevocationPropagationRecords
}
