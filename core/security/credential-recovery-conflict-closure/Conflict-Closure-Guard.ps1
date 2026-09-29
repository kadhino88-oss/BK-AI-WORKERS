function Get-ConflictClosureConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "CONFLICT_CLOSURE_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "CONFLICT_CLOSURE_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-ConflictClosureRecords {

    $path = Join-Path $PSScriptRoot "state\closures.json"

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

function Save-ConflictClosureRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-ConflictClosureConfig
    $path = Join-Path $PSScriptRoot "state\closures.json"

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "CONFLICT_CLOSURE_RECORD_LIMIT"
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

function Get-ConflictClosureHash {

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

function New-ConflictClosureId {

    return "CLOSURE-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Close-ResolvedRevocationConflict {

    param(
        [Parameter(Mandatory)][string]$ConflictId,
        [Parameter(Mandatory)][string]$EnforcementId,
        [Parameter(Mandatory)][string]$RecoveryId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ExecutionId,
        [Parameter(Mandatory)][string]$ResolvedEnforcement,
        [Parameter(Mandatory)][string]$ResolvedConsumption,
        [Parameter(Mandatory)][string]$ResolvedAuthorization,
        [Parameter(Mandatory)][string]$ResolvedExecution,
        [Parameter(Mandatory)][string]$ResolutionStatus
    )

    $config = Get-ConflictClosureConfig

    if (-not $config.enabled) {
        throw "CONFLICT_CLOSURE_DISABLED"
    }

    if (-not $config.closureEnabled) {
        throw "CLOSURE_DISABLED"
    }

    if (-not $config.immutableClosureEnabled) {
        throw "IMMUTABLE_CLOSURE_DISABLED"
    }

    if ($ResolutionStatus -ne "RESOLVED") {
        throw "CONFLICT_MUST_BE_RESOLVED"
    }

    if ($ResolvedEnforcement -ne "REVOKED") {
        throw "ENFORCEMENT_MUST_BE_REVOKED"
    }

    if ($ResolvedConsumption -ne "REVOKED") {
        throw "CONSUMPTION_MUST_BE_REVOKED"
    }

    if ($ResolvedAuthorization -ne "REVOKED") {
        throw "AUTHORIZATION_MUST_BE_REVOKED"
    }

    if ($ResolvedExecution -ne "BLOCKED") {
        throw "EXECUTION_MUST_BE_BLOCKED"
    }

    $required = @(
        $ConflictId
        $EnforcementId
        $RecoveryId
        $TenantId
        $ExecutionId
        $ResolvedEnforcement
        $ResolvedConsumption
        $ResolvedAuthorization
        $ResolvedExecution
    )

    foreach ($value in $required) {

        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "CLOSURE_BINDING_REQUIRED"
        }
    }

    $records = @(Get-ConflictClosureRecords)

    foreach ($existing in $records) {

        if ($existing.ConflictId -eq $ConflictId) {
            throw "CONFLICT_ALREADY_CLOSED"
        }
    }

    $now = (Get-Date).ToUniversalTime().ToString("o")
    $closureId = New-ConflictClosureId

    $canonical = (
        $closureId + "|" +
        $ConflictId + "|" +
        $EnforcementId + "|" +
        $RecoveryId + "|" +
        $TenantId + "|" +
        $ExecutionId + "|" +
        $ResolvedEnforcement + "|" +
        $ResolvedConsumption + "|" +
        $ResolvedAuthorization + "|" +
        $ResolvedExecution + "|" +
        $ResolutionStatus + "|" +
        $now
    )

    $integrityHash = Get-ConflictClosureHash `
        -Value $canonical

    $record = [pscustomobject][ordered]@{
        ClosureId              = $closureId
        IntegrityHash          = $integrityHash
        ConflictId             = $ConflictId
        EnforcementId          = $EnforcementId
        RecoveryId             = $RecoveryId
        TenantId               = $TenantId
        ExecutionId             = $ExecutionId

        ResolvedEnforcement    = $ResolvedEnforcement
        ResolvedConsumption    = $ResolvedConsumption
        ResolvedAuthorization  = $ResolvedAuthorization
        ResolvedExecution      = $ResolvedExecution
        ResolutionStatus       = $ResolutionStatus

        ClosureStatus          = "CLOSED"
        Decision               = "BLOCK"

        Immutable              = $true
        PermanentClosure       = $true
        ReopenAllowed          = $false
        MutationAllowed        = $false
        ReactivationAllowed    = $false
        ResolutionRewriteAllowed = $false

        SourceRevoked          = $true
        ExecutionBlocked       = $true

        CreatedAtUtc           = $now
        ClosedAtUtc            = $now

        RawSecret              = $null
        RawCredential          = $null
    }

    $records += $record

    Save-ConflictClosureRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "BLOCK"
        Code = "CONFLICT_CLOSED_IMMUTABLY"
        ClosureId = $closureId
        ClosureStatus = "CLOSED"
    }
}

function Test-ConflictClosure {

    param(
        [Parameter(Mandatory)]
        [string]$ClosureId
    )

    $records = @(Get-ConflictClosureRecords)

    foreach ($record in $records) {

        if ($record.ClosureId -ne $ClosureId) {
            continue
        }

        if ($record.ClosureStatus -ne "CLOSED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CLOSURE_STATUS_INVALID"
            }
        }

        if ($record.Immutable -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "IMMUTABILITY_MISSING"
            }
        }

        if ($record.PermanentClosure -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "PERMANENT_CLOSURE_MISSING"
            }
        }

        if ($record.ReopenAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "REOPEN_ALLOWED"
            }
        }

        if ($record.MutationAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "MUTATION_ALLOWED"
            }
        }

        if ($record.ReactivationAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "REACTIVATION_ALLOWED"
            }
        }

        if ($record.ResolutionRewriteAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "RESOLUTION_REWRITE_ALLOWED"
            }
        }

        if (
            $record.ResolvedEnforcement -ne "REVOKED" -or
            $record.ResolvedConsumption -ne "REVOKED" -or
            $record.ResolvedAuthorization -ne "REVOKED" -or
            $record.ResolvedExecution -ne "BLOCKED"
        ) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CLOSED_STATE_DRIFT"
            }
        }

        return [pscustomobject]@{
            Allowed = $true
            Decision = "BLOCK"
            Code = "CONFLICT_CLOSURE_VALID"
        }
    }

    return [pscustomobject]@{
        Allowed = $false
        Decision = "BLOCK"
        Code = "CLOSURE_NOT_FOUND"
    }
}

function Test-ConflictClosureIntegrity {

    $records = @(Get-ConflictClosureRecords)

    foreach ($record in $records) {

        $canonical = (
            $record.ClosureId + "|" +
            $record.ConflictId + "|" +
            $record.EnforcementId + "|" +
            $record.RecoveryId + "|" +
            $record.TenantId + "|" +
            $record.ExecutionId + "|" +
            $record.ResolvedEnforcement + "|" +
            $record.ResolvedConsumption + "|" +
            $record.ResolvedAuthorization + "|" +
            $record.ResolvedExecution + "|" +
            $record.ResolutionStatus + "|" +
            $record.CreatedAtUtc
        )

        $expectedHash = Get-ConflictClosureHash `
            -Value $canonical

        if ($record.IntegrityHash -ne $expectedHash) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CLOSURE_HASH_INVALID"
            }
        }

        if ($record.Immutable -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "IMMUTABILITY_INVALID"
            }
        }

        if ($record.PermanentClosure -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "PERMANENT_CLOSURE_INVALID"
            }
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "CONFLICT_CLOSURE_INTEGRITY_VALID"
    }
}

function Test-ConflictClosureIsolation {

    param(
        [Parameter(Mandatory)][string]$ClosureId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ExecutionId
    )

    $records = @(Get-ConflictClosureRecords)

    foreach ($record in $records) {

        if ($record.ClosureId -ne $ClosureId) {
            continue
        }

        if ($record.TenantId -ne $TenantId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_TENANT_CLOSURE"
            }
        }

        if ($record.ExecutionId -ne $ExecutionId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_EXECUTION_CLOSURE"
            }
        }

        return [pscustomobject]@{
            Allowed = $true
            Decision = "ALLOW"
            Code = "CLOSURE_SCOPE_VALID"
        }
    }

    return [pscustomobject]@{
        Allowed = $false
        Decision = "BLOCK"
        Code = "CLOSURE_NOT_FOUND"
    }
}

function Reset-ConflictClosure {

    Save-ConflictClosureRecords
}
