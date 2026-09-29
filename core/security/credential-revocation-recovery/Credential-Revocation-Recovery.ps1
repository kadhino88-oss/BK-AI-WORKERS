function Get-CredentialRevocationRecoveryConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "RECOVERY_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "RECOVERY_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-CredentialRevocationRecoveryRecords {

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

function Save-CredentialRevocationRecoveryRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-CredentialRevocationRecoveryConfig

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "RECOVERY_RECORD_LIMIT"
    }

    $path = Join-Path $PSScriptRoot "state\records.json"

    if ($Records.Count -eq 0) {
        Set-Content -LiteralPath $path -Value "[]" -Encoding UTF8
        return
    }

    $json = ConvertTo-Json -InputObject @($Records) -Depth 30

    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
}

function Get-CredentialRevocationRecoveryRecord {

    param(
        [Parameter(Mandatory)]
        [string]$RecoveryId
    )

    $records = @(Get-CredentialRevocationRecoveryRecords)

    foreach ($record in $records) {

        if ($record.RecoveryId -eq $RecoveryId) {
            return $record
        }
    }

    return $null
}

function Get-CredentialRecoveryHash {

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

function New-CredentialRecoveryId {

    return "REC-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function New-CredentialRecoveryChainId {

    return "CHAIN-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function New-CredentialRecoveryLeaseId {

    return "LEASE-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function New-CredentialRecoveryMaterializationId {

    return "MAT-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function New-CredentialRecoveryUsageId {

    return "USE-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function New-CredentialRecoveryExecutionId {

    return "EXEC-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Register-CredentialRevokedChain {

    param(
        [Parameter(Mandatory)][string]$CredentialRef,
        [Parameter(Mandatory)][string]$ChainId,
        [Parameter(Mandatory)][string]$LeaseId,
        [Parameter(Mandatory)][string]$MaterializationId,
        [Parameter(Mandatory)][string]$UsageId,
        [Parameter(Mandatory)][string]$ExecutionId
    )

    $config = Get-CredentialRevocationRecoveryConfig

    if (-not $config.enabled) {
        throw "RECOVERY_DISABLED"
    }

    if ([string]::IsNullOrWhiteSpace($CredentialRef)) {
        throw "CREDENTIAL_REF_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($ChainId)) {
        throw "CHAIN_ID_REQUIRED"
    }

    $now = (Get-Date).ToUniversalTime()

    $record = [pscustomobject][ordered]@{
        RecoveryId            = New-CredentialRecoveryId
        ChainId               = $ChainId
        CredentialRefHash     = Get-CredentialRecoveryHash -Value $CredentialRef
        LeaseId               = $LeaseId
        MaterializationId     = $MaterializationId
        UsageId               = $UsageId
        ExecutionId           = $ExecutionId
        ChainStatus           = "REVOKED"
        RecoveryStatus        = "CLOSED"
        ReactivationAllowed   = $false
        CreatedAtUtc          = $now.ToString("o")
        ClosedAtUtc           = $now.ToString("o")
        RawSecret             = $null
        RawCredential         = $null
    }

    $records = @(Get-CredentialRevocationRecoveryRecords)

    $records += $record

    Save-CredentialRevocationRecoveryRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        RecoveryId = $record.RecoveryId
        ChainId = $ChainId
        Status = "CLOSED"
    }
}

function Recover-CredentialWithNewChain {

    param(
        [Parameter(Mandatory)]
        [string]$ParentRecoveryId,

        [Parameter(Mandatory)]
        [string]$CredentialRef
    )

    $config = Get-CredentialRevocationRecoveryConfig

    if (-not $config.enabled) {
        throw "RECOVERY_DISABLED"
    }

    if (-not $config.recoveryGuardEnabled) {
        throw "RECOVERY_GUARD_DISABLED"
    }

    if (-not $config.newChainRequired) {
        throw "NEW_CHAIN_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($ParentRecoveryId)) {
        throw "PARENT_RECOVERY_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($CredentialRef)) {
        throw "CREDENTIAL_REF_REQUIRED"
    }

    $parent = Get-CredentialRevocationRecoveryRecord `
        -RecoveryId $ParentRecoveryId

    if ($null -eq $parent) {
        throw "PARENT_RECOVERY_NOT_FOUND"
    }

    if ($parent.RecoveryStatus -ne "CLOSED") {
        throw "PARENT_CHAIN_NOT_CLOSED"
    }

    if ($parent.ChainStatus -ne "REVOKED") {
        throw "PARENT_CHAIN_NOT_REVOKED"
    }

    if ($parent.ReactivationAllowed -eq $true) {
        throw "PARENT_REACTIVATION_FORBIDDEN"
    }

    $records = @(Get-CredentialRevocationRecoveryRecords)

    foreach ($existing in $records) {

        if (
            $existing.ChainId -eq $parent.ChainId -and
            $existing.RecoveryStatus -eq "ACTIVE"
        ) {
            throw "ACTIVE_RECOVERY_ALREADY_EXISTS"
        }
    }

    $now = (Get-Date).ToUniversalTime()

    $newChainId = New-CredentialRecoveryChainId
    $newLeaseId = New-CredentialRecoveryLeaseId
    $newMaterializationId = New-CredentialRecoveryMaterializationId
    $newUsageId = New-CredentialRecoveryUsageId
    $newExecutionId = New-CredentialRecoveryExecutionId

    $record = [pscustomobject][ordered]@{
        RecoveryId            = New-CredentialRecoveryId
        ParentRecoveryId     = $ParentRecoveryId
        ParentChainId        = $parent.ChainId
        ChainId               = $newChainId
        CredentialRefHash     = Get-CredentialRecoveryHash -Value $CredentialRef
        LeaseId               = $newLeaseId
        MaterializationId     = $newMaterializationId
        UsageId               = $newUsageId
        ExecutionId           = $newExecutionId
        ChainStatus           = "ACTIVE"
        RecoveryStatus        = "ACTIVE"
        ReactivationAllowed   = $false
        Decision              = "ALLOW"
        CreatedAtUtc          = $now.ToString("o")
        ClosedAtUtc           = $null
        RawSecret             = $null
        RawCredential         = $null
    }

    $records += $record

    Save-CredentialRevocationRecoveryRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        RecoveryId = $record.RecoveryId
        ParentRecoveryId = $ParentRecoveryId
        ParentChainId = $parent.ChainId
        NewChainId = $newChainId
        NewLeaseId = $newLeaseId
        NewMaterializationId = $newMaterializationId
        NewUsageId = $newUsageId
        NewExecutionId = $newExecutionId
        Status = "ACTIVE"
    }
}

function Test-CredentialRecoveryChain {

    param(
        [Parameter(Mandatory)]
        [string]$RecoveryId
    )

    $record = Get-CredentialRevocationRecoveryRecord `
        -RecoveryId $RecoveryId

    if ($null -eq $record) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_FOUND"
        }
    }

    if ($record.RecoveryStatus -eq "CLOSED") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "CLOSED"
        }
    }

    if ($record.ReactivationAllowed -eq $true) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "REACTIVATION_FORBIDDEN"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Code = "ACTIVE_NEW_CHAIN"
        ChainId = $record.ChainId
    }
}

function Test-CredentialOldChainReuse {

    param(
        [Parameter(Mandatory)]
        [string]$RecoveryId
    )

    $record = Get-CredentialRevocationRecoveryRecord `
        -RecoveryId $RecoveryId

    if ($null -eq $record) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_FOUND"
        }
    }

    if ($record.ChainStatus -eq "REVOKED") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "OLD_CHAIN_REVOKED"
        }
    }

    if ($record.RecoveryStatus -eq "CLOSED") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "OLD_CHAIN_CLOSED"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Code = "REUSABLE"
    }
}

function Reset-CredentialRevocationRecovery {

    Save-CredentialRevocationRecoveryRecords
}
