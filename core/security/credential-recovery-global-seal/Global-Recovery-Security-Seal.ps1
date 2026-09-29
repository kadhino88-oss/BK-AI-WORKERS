function Get-GlobalRecoverySealConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "GLOBAL_SEAL_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "GLOBAL_SEAL_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-GlobalRecoverySealRecords {

    $path = Join-Path $PSScriptRoot "state\seals.json"

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

    return @($data)
}

function Save-GlobalRecoverySealRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-GlobalRecoverySealConfig
    $path = Join-Path $PSScriptRoot "state\seals.json"

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "GLOBAL_SEAL_RECORD_LIMIT"
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
        -Depth 40

    Set-Content `
        -LiteralPath $path `
        -Value $json `
        -Encoding UTF8
}

function Get-GlobalRecoverySealHash {

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

function New-GlobalRecoverySealId {

    return "SEAL-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function New-GlobalRecoverySealNonce {

    return [guid]::NewGuid().ToString("N")
}

function New-GlobalRecoverySecuritySeal {

    param(
        [Parameter(Mandatory)][string]$GlobalCheckId,
        [Parameter(Mandatory)][string]$FinalizationId,
        [Parameter(Mandatory)][string]$FinalizationEventId,
        [Parameter(Mandatory)][string]$EnforcementId,
        [Parameter(Mandatory)][string]$ConsumptionId,
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$ExecutionId,
        [Parameter(Mandatory)][string]$ConflictId,
        [Parameter(Mandatory)][string]$ClosureId,
        [Parameter(Mandatory)][string]$EvidenceId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$WorkerId,

        [Parameter(Mandatory)][bool]$GlobalConsistent,
        [Parameter(Mandatory)][bool]$Finalized,
        [Parameter(Mandatory)][bool]$PermanentLock,
        [Parameter(Mandatory)][bool]$AuditIntegrity,
        [Parameter(Mandatory)][bool]$FinalEnforcement,
        [Parameter(Mandatory)][bool]$AntiReplayValid,
        [Parameter(Mandatory)][bool]$TenantIsolationValid,
        [Parameter(Mandatory)][bool]$RevocationValid,
        [Parameter(Mandatory)][bool]$RevocationSyncValid,
        [Parameter(Mandatory)][bool]$ConflictResolved,
        [Parameter(Mandatory)][bool]$ConflictClosed,
        [Parameter(Mandatory)][bool]$EvidenceValid
    )

    $config = Get-GlobalRecoverySealConfig

    if (-not $config.enabled) {
        throw "GLOBAL_SEAL_DISABLED"
    }

    if (-not $config.sealEnabled) {
        throw "SECURITY_SEAL_DISABLED"
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

    if (-not $AuditIntegrity) {
        throw "AUDIT_INTEGRITY_REQUIRED"
    }

    if (-not $FinalEnforcement) {
        throw "FINAL_ENFORCEMENT_REQUIRED"
    }

    if (-not $AntiReplayValid) {
        throw "ANTI_REPLAY_REQUIRED"
    }

    if (-not $TenantIsolationValid) {
        throw "TENANT_ISOLATION_REQUIRED"
    }

    if (-not $RevocationValid) {
        throw "REVOCATION_VALIDATION_REQUIRED"
    }

    if (-not $RevocationSyncValid) {
        throw "REVOCATION_SYNC_REQUIRED"
    }

    if (-not $ConflictResolved) {
        throw "CONFLICT_RESOLUTION_REQUIRED"
    }

    if (-not $ConflictClosed) {
        throw "CONFLICT_CLOSURE_REQUIRED"
    }

    if (-not $EvidenceValid) {
        throw "PERMANENT_EVIDENCE_REQUIRED"
    }

    $requiredStrings = @(
        $GlobalCheckId
        $FinalizationId
        $FinalizationEventId
        $EnforcementId
        $ConsumptionId
        $AuthorizationId
        $ExecutionId
        $ConflictId
        $ClosureId
        $EvidenceId
        $TenantId
        $ClientId
        $ProjectId
        $UserId
        $WorkerId
    )

    foreach ($value in $requiredStrings) {

        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "GLOBAL_SEAL_BINDING_REQUIRED"
        }
    }

    $records = @(Get-GlobalRecoverySealRecords)

    foreach ($existing in $records) {

        if (
            $existing.FinalizationId -eq $FinalizationId -or
            $existing.ExecutionId -eq $ExecutionId
        ) {

            throw "SECURITY_SEAL_ALREADY_EXISTS"
        }
    }

    $nonce = New-GlobalRecoverySealNonce
    $sealId = New-GlobalRecoverySealId
    $now = (Get-Date).ToUniversalTime().ToString("o")

    $chainState = (
        "GLOBAL_CONSISTENT=" + $GlobalConsistent + "|" +
        "FINALIZED=" + $Finalized + "|" +
        "PERMANENT_LOCK=" + $PermanentLock + "|" +
        "AUDIT_INTEGRITY=" + $AuditIntegrity + "|" +
        "FINAL_ENFORCEMENT=" + $FinalEnforcement + "|" +
        "ANTI_REPLAY=" + $AntiReplayValid + "|" +
        "TENANT_ISOLATION=" + $TenantIsolationValid + "|" +
        "REVOCATION=" + $RevocationValid + "|" +
        "REVOCATION_SYNC=" + $RevocationSyncValid + "|" +
        "CONFLICT_RESOLVED=" + $ConflictResolved + "|" +
        "CONFLICT_CLOSED=" + $ConflictClosed + "|" +
        "EVIDENCE_VALID=" + $EvidenceValid
    )

    $canonical = (
        $sealId + "|" +
        $GlobalCheckId + "|" +
        $FinalizationId + "|" +
        $FinalizationEventId + "|" +
        $EnforcementId + "|" +
        $ConsumptionId + "|" +
        $AuthorizationId + "|" +
        $ExecutionId + "|" +
        $ConflictId + "|" +
        $ClosureId + "|" +
        $EvidenceId + "|" +
        $TenantId + "|" +
        $ClientId + "|" +
        $ProjectId + "|" +
        $UserId + "|" +
        $WorkerId + "|" +
        $chainState + "|" +
        $nonce + "|" +
        $now
    )

    $sealHash = Get-GlobalRecoverySealHash `
        -Value $canonical

    $record = [pscustomobject][ordered]@{
        SealId                 = $sealId
        SecuritySealHash       = $sealHash
        SealNonce              = $nonce

        GlobalCheckId           = $GlobalCheckId
        FinalizationId          = $FinalizationId
        FinalizationEventId     = $FinalizationEventId
        EnforcementId           = $EnforcementId
        ConsumptionId           = $ConsumptionId
        AuthorizationId         = $AuthorizationId
        ExecutionId             = $ExecutionId

        ConflictId              = $ConflictId
        ClosureId               = $ClosureId
        EvidenceId              = $EvidenceId

        TenantId                = $TenantId
        ClientId                = $ClientId
        ProjectId               = $ProjectId
        UserId                  = $UserId
        WorkerId                = $WorkerId

        GlobalConsistent        = $GlobalConsistent
        Finalized               = $Finalized
        PermanentLock           = $PermanentLock
        AuditIntegrity          = $AuditIntegrity
        FinalEnforcement        = $FinalEnforcement
        AntiReplayValid         = $AntiReplayValid
        TenantIsolationValid    = $TenantIsolationValid
        RevocationValid         = $RevocationValid
        RevocationSyncValid     = $RevocationSyncValid
        ConflictResolved        = $ConflictResolved
        ConflictClosed          = $ConflictClosed
        EvidenceValid           = $EvidenceValid

        SealStatus              = "SEALED"
        Decision                = "ALLOW"

        PermanentSeal           = $true
        Immutable               = $true
        MutationAllowed         = $false
        ReuseAllowed            = $false
        TamperDetected          = $false
        CrossTenantAllowed      = $false
        StaleSealAllowed        = $false

        CreatedAtUtc            = $now

        RawSecret               = $null
        RawCredential           = $null
    }

    $records += $record

    Save-GlobalRecoverySealRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "GLOBAL_SECURITY_SEAL_CREATED"
        SealId = $sealId
        SecuritySealHash = $sealHash
    }
}

function Test-GlobalRecoverySecuritySeal {

    param(
        [Parameter(Mandatory)]
        [string]$SealId
    )

    $records = @(Get-GlobalRecoverySealRecords)

    foreach ($record in $records) {

        if ($record.SealId -ne $SealId) {
            continue
        }

        if ($record.SealStatus -ne "SEALED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "SEAL_STATUS_INVALID"
            }
        }

        if ($record.PermanentSeal -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "PERMANENT_SEAL_MISSING"
            }
        }

        if ($record.Immutable -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "SEAL_NOT_IMMUTABLE"
            }
        }

        if ($record.MutationAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "SEAL_MUTATION_ALLOWED"
            }
        }

        if ($record.ReuseAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "SEAL_REUSE_ALLOWED"
            }
        }

        if ($record.TamperDetected -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "SEAL_TAMPER_DETECTED"
            }
        }

        if ($record.CrossTenantAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_TENANT_ALLOWED"
            }
        }

        if ($record.StaleSealAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "STALE_SEAL_ALLOWED"
            }
        }

        return [pscustomobject]@{
            Allowed = $true
            Decision = "ALLOW"
            Code = "GLOBAL_SECURITY_SEAL_VALID"
        }
    }

    return [pscustomobject]@{
        Allowed = $false
        Decision = "BLOCK"
        Code = "SEAL_NOT_FOUND"
    }
}

function Test-GlobalRecoverySealIntegrity {

    $records = @(Get-GlobalRecoverySealRecords)

    foreach ($record in $records) {

        $chainState = (
            "GLOBAL_CONSISTENT=" + $record.GlobalConsistent + "|" +
            "FINALIZED=" + $record.Finalized + "|" +
            "PERMANENT_LOCK=" + $record.PermanentLock + "|" +
            "AUDIT_INTEGRITY=" + $record.AuditIntegrity + "|" +
            "FINAL_ENFORCEMENT=" + $record.FinalEnforcement + "|" +
            "ANTI_REPLAY=" + $record.AntiReplayValid + "|" +
            "TENANT_ISOLATION=" + $record.TenantIsolationValid + "|" +
            "REVOCATION=" + $record.RevocationValid + "|" +
            "REVOCATION_SYNC=" + $record.RevocationSyncValid + "|" +
            "CONFLICT_RESOLVED=" + $record.ConflictResolved + "|" +
            "CONFLICT_CLOSED=" + $record.ConflictClosed + "|" +
            "EVIDENCE_VALID=" + $record.EvidenceValid
        )

        $canonical = (
            $record.SealId + "|" +
            $record.GlobalCheckId + "|" +
            $record.FinalizationId + "|" +
            $record.FinalizationEventId + "|" +
            $record.EnforcementId + "|" +
            $record.ConsumptionId + "|" +
            $record.AuthorizationId + "|" +
            $record.ExecutionId + "|" +
            $record.ConflictId + "|" +
            $record.ClosureId + "|" +
            $record.EvidenceId + "|" +
            $record.TenantId + "|" +
            $record.ClientId + "|" +
            $record.ProjectId + "|" +
            $record.UserId + "|" +
            $record.WorkerId + "|" +
            $chainState + "|" +
            $record.SealNonce + "|" +
            $record.CreatedAtUtc
        )

        $expectedHash = Get-GlobalRecoverySealHash `
            -Value $canonical

        if ($record.SecuritySealHash -ne $expectedHash) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "SECURITY_SEAL_HASH_INVALID"
            }
        }

        $flagsValid = (
            $record.GlobalConsistent -eq $true -and
            $record.Finalized -eq $true -and
            $record.PermanentLock -eq $true -and
            $record.AuditIntegrity -eq $true -and
            $record.FinalEnforcement -eq $true -and
            $record.AntiReplayValid -eq $true -and
            $record.TenantIsolationValid -eq $true -and
            $record.RevocationValid -eq $true -and
            $record.RevocationSyncValid -eq $true -and
            $record.ConflictResolved -eq $true -and
            $record.ConflictClosed -eq $true -and
            $record.EvidenceValid -eq $true
        )

        if (-not $flagsValid) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "GLOBAL_SEAL_CHAIN_INCOMPLETE"
            }
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "GLOBAL_SECURITY_SEAL_INTEGRITY_VALID"
    }
}

function Test-GlobalRecoverySealScope {

    param(
        [Parameter(Mandatory)][string]$SealId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$ExecutionId
    )

    $records = @(Get-GlobalRecoverySealRecords)

    foreach ($record in $records) {

        if ($record.SealId -ne $SealId) {
            continue
        }

        if ($record.TenantId -ne $TenantId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_TENANT_SEAL"
            }
        }

        if ($record.ClientId -ne $ClientId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_CLIENT_SEAL"
            }
        }

        if ($record.ProjectId -ne $ProjectId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_PROJECT_SEAL"
            }
        }

        if ($record.ExecutionId -ne $ExecutionId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_EXECUTION_SEAL"
            }
        }

        return [pscustomobject]@{
            Allowed = $true
            Decision = "ALLOW"
            Code = "GLOBAL_SEAL_SCOPE_VALID"
        }
    }

    return [pscustomobject]@{
        Allowed = $false
        Decision = "BLOCK"
        Code = "SEAL_NOT_FOUND"
    }
}

function Reset-GlobalRecoverySeal {

    Save-GlobalRecoverySealRecords
}
