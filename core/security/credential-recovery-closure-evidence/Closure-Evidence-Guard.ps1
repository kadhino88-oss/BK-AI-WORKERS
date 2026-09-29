function Get-ClosureEvidenceConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "CLOSURE_EVIDENCE_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "CLOSURE_EVIDENCE_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-ClosureEvidenceRecords {

    $path = Join-Path $PSScriptRoot "state\evidence.json"

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

function Save-ClosureEvidenceRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-ClosureEvidenceConfig
    $path = Join-Path $PSScriptRoot "state\evidence.json"

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "CLOSURE_EVIDENCE_RECORD_LIMIT"
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

function Get-ClosureEvidenceHash {

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

function New-ClosureEvidenceId {

    return "EVIDENCE-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Write-ClosureEvidence {

    param(
        [Parameter(Mandatory)][string]$ConflictId,
        [Parameter(Mandatory)][string]$ResolutionId,
        [Parameter(Mandatory)][string]$ClosureId,
        [Parameter(Mandatory)][string]$EnforcementId,
        [Parameter(Mandatory)][string]$RecoveryId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$ExecutionId,
        [Parameter(Mandatory)][string]$ResolvedEnforcement,
        [Parameter(Mandatory)][string]$ResolvedConsumption,
        [Parameter(Mandatory)][string]$ResolvedAuthorization,
        [Parameter(Mandatory)][string]$ResolvedExecution,
        [Parameter(Mandatory)][string]$ClosureStatus,
        [Parameter(Mandatory)][string]$Actor
    )

    $config = Get-ClosureEvidenceConfig

    if (-not $config.enabled) {
        throw "CLOSURE_EVIDENCE_DISABLED"
    }

    if (-not $config.evidenceEnabled) {
        throw "EVIDENCE_DISABLED"
    }

    $required = @(
        $ConflictId
        $ResolutionId
        $ClosureId
        $EnforcementId
        $RecoveryId
        $TenantId
        $ClientId
        $ProjectId
        $ExecutionId
        $ResolvedEnforcement
        $ResolvedConsumption
        $ResolvedAuthorization
        $ResolvedExecution
        $ClosureStatus
        $Actor
    )

    foreach ($value in $required) {

        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "EVIDENCE_FIELD_REQUIRED"
        }
    }

    if ($ResolvedEnforcement -ne "REVOKED") {
        throw "EVIDENCE_ENFORCEMENT_NOT_REVOKED"
    }

    if ($ResolvedConsumption -ne "REVOKED") {
        throw "EVIDENCE_CONSUMPTION_NOT_REVOKED"
    }

    if ($ResolvedAuthorization -ne "REVOKED") {
        throw "EVIDENCE_AUTHORIZATION_NOT_REVOKED"
    }

    if ($ResolvedExecution -ne "BLOCKED") {
        throw "EVIDENCE_EXECUTION_NOT_BLOCKED"
    }

    if ($ClosureStatus -ne "CLOSED") {
        throw "EVIDENCE_CLOSURE_NOT_CLOSED"
    }

    $records = @(Get-ClosureEvidenceRecords)

    foreach ($existing in $records) {

        if ($existing.ClosureId -eq $ClosureId) {
            throw "CLOSURE_EVIDENCE_ALREADY_EXISTS"
        }
    }

    $prevHash = $config.genesisPrevHash

    if ($records.Count -gt 0) {
        $prevHash = $records[$records.Count - 1].EvidenceHash
    }

    $now = (Get-Date).ToUniversalTime().ToString("o")
    $evidenceId = New-ClosureEvidenceId

    $canonical = (
        $evidenceId + "|" +
        $ConflictId + "|" +
        $ResolutionId + "|" +
        $ClosureId + "|" +
        $EnforcementId + "|" +
        $RecoveryId + "|" +
        $TenantId + "|" +
        $ClientId + "|" +
        $ProjectId + "|" +
        $ExecutionId + "|" +
        $ResolvedEnforcement + "|" +
        $ResolvedConsumption + "|" +
        $ResolvedAuthorization + "|" +
        $ResolvedExecution + "|" +
        $ClosureStatus + "|" +
        $Actor + "|" +
        $now + "|" +
        $prevHash
    )

    $evidenceHash = Get-ClosureEvidenceHash `
        -Value $canonical

    $record = [pscustomobject][ordered]@{
        EvidenceId             = $evidenceId
        EvidenceHash           = $evidenceHash
        PreviousHash           = $prevHash

        ConflictId             = $ConflictId
        ResolutionId           = $ResolutionId
        ClosureId              = $ClosureId

        EnforcementId          = $EnforcementId
        RecoveryId             = $RecoveryId
        TenantId               = $TenantId
        ClientId               = $ClientId
        ProjectId              = $ProjectId
        ExecutionId            = $ExecutionId

        ResolvedEnforcement    = $ResolvedEnforcement
        ResolvedConsumption    = $ResolvedConsumption
        ResolvedAuthorization  = $ResolvedAuthorization
        ResolvedExecution      = $ResolvedExecution

        ClosureStatus          = $ClosureStatus
        Decision               = "BLOCK"

        Immutable              = $true
        AppendOnly             = $true
        PermanentEvidence      = $true
        MutationAllowed        = $false
        DeletionAllowed        = $false
        RewriteAllowed         = $false

        Actor                  = $Actor
        CreatedAtUtc           = $now

        RawSecret              = $null
        RawCredential          = $null
    }

    $records += $record

    Save-ClosureEvidenceRecords `
        -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "BLOCK"
        Code = "CLOSURE_EVIDENCE_WRITTEN"
        EvidenceId = $evidenceId
    }
}

function Test-ClosureEvidenceIntegrity {

    $config = Get-ClosureEvidenceConfig
    $records = @(Get-ClosureEvidenceRecords)

    if ($records.Count -eq 0) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "EVIDENCE_EMPTY"
        }
    }

    $expectedPreviousHash = $config.genesisPrevHash

    foreach ($record in $records) {

        if ($record.PreviousHash -ne $expectedPreviousHash) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "EVIDENCE_CHAIN_BROKEN"
                EvidenceId = $record.EvidenceId
            }
        }

        $canonical = (
            $record.EvidenceId + "|" +
            $record.ConflictId + "|" +
            $record.ResolutionId + "|" +
            $record.ClosureId + "|" +
            $record.EnforcementId + "|" +
            $record.RecoveryId + "|" +
            $record.TenantId + "|" +
            $record.ClientId + "|" +
            $record.ProjectId + "|" +
            $record.ExecutionId + "|" +
            $record.ResolvedEnforcement + "|" +
            $record.ResolvedConsumption + "|" +
            $record.ResolvedAuthorization + "|" +
            $record.ResolvedExecution + "|" +
            $record.ClosureStatus + "|" +
            $record.Actor + "|" +
            $record.CreatedAtUtc + "|" +
            $record.PreviousHash
        )

        $expectedHash = Get-ClosureEvidenceHash `
            -Value $canonical

        if ($record.EvidenceHash -ne $expectedHash) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "EVIDENCE_HASH_INVALID"
                EvidenceId = $record.EvidenceId
            }
        }

        if ($record.Immutable -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "EVIDENCE_NOT_IMMUTABLE"
            }
        }

        if ($record.AppendOnly -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "EVIDENCE_NOT_APPEND_ONLY"
            }
        }

        if ($record.PermanentEvidence -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "PERMANENT_EVIDENCE_MISSING"
            }
        }

        if ($record.MutationAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "EVIDENCE_MUTATION_ALLOWED"
            }
        }

        if ($record.DeletionAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "EVIDENCE_DELETION_ALLOWED"
            }
        }

        if ($record.RewriteAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "EVIDENCE_REWRITE_ALLOWED"
            }
        }

        $expectedPreviousHash = $record.EvidenceHash
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "CLOSURE_EVIDENCE_INTEGRITY_VALID"
        EvidenceCount = $records.Count
    }
}

function Test-ClosureEvidenceBinding {

    param(
        [Parameter(Mandatory)][string]$EvidenceId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ExecutionId
    )

    $records = @(Get-ClosureEvidenceRecords)

    foreach ($record in $records) {

        if ($record.EvidenceId -ne $EvidenceId) {
            continue
        }

        if ($record.TenantId -ne $TenantId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_TENANT_EVIDENCE"
            }
        }

        if ($record.ExecutionId -ne $ExecutionId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_EXECUTION_EVIDENCE"
            }
        }

        return [pscustomobject]@{
            Allowed = $true
            Decision = "ALLOW"
            Code = "CLOSURE_EVIDENCE_SCOPE_VALID"
        }
    }

    return [pscustomobject]@{
        Allowed = $false
        Decision = "BLOCK"
        Code = "EVIDENCE_NOT_FOUND"
    }
}

function Test-ClosureEvidenceState {

    param(
        [Parameter(Mandatory)]
        [string]$EvidenceId
    )

    $records = @(Get-ClosureEvidenceRecords)

    foreach ($record in $records) {

        if ($record.EvidenceId -ne $EvidenceId) {
            continue
        }

        if ($record.ClosureStatus -ne "CLOSED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CLOSURE_NOT_CLOSED"
            }
        }

        if ($record.ResolvedEnforcement -ne "REVOKED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "ENFORCEMENT_NOT_REVOKED"
            }
        }

        if ($record.ResolvedConsumption -ne "REVOKED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CONSUMPTION_NOT_REVOKED"
            }
        }

        if ($record.ResolvedAuthorization -ne "REVOKED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "AUTHORIZATION_NOT_REVOKED"
            }
        }

        if ($record.ResolvedExecution -ne "BLOCKED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "EXECUTION_NOT_BLOCKED"
            }
        }

        return [pscustomobject]@{
            Allowed = $true
            Decision = "BLOCK"
            Code = "CLOSURE_EVIDENCE_STATE_VALID"
        }
    }

    return [pscustomobject]@{
        Allowed = $false
        Decision = "BLOCK"
        Code = "EVIDENCE_NOT_FOUND"
    }
}

function Reset-ClosureEvidence {

    Save-ClosureEvidenceRecords
}
