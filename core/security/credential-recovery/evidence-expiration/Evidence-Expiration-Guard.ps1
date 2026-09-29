#Requires -Version 5.1
$ErrorActionPreference = "Stop"

# ============================================================
# 8A-45
# EVIDENCE RETENTION EXPIRATION & LEGAL-HOLD
#
# Compatible with the 8A-44 retention contract.
# 8A-44 contract preserved:
# EvidenceId / SealId / EvidenceHash / TenantId / ClientId /
# ProjectId / ExecutionId / EvidenceStatus / PermanentEvidence /
# ImmutableEvidence / IntegrityValid / RetentionId /
# RetentionState / AvailabilityState / DeletionAllowed /
# MutationAllowed / RewriteAllowed / PrematureExpiry /
# RetentionBypass / Decision
# ============================================================

$ConfigPath = Join-Path $PSScriptRoot "config.json"
$StateDir   = Join-Path $PSScriptRoot "state"
$StatePath  = Join-Path $StateDir "expiration.json"

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

function Get-EvidenceExpirationConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "EVIDENCE_EXPIRATION_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $ConfigPath -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "EVIDENCE_EXPIRATION_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-EvidenceExpirationRecords {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return @()
    }

    $raw = Get-Content -LiteralPath $StatePath -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $data = $raw | ConvertFrom-Json

    if ($null -eq $data) {
        return @()
    }

    return @($data)
}

function Save-EvidenceExpirationRecords {
    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-EvidenceExpirationConfig

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "EVIDENCE_EXPIRATION_RECORD_LIMIT"
    }

    if ($Records.Count -eq 0) {
        Set-Content -LiteralPath $StatePath -Value "[]" -Encoding UTF8
        return
    }

    $json = ConvertTo-Json -InputObject @($Records) -Depth 50

    $tmp = "$StatePath.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8

    Move-Item -LiteralPath $tmp -Destination $StatePath -Force
}

function Get-EvidenceExpirationHash {
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

function New-EvidenceExpirationId {
    return "EXPIRATION-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Get-EvidenceExpirationRegistrationCanonical {
    param([Parameter(Mandatory)]$Record)

    return (
        [string]$Record.ExpirationId + "|" +
        [string]$Record.RetentionId + "|" +
        [string]$Record.EvidenceId + "|" +
        [string]$Record.SealId + "|" +
        [string]$Record.EvidenceHash + "|" +
        [string]$Record.TenantId + "|" +
        [string]$Record.ClientId + "|" +
        [string]$Record.ProjectId + "|" +
        [string]$Record.ExecutionId + "|" +
        [string]$Record.EvidenceStatus + "|" +
        [string]$Record.PermanentEvidence + "|" +
        [string]$Record.ImmutableEvidence + "|" +
        [string]$Record.IntegrityValid + "|" +
        [string]$Record.RetentionPeriodSeconds + "|" +
        [string]$Record.CreatedAtUtc + "|" +
        [string]$Record.ExpiresAtUtc
    )
}

function Get-EvidenceExpirationStateCanonical {
    param([Parameter(Mandatory)]$Record)

    $holdReason = ""
    $holdActor  = ""
    $holdAt     = ""
    $expiredAt  = ""
    $reason     = ""
    $actor      = ""

    if ($null -ne $Record.LegalHoldReason) { $holdReason = [string]$Record.LegalHoldReason }
    if ($null -ne $Record.LegalHoldActor)  { $holdActor  = [string]$Record.LegalHoldActor }
    if ($null -ne $Record.LegalHoldAtUtc)  { $holdAt     = [string]$Record.LegalHoldAtUtc }
    if ($null -ne $Record.ExpiredAtUtc)    { $expiredAt  = [string]$Record.ExpiredAtUtc }
    if ($null -ne $Record.ExpirationReason) { $reason = [string]$Record.ExpirationReason }
    if ($null -ne $Record.ExpirationActor)  { $actor  = [string]$Record.ExpirationActor }

    return (
        [string]$Record.ExpirationId + "|" +
        [string]$Record.RetentionState + "|" +
        [string]$Record.AvailabilityState + "|" +
        [string]$Record.LegalHold + "|" +
        $holdReason + "|" +
        $holdActor + "|" +
        $holdAt + "|" +
        [string]$Record.PrematureExpiry + "|" +
        [string]$Record.ExpirationDecision + "|" +
        [string]$Record.Expired + "|" +
        $expiredAt + "|" +
        [string]$Record.DeletionAllowed + "|" +
        [string]$Record.MutationAllowed + "|" +
        [string]$Record.RewriteAllowed + "|" +
        [string]$Record.RetentionBypass + "|" +
        $reason + "|" +
        $actor
    )
}

function Update-EvidenceExpirationStateHash {
    param([Parameter(Mandatory)]$Record)

    return Get-EvidenceExpirationHash (
        Get-EvidenceExpirationStateCanonical -Record $Record
    )
}

function Get-EvidenceExpirationRegistrationHash {
    param([Parameter(Mandatory)]$Record)

    return Get-EvidenceExpirationHash (
        Get-EvidenceExpirationRegistrationCanonical -Record $Record
    )
}

function Find-EvidenceExpirationRecord {
    param(
        [Parameter(Mandatory)]
        [string]$ExpirationId
    )

    foreach ($record in @(Get-EvidenceExpirationRecords)) {
        if ([string]$record.ExpirationId -eq $ExpirationId) {
            return $record
        }
    }

    return $null
}

function Find-EvidenceExpirationByRetentionId {
    param(
        [Parameter(Mandatory)]
        [string]$RetentionId
    )

    foreach ($record in @(Get-EvidenceExpirationRecords)) {
        if ([string]$record.RetentionId -eq $RetentionId) {
            return $record
        }
    }

    return $null
}

function Assert-EvidenceExpirationRegistrationIntegrity {
    param([Parameter(Mandatory)]$Record)

    $expected = Get-EvidenceExpirationRegistrationHash -Record $Record

    if ([string]$Record.RegistrationHash -ne $expected) {
        throw "EVIDENCE_EXPIRATION_REGISTRATION_HASH_INVALID"
    }

    return $true
}

function Assert-EvidenceExpirationStateIntegrity {
    param([Parameter(Mandatory)]$Record)

    $expected = Update-EvidenceExpirationStateHash -Record $Record

    if ([string]$Record.StateHash -ne $expected) {
        throw "EVIDENCE_EXPIRATION_STATE_HASH_INVALID"
    }

    return $true
}

function Assert-EvidenceExpirationIntegrity {
    param([Parameter(Mandatory)]$Record)

    Assert-EvidenceExpirationRegistrationIntegrity -Record $Record | Out-Null
    Assert-EvidenceExpirationStateIntegrity -Record $Record | Out-Null

    return $true
}

function Register-EvidenceExpiration {
    param(
        [Parameter(Mandatory)][string]$EvidenceId,
        [Parameter(Mandatory)][string]$SealId,
        [Parameter(Mandatory)][string]$EvidenceHash,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$ExecutionId,
        [Parameter(Mandatory)][string]$EvidenceStatus,
        [Parameter(Mandatory)][bool]$PermanentEvidence,
        [Parameter(Mandatory)][bool]$ImmutableEvidence,
        [Parameter(Mandatory)][bool]$IntegrityValid,
        [Parameter(Mandatory)][string]$RetentionId,
        [Parameter(Mandatory)][int64]$RetentionPeriodSeconds,
        [Parameter(Mandatory)][datetime]$ExpiresAtUtc
    )

    $config = Get-EvidenceExpirationConfig

    if (-not $config.enabled) { throw "EVIDENCE_EXPIRATION_DISABLED" }
    if (-not $config.expirationEnabled) { throw "EXPIRATION_DISABLED" }

    $required = @(
        $EvidenceId,$SealId,$EvidenceHash,$TenantId,$ClientId,
        $ProjectId,$ExecutionId,$EvidenceStatus,$RetentionId
    )

    foreach ($value in $required) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) {
            throw "RETENTION_FIELD_REQUIRED"
        }
    }

    if (-not $PermanentEvidence) { throw "PERMANENT_EVIDENCE_REQUIRED" }
    if (-not $ImmutableEvidence) { throw "IMMUTABLE_EVIDENCE_REQUIRED" }
    if (-not $IntegrityValid) { throw "EVIDENCE_INTEGRITY_REQUIRED" }
    if ($EvidenceStatus -ne "VALID") { throw "EVIDENCE_STATUS_INVALID" }

    if ($RetentionPeriodSeconds -le 0) {
        throw "RETENTION_PERIOD_REQUIRED"
    }

    if ($ExpiresAtUtc.Kind -eq [DateTimeKind]::Unspecified) {
        $ExpiresAtUtc = [DateTime]::SpecifyKind($ExpiresAtUtc,[DateTimeKind]::Utc)
    }

    $records = @(Get-EvidenceExpirationRecords)

    foreach ($existing in $records) {
        if ([string]$existing.RetentionId -eq $RetentionId) {
            throw "EVIDENCE_EXPIRATION_ALREADY_REGISTERED"
        }
    }

    $now = (Get-Date).ToUniversalTime().ToString("o")

    $record = [pscustomobject][ordered]@{
        ExpirationId          = New-EvidenceExpirationId
        RetentionId           = $RetentionId

        EvidenceId            = $EvidenceId
        SealId                = $SealId
        EvidenceHash          = $EvidenceHash

        TenantId              = $TenantId
        ClientId              = $ClientId
        ProjectId             = $ProjectId
        ExecutionId           = $ExecutionId

        EvidenceStatus        = $EvidenceStatus
        PermanentEvidence     = $PermanentEvidence
        ImmutableEvidence     = $ImmutableEvidence
        IntegrityValid        = $IntegrityValid

        RetentionState        = "RETAINED"
        AvailabilityState     = "AVAILABLE"

        RetentionPeriodSeconds= $RetentionPeriodSeconds
        CreatedAtUtc          = $now
        RetainedAtUtc         = $now
        ExpiresAtUtc          = $ExpiresAtUtc.ToUniversalTime().ToString("o")

        LegalHold             = $false
        LegalHoldReason       = ""
        LegalHoldActor        = ""
        LegalHoldAtUtc        = ""

        PrematureExpiry       = $false
        ExpirationDecision    = "ALLOW"
        Expired               = $false
        ExpiredAtUtc          = ""

        DeletionAllowed       = $false
        MutationAllowed       = $false
        RewriteAllowed        = $false
        RetentionBypass       = $false

        ExpirationReason      = ""
        ExpirationActor       = ""

        RawSecret             = $null
        RawCredential         = $null

        RegistrationHash      = ""
        StateHash             = ""
    }

    $record.RegistrationHash = Get-EvidenceExpirationRegistrationHash -Record $record
    $record.StateHash = Update-EvidenceExpirationStateHash -Record $record

    $records += $record
    Save-EvidenceExpirationRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "EVIDENCE_EXPIRATION_REGISTERED"
        ExpirationId = $record.ExpirationId
        RetentionId = $record.RetentionId
        RetentionState = $record.RetentionState
        AvailabilityState = $record.AvailabilityState
    }
}

function Set-EvidenceLegalHold {
    param(
        [Parameter(Mandatory)][string]$ExpirationId,
        [Parameter(Mandatory)][string]$Actor,
        [Parameter(Mandatory)][string]$Reason
    )

    $config = Get-EvidenceExpirationConfig

    if (-not $config.legalHoldEnabled) {
        throw "LEGAL_HOLD_DISABLED"
    }

    if ([string]::IsNullOrWhiteSpace($Actor)) {
        throw "LEGAL_HOLD_ACTOR_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        throw "LEGAL_HOLD_REASON_REQUIRED"
    }

    $records = @(Get-EvidenceExpirationRecords)
    $target = $null
    $index = -1

    for ($i=0; $i -lt $records.Count; $i++) {
        if ([string]$records[$i].ExpirationId -eq $ExpirationId) {
            $target = $records[$i]
            $index = $i
            break
        }
    }

    if ($null -eq $target) {
        throw "EXPIRATION_RECORD_NOT_FOUND"
    }

    Assert-EvidenceExpirationIntegrity -Record $target | Out-Null

    if ([string]$target.RetentionState -eq "EXPIRED") {
        throw "EXPIRED_EVIDENCE_CANNOT_BE_HELD"
    }

    $target.LegalHold = $true
    $target.LegalHoldReason = $Reason
    $target.LegalHoldActor = $Actor
    $target.LegalHoldAtUtc = (Get-Date).ToUniversalTime().ToString("o")

    $target.StateHash = Update-EvidenceExpirationStateHash -Record $target

    $records[$index] = $target
    Save-EvidenceExpirationRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "LEGAL_HOLD_APPLIED"
        ExpirationId = $ExpirationId
        LegalHold = $true
    }
}

function Expire-EvidenceAtTime {
    param(
        [Parameter(Mandatory)][string]$ExpirationId,
        [Parameter(Mandatory)][string]$Actor,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][datetime]$NowUtc
    )

    $config = Get-EvidenceExpirationConfig

    if (-not $config.enabled) { throw "EVIDENCE_EXPIRATION_DISABLED" }
    if (-not $config.expirationEnabled) { throw "EXPIRATION_DISABLED" }

    if ([string]::IsNullOrWhiteSpace($Actor)) {
        throw "EXPIRATION_ACTOR_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        throw "EXPIRATION_REASON_REQUIRED"
    }

    if ($NowUtc.Kind -eq [DateTimeKind]::Unspecified) {
        $NowUtc = [DateTime]::SpecifyKind($NowUtc,[DateTimeKind]::Utc)
    }

    $records = @(Get-EvidenceExpirationRecords)
    $target = $null
    $index = -1

    for ($i=0; $i -lt $records.Count; $i++) {
        if ([string]$records[$i].ExpirationId -eq $ExpirationId) {
            $target = $records[$i]
            $index = $i
            break
        }
    }

    if ($null -eq $target) {
        throw "EXPIRATION_RECORD_NOT_FOUND"
    }

    # READ-ONLY GUARDS FIRST.
    Assert-EvidenceExpirationIntegrity -Record $target | Out-Null

    if ([string]$target.RetentionState -ne "RETAINED") {
        throw "EVIDENCE_NOT_RETAINABLE"
    }

    if ([string]$target.AvailabilityState -ne "AVAILABLE") {
        throw "EVIDENCE_UNAVAILABLE"
    }

    $comparisonNow = $NowUtc.ToUniversalTime()
    $expiresAt = ([DateTime]$target.ExpiresAtUtc).ToUniversalTime()

    # Pre-expiration: zero mutation.
    if ($comparisonNow -lt $expiresAt) {
        throw "PREMATURE_EXPIRATION_BLOCKED"
    }

    # Legal Hold: zero mutation.
    if ([bool]$target.LegalHold) {
        throw "LEGAL_HOLD_BLOCKS_EXPIRATION"
    }

    # Only now is mutation permitted.
    $target.RetentionState = "EXPIRED"
    $target.AvailabilityState = "AVAILABLE"

    $target.ExpirationDecision = "BLOCK"
    $target.Expired = $true
    $target.ExpiredAtUtc = $comparisonNow.ToString("o")

    $target.PrematureExpiry = $false
    $target.DeletionAllowed = $false
    $target.MutationAllowed = $false
    $target.RewriteAllowed = $false
    $target.RetentionBypass = $false

    $target.ExpirationReason = $Reason
    $target.ExpirationActor = $Actor

    $target.StateHash = Update-EvidenceExpirationStateHash -Record $target

    $records[$index] = $target
    Save-EvidenceExpirationRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "BLOCK"
        Code = "EVIDENCE_EXPIRED"
        ExpirationId = $ExpirationId
        RetentionState = "EXPIRED"
        AvailabilityState = "AVAILABLE"
    }
}

function Test-EvidenceExpiration {
    param(
        [Parameter(Mandatory)][string]$ExpirationId
    )

    $record = Find-EvidenceExpirationRecord -ExpirationId $ExpirationId

    if ($null -eq $record) {
        throw "EXPIRATION_RECORD_NOT_FOUND"
    }

    Assert-EvidenceExpirationIntegrity -Record $record | Out-Null

    return [pscustomobject]@{
        Allowed = ($record.RetentionState -eq "RETAINED" -and $record.LegalHold -ne $true)
        Decision = $record.ExpirationDecision
        Code = $(if ($record.RetentionState -eq "EXPIRED") { "EVIDENCE_EXPIRED" } elseif ($record.LegalHold -eq $true) { "LEGAL_HOLD_ACTIVE" } else { "SEAL_EVIDENCE_RETAINED" })
        ExpirationId = $record.ExpirationId
        RetentionId = $record.RetentionId
        RetentionState = $record.RetentionState
        AvailabilityState = $record.AvailabilityState
        LegalHold = [bool]$record.LegalHold
    }
}

function Test-EvidenceExpirationIntegrity {
    $records = @(Get-EvidenceExpirationRecords)

    foreach ($record in $records) {
        Assert-EvidenceExpirationIntegrity -Record $record | Out-Null

        if ($record.DeletionAllowed -eq $true) {
            return [pscustomobject]@{ Allowed=$false; Decision="BLOCK"; Code="DELETION_ALLOWED" }
        }

        if ($record.MutationAllowed -eq $true) {
            return [pscustomobject]@{ Allowed=$false; Decision="BLOCK"; Code="MUTATION_ALLOWED" }
        }

        if ($record.RewriteAllowed -eq $true) {
            return [pscustomobject]@{ Allowed=$false; Decision="BLOCK"; Code="REWRITE_ALLOWED" }
        }

        if ($record.RetentionBypass -eq $true) {
            return [pscustomobject]@{ Allowed=$false; Decision="BLOCK"; Code="RETENTION_BYPASS" }
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "EVIDENCE_EXPIRATION_INTEGRITY_VALID"
    }
}

function Test-EvidenceExpirationScope {
    param(
        [Parameter(Mandatory)][string]$ExpirationId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$ExecutionId
    )

    $record = Find-EvidenceExpirationRecord -ExpirationId $ExpirationId

    if ($null -eq $record) {
        throw "EXPIRATION_RECORD_NOT_FOUND"
    }

    Assert-EvidenceExpirationIntegrity -Record $record | Out-Null

    if ($record.TenantId -ne $TenantId) {
        return [pscustomobject]@{Allowed=$false;Decision="BLOCK";Code="CROSS_TENANT_EXPIRATION"}
    }

    if ($record.ClientId -ne $ClientId) {
        return [pscustomobject]@{Allowed=$false;Decision="BLOCK";Code="CROSS_CLIENT_EXPIRATION"}
    }

    if ($record.ProjectId -ne $ProjectId) {
        return [pscustomobject]@{Allowed=$false;Decision="BLOCK";Code="CROSS_PROJECT_EXPIRATION"}
    }

    if ($record.ExecutionId -ne $ExecutionId) {
        return [pscustomobject]@{Allowed=$false;Decision="BLOCK";Code="CROSS_EXECUTION_EXPIRATION"}
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "EVIDENCE_EXPIRATION_SCOPE_VALID"
    }
}

function Reset-EvidenceExpiration {
    Save-EvidenceExpirationRecords -Records @()
}
