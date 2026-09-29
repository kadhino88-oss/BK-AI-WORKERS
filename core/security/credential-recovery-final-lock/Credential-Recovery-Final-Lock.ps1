function Get-CredentialRecoveryFinalLockConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "FINAL_LOCK_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "FINAL_LOCK_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-CredentialRecoveryFinalLockRecords {

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

function Save-CredentialRecoveryFinalLockRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-CredentialRecoveryFinalLockConfig
    $path = Join-Path $PSScriptRoot "state\records.json"

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "FINAL_LOCK_RECORD_LIMIT"
    }

    if ($Records.Count -eq 0) {
        Set-Content `
            -LiteralPath $path `
            -Value "[]" `
            -Encoding UTF8
        return
    }

    $json = ConvertTo-Json `
        -InputObject @($Records) `
        -Depth 30

    Set-Content `
        -LiteralPath $path `
        -Value $json `
        -Encoding UTF8
}

function Get-CredentialRecoveryFinalLockRecord {

    param(
        [Parameter(Mandatory)]
        [string]$FinalizationId
    )

    $records = @(Get-CredentialRecoveryFinalLockRecords)

    foreach ($record in $records) {

        if ($record.FinalizationId -eq $FinalizationId) {
            return $record
        }
    }

    return $null
}

function Get-CredentialRecoveryFinalLockHash {

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

function New-CredentialRecoveryFinalizationId {

    return "FINAL-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Finalize-CredentialRecovery {

    param(
        [Parameter(Mandatory)][string]$GlobalCheckId,
        [Parameter(Mandatory)][string]$RecoveryId,
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$ContextId,
        [Parameter(Mandatory)][string]$ActivationId,
        [Parameter(Mandatory)][string]$IntegrityId,
        [Parameter(Mandatory)][string]$OldChainId,
        [Parameter(Mandatory)][string]$NewChainId,
        [Parameter(Mandatory)][string]$NewLeaseId,
        [Parameter(Mandatory)][string]$NewMaterializationId,
        [Parameter(Mandatory)][string]$NewUsageId,
        [Parameter(Mandatory)][string]$NewExecutionId,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Connector
    )

    $config = Get-CredentialRecoveryFinalLockConfig

    if (-not $config.enabled) {
        throw "FINAL_LOCK_DISABLED"
    }

    if (-not $config.finalizationGuardEnabled) {
        throw "FINALIZATION_GUARD_DISABLED"
    }

    $values = @(
        $GlobalCheckId
        $RecoveryId
        $AuthorizationId
        $ContextId
        $ActivationId
        $IntegrityId
        $OldChainId
        $NewChainId
        $NewLeaseId
        $NewMaterializationId
        $NewUsageId
        $NewExecutionId
        $UserId
        $TenantId
        $ClientId
        $ProjectId
        $WorkerId
        $Action
        $Connector
    )

    foreach ($value in $values) {

        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "FINALIZATION_BINDING_REQUIRED"
        }
    }

    if ($OldChainId -eq $NewChainId) {
        throw "OLD_CHAIN_REUSE_FORBIDDEN"
    }

    $records = @(Get-CredentialRecoveryFinalLockRecords)

    foreach ($existing in $records) {

        if (
            $existing.RecoveryId -eq $RecoveryId -and
            $existing.FinalizationStatus -eq "FINALIZED"
        ) {
            throw "RECOVERY_ALREADY_FINALIZED"
        }
    }

    $now = (Get-Date).ToUniversalTime()

    $finalizationId = New-CredentialRecoveryFinalizationId

    $canonical = (
        $GlobalCheckId + "|" +
        $RecoveryId + "|" +
        $AuthorizationId + "|" +
        $ContextId + "|" +
        $ActivationId + "|" +
        $IntegrityId + "|" +
        $OldChainId + "|" +
        $NewChainId + "|" +
        $NewLeaseId + "|" +
        $NewMaterializationId + "|" +
        $NewUsageId + "|" +
        $NewExecutionId + "|" +
        $UserId + "|" +
        $TenantId + "|" +
        $ClientId + "|" +
        $ProjectId + "|" +
        $WorkerId + "|" +
        $Action + "|" +
        $Connector
    )

    $finalizationHash = Get-CredentialRecoveryFinalLockHash `
        -Value $canonical

    $record = [pscustomobject][ordered]@{
        FinalizationId           = $finalizationId
        FinalizationHash         = $finalizationHash
        GlobalCheckId            = $GlobalCheckId
        RecoveryId               = $RecoveryId
        AuthorizationId          = $AuthorizationId
        ContextId                = $ContextId
        ActivationId             = $ActivationId
        IntegrityId              = $IntegrityId
        OldChainId               = $OldChainId
        NewChainId               = $NewChainId
        NewLeaseId               = $NewLeaseId
        NewMaterializationId     = $NewMaterializationId
        NewUsageId               = $NewUsageId
        NewExecutionId           = $NewExecutionId
        UserId                   = $UserId
        TenantId                 = $TenantId
        ClientId                 = $ClientId
        ProjectId                = $ProjectId
        WorkerId                 = $WorkerId
        Action                   = $Action
        Connector                = $Connector
        OldChainStatus           = "REVOKED"
        NewChainStatus           = "ACTIVE"
        NewLeaseStatus           = "ACTIVE"
        NewMaterializationStatus = "ACTIVE"
        NewUsageStatus            = "ACTIVE"
        NewExecutionStatus        = "AUTHORIZED"
        GlobalStatus              = "CONSISTENT"
        FinalizationStatus        = "FINALIZED"
        Decision                  = "ALLOW"
        Immutable                 = $true
        PermanentLock             = $true
        ReopenAllowed             = $false
        ReactivationAllowed       = $false
        MutationAllowed           = $false
        CreatedAtUtc              = $now.ToString("o")
        FinalizedAtUtc            = $now.ToString("o")
        RawSecret                 = $null
        RawCredential              = $null
    }

    $records += $record

    Save-CredentialRecoveryFinalLockRecords `
        -Records $records

    return [pscustomobject]@{
        Allowed = $true
        FinalizationId = $finalizationId
        FinalizationHash = $finalizationHash
        Status = "FINALIZED"
        PermanentLock = $true
        Decision = "ALLOW"
    }
}

function Test-CredentialRecoveryFinalization {

    param(
        [Parameter(Mandatory)]
        [string]$FinalizationId
    )

    $record = Get-CredentialRecoveryFinalLockRecord `
        -FinalizationId $FinalizationId

    if ($null -eq $record) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_FOUND"
        }
    }

    if ($record.FinalizationStatus -ne "FINALIZED") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_FINALIZED"
        }
    }

    if ($record.Immutable -ne $true) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "IMMUTABILITY_FAILURE"
        }
    }

    if ($record.PermanentLock -ne $true) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "LOCK_MISSING"
        }
    }

    if ($record.ReopenAllowed -eq $true) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "REOPEN_ALLOWED"
        }
    }

    if ($record.ReactivationAllowed -eq $true) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "REACTIVATION_ALLOWED"
        }
    }

    if ($record.MutationAllowed -eq $true) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "MUTATION_ALLOWED"
        }
    }

    if ($record.OldChainStatus -ne "REVOKED") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "OLD_CHAIN_NOT_REVOKED"
        }
    }

    if ($record.NewChainStatus -ne "ACTIVE") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NEW_CHAIN_NOT_ACTIVE"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Code = "FINALIZED_AND_LOCKED"
        FinalizationId = $FinalizationId
    }
}

function Test-CredentialRecoveryReopen {

    param(
        [Parameter(Mandatory)]
        [string]$FinalizationId
    )

    $record = Get-CredentialRecoveryFinalLockRecord `
        -FinalizationId $FinalizationId

    if ($null -eq $record) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_FOUND"
        }
    }

    if ($record.PermanentLock -eq $true) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "PERMANENT_LOCK"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Code = "REOPEN_ALLOWED"
    }
}

function Reset-CredentialRecoveryFinalLock {

    Save-CredentialRecoveryFinalLockRecords
}
