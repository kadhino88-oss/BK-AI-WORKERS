function Get-CredentialRecoveryEnforcementConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "ENFORCEMENT_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "ENFORCEMENT_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-CredentialRecoveryEnforcementRecords {

    $path = Join-Path $PSScriptRoot "state\enforcement.json"

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

function Save-CredentialRecoveryEnforcementRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-CredentialRecoveryEnforcementConfig
    $path = Join-Path $PSScriptRoot "state\enforcement.json"

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "ENFORCEMENT_RECORD_LIMIT"
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

function Get-CredentialRecoveryEnforcementHash {

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

function New-CredentialRecoveryEnforcementId {

    return "ENF-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Invoke-CredentialRecoveryFinalEnforcement {

    param(
        [Parameter(Mandatory)][string]$GlobalCheckId,
        [Parameter(Mandatory)][string]$FinalizationId,
        [Parameter(Mandatory)][string]$RecoveryId,
        [Parameter(Mandatory)][string]$AuditFinalizationEventId,
        [Parameter(Mandatory)][string]$AuditIntegrityCode,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$OldChainId,
        [Parameter(Mandatory)][string]$NewChainId,
        [Parameter(Mandatory)][string]$NewLeaseId,
        [Parameter(Mandatory)][string]$NewMaterializationId,
        [Parameter(Mandatory)][string]$NewUsageId,
        [Parameter(Mandatory)][string]$NewExecutionId,
        [Parameter(Mandatory)][bool]$GlobalConsistent,
        [Parameter(Mandatory)][bool]$Finalized,
        [Parameter(Mandatory)][bool]$PermanentLock,
        [Parameter(Mandatory)][bool]$Immutable,
        [Parameter(Mandatory)][bool]$OldChainRevoked,
        [Parameter(Mandatory)][bool]$NewChainActive,
        [Parameter(Mandatory)][bool]$FreshBindings
    )

    $config = Get-CredentialRecoveryEnforcementConfig

    if (-not $config.enabled) {
        throw "ENFORCEMENT_DISABLED"
    }

    if (-not $config.enforcementEnabled) {
        throw "FINAL_ENFORCEMENT_DISABLED"
    }

    $requiredStrings = @(
        $GlobalCheckId
        $FinalizationId
        $RecoveryId
        $AuditFinalizationEventId
        $AuditIntegrityCode
        $TenantId
        $ClientId
        $ProjectId
        $UserId
        $WorkerId
        $OldChainId
        $NewChainId
        $NewLeaseId
        $NewMaterializationId
        $NewUsageId
        $NewExecutionId
    )

    foreach ($value in $requiredStrings) {

        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "ENFORCEMENT_BINDING_REQUIRED"
        }
    }

    if ($OldChainId -eq $NewChainId) {
        throw "OLD_NEW_CHAIN_EQUAL"
    }

    if (-not $GlobalConsistent) {
        throw "GLOBAL_CONSISTENCY_REQUIRED"
    }

    if (-not $Finalized) {
        throw "FINALIZATION_REQUIRED"
    }

    if (-not $PermanentLock) {
        throw "PERMANENT_LOCK_REQUIRED"
    }

    if (-not $Immutable) {
        throw "IMMUTABLE_STATE_REQUIRED"
    }

    if (-not $OldChainRevoked) {
        throw "OLD_CHAIN_REVOCATION_REQUIRED"
    }

    if (-not $NewChainActive) {
        throw "NEW_CHAIN_ACTIVE_REQUIRED"
    }

    if (-not $FreshBindings) {
        throw "FRESH_BINDINGS_REQUIRED"
    }

    if ($AuditIntegrityCode -ne "AUDIT_INTEGRITY_VALID") {
        throw "AUDIT_INTEGRITY_INVALID"
    }

    $records = @(Get-CredentialRecoveryEnforcementRecords)

    foreach ($existing in $records) {

        if (
            $existing.RecoveryId -eq $RecoveryId -and
            $existing.Decision -eq "ALLOW"
        ) {
            throw "RECOVERY_ALREADY_ENFORCED"
        }
    }

    $now = (Get-Date).ToUniversalTime().ToString("o")
    $enforcementId = New-CredentialRecoveryEnforcementId

    $canonical = (
        $enforcementId + "|" +
        $GlobalCheckId + "|" +
        $FinalizationId + "|" +
        $RecoveryId + "|" +
        $AuditFinalizationEventId + "|" +
        $AuditIntegrityCode + "|" +
        $TenantId + "|" +
        $ClientId + "|" +
        $ProjectId + "|" +
        $UserId + "|" +
        $WorkerId + "|" +
        $OldChainId + "|" +
        $NewChainId + "|" +
        $NewLeaseId + "|" +
        $NewMaterializationId + "|" +
        $NewUsageId + "|" +
        $NewExecutionId + "|" +
        $now
    )

    $integrityHash = Get-CredentialRecoveryEnforcementHash `
        -Value $canonical

    $record = [pscustomobject][ordered]@{
        EnforcementId            = $enforcementId
        IntegrityHash             = $integrityHash
        GlobalCheckId             = $GlobalCheckId
        FinalizationId             = $FinalizationId
        RecoveryId                = $RecoveryId
        AuditFinalizationEventId  = $AuditFinalizationEventId
        AuditIntegrityCode        = $AuditIntegrityCode
        TenantId                  = $TenantId
        ClientId                  = $ClientId
        ProjectId                 = $ProjectId
        UserId                    = $UserId
        WorkerId                  = $WorkerId
        OldChainId                = $OldChainId
        NewChainId                = $NewChainId
        NewLeaseId                = $NewLeaseId
        NewMaterializationId      = $NewMaterializationId
        NewUsageId                = $NewUsageId
        NewExecutionId            = $NewExecutionId
        GlobalConsistent           = $GlobalConsistent
        Finalized                  = $Finalized
        PermanentLock             = $PermanentLock
        Immutable                 = $Immutable
        OldChainRevoked           = $OldChainRevoked
        NewChainActive            = $NewChainActive
        FreshBindings             = $FreshBindings
        Decision                  = "ALLOW"
        EnforcementStatus         = "ENFORCED"
        ReopenAllowed             = $false
        ReactivationAllowed       = $false
        MutationAllowed            = $false
        CrossTenantAllowed         = $false
        StaleStateAllowed         = $false
        TamperDetected            = $false
        CreatedAtUtc              = $now
        RawSecret                 = $null
        RawCredential              = $null
    }

    $records += $record

    Save-CredentialRecoveryEnforcementRecords `
        -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "FINAL_ENFORCEMENT_APPLIED"
        EnforcementId = $enforcementId
        EnforcementStatus = "ENFORCED"
        PermanentLock = $true
    }
}

function Test-CredentialRecoveryFinalEnforcement {

    param(
        [Parameter(Mandatory)]
        [string]$EnforcementId
    )

    $records = @(Get-CredentialRecoveryEnforcementRecords)

    $record = $null

    foreach ($item in $records) {

        if ($item.EnforcementId -eq $EnforcementId) {
            $record = $item
            break
        }
    }

    if ($null -eq $record) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "ENFORCEMENT_NOT_FOUND"
        }
    }

    if ($record.EnforcementStatus -ne "ENFORCED") {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "ENFORCEMENT_STATUS_INVALID"
        }
    }

    if ($record.Decision -ne "ALLOW") {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "ENFORCEMENT_DECISION_INVALID"
        }
    }

    if ($record.PermanentLock -ne $true) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "PERMANENT_LOCK_MISSING"
        }
    }

    if ($record.Immutable -ne $true) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "IMMUTABLE_STATE_MISSING"
        }
    }

    if ($record.ReopenAllowed -eq $true) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "REOPEN_ALLOWED"
        }
    }

    if ($record.ReactivationAllowed -eq $true) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "REACTIVATION_ALLOWED"
        }
    }

    if ($record.MutationAllowed -eq $true) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "MUTATION_ALLOWED"
        }
    }

    if ($record.CrossTenantAllowed -eq $true) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "CROSS_TENANT_ALLOWED"
        }
    }

    if ($record.StaleStateAllowed -eq $true) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "STALE_STATE_ALLOWED"
        }
    }

    if ($record.TamperDetected -eq $true) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "TAMPER_DETECTED"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "FINAL_ENFORCEMENT_VALID"
    }
}

function Get-CredentialRecoveryEnforcementRecord {

    param(
        [Parameter(Mandatory)]
        [string]$EnforcementId
    )

    $records = @(Get-CredentialRecoveryEnforcementRecords)

    foreach ($record in $records) {

        if ($record.EnforcementId -eq $EnforcementId) {
            return $record
        }
    }

    return $null
}

function Reset-CredentialRecoveryFinalEnforcement {

    Save-CredentialRecoveryEnforcementRecords
}
