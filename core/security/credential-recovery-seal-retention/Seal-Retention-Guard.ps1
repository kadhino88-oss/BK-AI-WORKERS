function Get-SealRetentionConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "SEAL_RETENTION_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "SEAL_RETENTION_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-SealRetentionRecords {

    $path = Join-Path $PSScriptRoot "state/retention.json"

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

function Save-SealRetentionRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-SealRetentionConfig
    $path = Join-Path $PSScriptRoot "state/retention.json"

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "SEAL_RETENTION_RECORD_LIMIT"
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

function Get-SealRetentionHash {

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

function New-SealRetentionId {

    return "RETENTION-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Register-SealEvidenceRetention {

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
        [Parameter(Mandatory)][bool]$IntegrityValid
    )

    $config = Get-SealRetentionConfig

    if (-not $config.enabled) {
        throw "SEAL_RETENTION_DISABLED"
    }

    if (-not $config.retentionEnabled) {
        throw "RETENTION_DISABLED"
    }

    $required = @(
        $EvidenceId
        $SealId
        $EvidenceHash
        $TenantId
        $ClientId
        $ProjectId
        $ExecutionId
        $EvidenceStatus
    )

    foreach ($value in $required) {

        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "RETENTION_FIELD_REQUIRED"
        }
    }

    if (-not $PermanentEvidence) {
        throw "PERMANENT_EVIDENCE_REQUIRED"
    }

    if (-not $ImmutableEvidence) {
        throw "IMMUTABLE_EVIDENCE_REQUIRED"
    }

    if (-not $IntegrityValid) {
        throw "EVIDENCE_INTEGRITY_REQUIRED"
    }

    if ($EvidenceStatus -ne "VALID") {
        throw "EVIDENCE_STATUS_INVALID"
    }

    $records = @(Get-SealRetentionRecords)

    foreach ($existing in $records) {

        if ($existing.EvidenceId -eq $EvidenceId) {
            throw "EVIDENCE_RETENTION_ALREADY_REGISTERED"
        }
    }

    $now = (Get-Date).ToUniversalTime().ToString("o")
    $retentionId = New-SealRetentionId

    $canonical = (
        $retentionId + "|" +
        $EvidenceId + "|" +
        $SealId + "|" +
        $EvidenceHash + "|" +
        $TenantId + "|" +
        $ClientId + "|" +
        $ProjectId + "|" +
        $ExecutionId + "|" +
        $EvidenceStatus + "|" +
        $PermanentEvidence + "|" +
        $ImmutableEvidence + "|" +
        $IntegrityValid + "|" +
        $now
    )

    $retentionHash = Get-SealRetentionHash `
        -Value $canonical

    $record = [pscustomobject][ordered]@{
        RetentionId          = $retentionId
        RetentionHash        = $retentionHash

        EvidenceId           = $EvidenceId
        SealId               = $SealId
        EvidenceHash         = $EvidenceHash

        TenantId             = $TenantId
        ClientId             = $ClientId
        ProjectId            = $ProjectId
        ExecutionId          = $ExecutionId

        EvidenceStatus       = $EvidenceStatus
        PermanentEvidence    = $PermanentEvidence
        ImmutableEvidence    = $ImmutableEvidence
        IntegrityValid       = $IntegrityValid

        RetentionState       = "RETAINED"
        AvailabilityState    = "AVAILABLE"

        DeletionAllowed      = $false
        MutationAllowed      = $false
        RewriteAllowed       = $false
        PrematureExpiry      = $false
        RetentionBypass      = $false

        Decision             = "ALLOW"

        CreatedAtUtc         = $now
        RetainedAtUtc        = $now

        RawSecret            = $null
        RawCredential        = $null
    }

    $records += $record

    Save-SealRetentionRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "EVIDENCE_RETENTION_REGISTERED"
        RetentionId = $retentionId
        RetentionState = "RETAINED"
        AvailabilityState = "AVAILABLE"
    }
}

function Test-SealEvidenceRetention {

    param(
        [Parameter(Mandatory)]
        [string]$RetentionId
    )

    $records = @(Get-SealRetentionRecords)

    foreach ($record in $records) {

        if ($record.RetentionId -ne $RetentionId) {
            continue
        }

        if ($record.RetentionState -ne "RETAINED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "RETENTION_STATE_INVALID"
            }
        }

        if ($record.AvailabilityState -ne "AVAILABLE") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "EVIDENCE_UNAVAILABLE"
            }
        }

        if ($record.PermanentEvidence -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "PERMANENT_EVIDENCE_MISSING"
            }
        }

        if ($record.ImmutableEvidence -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "IMMUTABLE_EVIDENCE_MISSING"
            }
        }

        if ($record.IntegrityValid -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "EVIDENCE_INTEGRITY_INVALID"
            }
        }

        if ($record.DeletionAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "DELETION_ALLOWED"
            }
        }

        if ($record.MutationAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "MUTATION_ALLOWED"
            }
        }

        if ($record.RewriteAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "REWRITE_ALLOWED"
            }
        }

        if ($record.PrematureExpiry -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "PREMATURE_EXPIRY"
            }
        }

        if ($record.RetentionBypass -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "RETENTION_BYPASS"
            }
        }

        return [pscustomobject]@{
            Allowed = $true
            Decision = "ALLOW"
            Code = "SEAL_EVIDENCE_RETAINED"
        }
    }

    return [pscustomobject]@{
        Allowed = $false
        Decision = "BLOCK"
        Code = "RETENTION_NOT_FOUND"
    }
}

function Test-SealRetentionIntegrity {

    $records = @(Get-SealRetentionRecords)

    foreach ($record in $records) {

        $canonical = (
            $record.RetentionId + "|" +
            $record.EvidenceId + "|" +
            $record.SealId + "|" +
            $record.EvidenceHash + "|" +
            $record.TenantId + "|" +
            $record.ClientId + "|" +
            $record.ProjectId + "|" +
            $record.ExecutionId + "|" +
            $record.EvidenceStatus + "|" +
            $record.PermanentEvidence + "|" +
            $record.ImmutableEvidence + "|" +
            $record.IntegrityValid + "|" +
            $record.CreatedAtUtc
        )

        $expectedHash = Get-SealRetentionHash `
            -Value $canonical

        if ($record.RetentionHash -ne $expectedHash) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "RETENTION_HASH_INVALID"
            }
        }

        if ($record.DeletionAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "DELETION_ALLOWED"
            }
        }

        if ($record.MutationAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "MUTATION_ALLOWED"
            }
        }

        if ($record.RetentionBypass -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "RETENTION_BYPASS"
            }
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "SEAL_RETENTION_INTEGRITY_VALID"
    }
}

function Test-SealRetentionScope {

    param(
        [Parameter(Mandatory)][string]$RetentionId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$ExecutionId
    )

    $records = @(Get-SealRetentionRecords)

    foreach ($record in $records) {

        if ($record.RetentionId -ne $RetentionId) {
            continue
        }

        if ($record.TenantId -ne $TenantId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_TENANT_RETENTION"
            }
        }

        if ($record.ClientId -ne $ClientId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_CLIENT_RETENTION"
            }
        }

        if ($record.ProjectId -ne $ProjectId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_PROJECT_RETENTION"
            }
        }

        if ($record.ExecutionId -ne $ExecutionId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_EXECUTION_RETENTION"
            }
        }

        return [pscustomobject]@{
            Allowed = $true
            Decision = "ALLOW"
            Code = "SEAL_RETENTION_SCOPE_VALID"
        }
    }

    return [pscustomobject]@{
        Allowed = $false
        Decision = "BLOCK"
        Code = "RETENTION_NOT_FOUND"
    }
}

function Reset-SealRetention {

    Save-SealRetentionRecords
}
