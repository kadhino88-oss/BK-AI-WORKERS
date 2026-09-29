function Get-RevocationConflictConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "REVOCATION_CONFLICT_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "REVOCATION_CONFLICT_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-RevocationConflictRecords {

    $path = Join-Path $PSScriptRoot "state\conflicts.json"

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

function Save-RevocationConflictRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-RevocationConflictConfig
    $path = Join-Path $PSScriptRoot "state\conflicts.json"

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "REVOCATION_CONFLICT_RECORD_LIMIT"
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

function Get-RevocationConflictHash {

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

function New-RevocationConflictId {

    return "CONFLICT-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Register-RevocationConflict {

    param(
        [Parameter(Mandatory)][string]$EnforcementId,
        [Parameter(Mandatory)][string]$RecoveryId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ExecutionId,

        [Parameter(Mandatory)][string]$StateAEnforcement,
        [Parameter(Mandatory)][string]$StateAConsumption,
        [Parameter(Mandatory)][string]$StateAAuthorization,
        [Parameter(Mandatory)][string]$StateAExecution,

        [Parameter(Mandatory)][string]$StateBEnforcement,
        [Parameter(Mandatory)][string]$StateBConsumption,
        [Parameter(Mandatory)][string]$StateBAuthorization,
        [Parameter(Mandatory)][string]$StateBExecution
    )

    $config = Get-RevocationConflictConfig

    if (-not $config.enabled) {
        throw "CONFLICT_GUARD_DISABLED"
    }

    $required = @(
        $EnforcementId
        $RecoveryId
        $TenantId
        $ExecutionId
        $StateAEnforcement
        $StateAConsumption
        $StateAAuthorization
        $StateAExecution
        $StateBEnforcement
        $StateBConsumption
        $StateBAuthorization
        $StateBExecution
    )

    foreach ($value in $required) {

        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "CONFLICT_BINDING_REQUIRED"
        }
    }

    $records = @(Get-RevocationConflictRecords)

    foreach ($existing in $records) {

        if (
            $existing.EnforcementId -eq $EnforcementId -and
            $existing.ExecutionId -eq $ExecutionId
        ) {

            throw "CONFLICT_RECORD_ALREADY_REGISTERED"
        }
    }

    $sameIdentity = (
        ($EnforcementId -eq $existing.EnforcementId)
    )

    $statesAgree = (
        $StateAEnforcement -eq $StateBEnforcement -and
        $StateAConsumption -eq $StateBConsumption -and
        $StateAAuthorization -eq $StateBAuthorization -and
        $StateAExecution -eq $StateBExecution
    )

    $conflictDetected = -not $statesAgree

    $now = (Get-Date).ToUniversalTime().ToString("o")
    $conflictId = New-RevocationConflictId

    $canonical = (
        $conflictId + "|" +
        $EnforcementId + "|" +
        $RecoveryId + "|" +
        $TenantId + "|" +
        $ExecutionId + "|" +
        $StateAEnforcement + "|" +
        $StateAConsumption + "|" +
        $StateAAuthorization + "|" +
        $StateAExecution + "|" +
        $StateBEnforcement + "|" +
        $StateBConsumption + "|" +
        $StateBAuthorization + "|" +
        $StateBExecution + "|" +
        $now
    )

    $hash = Get-RevocationConflictHash -Value $canonical

    $record = [pscustomobject][ordered]@{
        ConflictId              = $conflictId
        IntegrityHash           = $hash
        EnforcementId           = $EnforcementId
        RecoveryId              = $RecoveryId
        TenantId                = $TenantId
        ExecutionId             = $ExecutionId

        StateAEnforcement       = $StateAEnforcement
        StateAConsumption       = $StateAConsumption
        StateAAuthorization     = $StateAAuthorization
        StateAExecution         = $StateAExecution

        StateBEnforcement       = $StateBEnforcement
        StateBConsumption       = $StateBConsumption
        StateBAuthorization     = $StateBAuthorization
        StateBExecution         = $StateBExecution

        ConflictDetected        = $conflictDetected
        ConflictType            = "NONE"

        ResolutionStatus        = "PENDING"
        ResolutionDecision      = "BLOCK"

        ResolvedEnforcement     = "UNKNOWN"
        ResolvedConsumption     = "UNKNOWN"
        ResolvedAuthorization   = "UNKNOWN"
        ResolvedExecution       = "UNKNOWN"

        SourceRevoked           = $false
        ExecutionBlocked        = $false

        ReactivationAllowed     = $false
        ReopenAllowed           = $false

        CreatedAtUtc            = $now
        ResolvedAtUtc           = $null
        ResolutionReason        = $null

        RawSecret               = $null
        RawCredential           = $null
    }

    if ($conflictDetected) {

        $record.ConflictType = "STATE_DIVERGENCE"
    }
    else {

        $record.ConflictType = "NO_CONFLICT"
    }

    $records += $record

    Save-RevocationConflictRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "BLOCK"
        Code = "REVOCATION_CONFLICT_REGISTERED"
        ConflictId = $conflictId
        ConflictDetected = $conflictDetected
    }
}

function Resolve-RevocationConflict {

    param(
        [Parameter(Mandatory)]
        [string]$ConflictId
    )

    $config = Get-RevocationConflictConfig

    if (-not $config.resolutionEnabled) {
        throw "CONFLICT_RESOLUTION_DISABLED"
    }

    $records = @(Get-RevocationConflictRecords)

    $record = $null
    $index = -1

    for ($i = 0; $i -lt $records.Count; $i++) {

        if ($records[$i].ConflictId -eq $ConflictId) {
            $record = $records[$i]
            $index = $i
            break
        }
    }

    if ($null -eq $record) {
        throw "CONFLICT_NOT_FOUND"
    }

    if (-not $record.ConflictDetected) {

        $record.ResolvedEnforcement = $record.StateAEnforcement
        $record.ResolvedConsumption = $record.StateAConsumption
        $record.ResolvedAuthorization = $record.StateAAuthorization
        $record.ResolvedExecution = $record.StateAExecution

        $record.SourceRevoked = (
            $record.ResolvedEnforcement -eq "REVOKED"
        )

        $record.ExecutionBlocked = (
            $record.ResolvedExecution -eq "BLOCKED"
        )

        if (
            $record.SourceRevoked -and
            $record.ExecutionBlocked
        ) {

            $record.ResolutionStatus = "RESOLVED"
            $record.ResolutionDecision = "ALLOW"
            $record.ResolutionReason = "CONSISTENT_REVOKED_BLOCKED_STATE"
        }
        else {

            $record.ResolutionStatus = "BLOCKED"
            $record.ResolutionDecision = "BLOCK"
            $record.ResolutionReason = "CONSISTENT_STATE_NOT_SAFE"
        }
    }
    else {

        # FAIL-CLOSED / REVOKED STATE WINS.
        $record.ResolvedEnforcement = "REVOKED"
        $record.ResolvedConsumption = "REVOKED"
        $record.ResolvedAuthorization = "REVOKED"
        $record.ResolvedExecution = "BLOCKED"

        $record.SourceRevoked = $true
        $record.ExecutionBlocked = $true

        $record.ResolutionStatus = "RESOLVED"
        $record.ResolutionDecision = "BLOCK"
        $record.ResolutionReason = "REVOKED_STATE_WINS_FAIL_CLOSED"
    }

    $record.ResolvedAtUtc = (Get-Date).ToUniversalTime().ToString("o")

    $records[$index] = $record

    Save-RevocationConflictRecords -Records $records

    return [pscustomobject]@{
        Allowed = (
            $record.ResolutionStatus -eq "RESOLVED"
        )
        Decision = $record.ResolutionDecision
        Code = "REVOCATION_CONFLICT_RESOLVED"
        ConflictId = $ConflictId
        ResolutionStatus = $record.ResolutionStatus
    }
}

function Test-RevocationConflictResolution {

    param(
        [Parameter(Mandatory)]
        [string]$ConflictId
    )

    $records = @(Get-RevocationConflictRecords)

    foreach ($record in $records) {

        if ($record.ConflictId -ne $ConflictId) {
            continue
        }

        if ($record.ResolutionStatus -ne "RESOLVED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CONFLICT_NOT_RESOLVED"
            }
        }

        if ($record.ResolvedEnforcement -ne "REVOKED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "ENFORCEMENT_RESOLUTION_INVALID"
            }
        }

        if ($record.ResolvedConsumption -ne "REVOKED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CONSUMPTION_RESOLUTION_INVALID"
            }
        }

        if ($record.ResolvedAuthorization -ne "REVOKED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "AUTHORIZATION_RESOLUTION_INVALID"
            }
        }

        if ($record.ResolvedExecution -ne "BLOCKED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "EXECUTION_RESOLUTION_INVALID"
            }
        }

        return [pscustomobject]@{
            Allowed = $true
            Decision = "BLOCK"
            Code = "REVOCATION_CONFLICT_RESOLUTION_VALID"
        }
    }

    return [pscustomobject]@{
        Allowed = $false
        Decision = "BLOCK"
        Code = "CONFLICT_NOT_FOUND"
    }
}

function Test-RevocationConflictIntegrity {

    $records = @(Get-RevocationConflictRecords)

    foreach ($record in $records) {

        $canonical = (
            $record.ConflictId + "|" +
            $record.EnforcementId + "|" +
            $record.RecoveryId + "|" +
            $record.TenantId + "|" +
            $record.ExecutionId + "|" +
            $record.StateAEnforcement + "|" +
            $record.StateAConsumption + "|" +
            $record.StateAAuthorization + "|" +
            $record.StateAExecution + "|" +
            $record.StateBEnforcement + "|" +
            $record.StateBConsumption + "|" +
            $record.StateBAuthorization + "|" +
            $record.StateBExecution + "|" +
            $record.CreatedAtUtc
        )

        $expectedHash = Get-RevocationConflictHash `
            -Value $canonical

        if ($record.IntegrityHash -ne $expectedHash) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CONFLICT_HASH_INVALID"
            }
        }

        if ($record.ReactivationAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "REACTIVATION_ALLOWED"
            }
        }

        if ($record.ReopenAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "REOPEN_ALLOWED"
            }
        }

        if (
            $record.ResolutionStatus -eq "RESOLVED" -and
            (
                $record.ResolvedEnforcement -ne "REVOKED" -or
                $record.ResolvedConsumption -ne "REVOKED" -or
                $record.ResolvedAuthorization -ne "REVOKED" -or
                $record.ResolvedExecution -ne "BLOCKED"
            )
        ) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "RESOLVED_STATE_DRIFT"
            }
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "REVOCATION_CONFLICT_INTEGRITY_VALID"
    }
}

function Test-RevocationConflictIsolation {

    param(
        [Parameter(Mandatory)]
        [string]$ConflictId,

        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$ExecutionId
    )

    $records = @(Get-RevocationConflictRecords)

    foreach ($record in $records) {

        if ($record.ConflictId -ne $ConflictId) {
            continue
        }

        if ($record.TenantId -ne $TenantId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_TENANT_CONFLICT"
            }
        }

        if ($record.ExecutionId -ne $ExecutionId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_EXECUTION_CONFLICT"
            }
        }

        return [pscustomobject]@{
            Allowed = $true
            Decision = "ALLOW"
            Code = "CONFLICT_SCOPE_VALID"
        }
    }

    return [pscustomobject]@{
        Allowed = $false
        Decision = "BLOCK"
        Code = "CONFLICT_NOT_FOUND"
    }
}

function Reset-RevocationConflict {

    Save-RevocationConflictRecords
}
