function Get-GlobalSealLifecycleConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "SEAL_LIFECYCLE_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "SEAL_LIFECYCLE_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-GlobalSealLifecycleRecords {

    $path = Join-Path $PSScriptRoot "state\lifecycle.json"

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

function Save-GlobalSealLifecycleRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-GlobalSealLifecycleConfig
    $path = Join-Path $PSScriptRoot "state\lifecycle.json"

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "SEAL_LIFECYCLE_RECORD_LIMIT"
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

function Get-GlobalSealLifecycleHash {

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

function New-GlobalSealLifecycleId {

    return "LIFE-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Register-GlobalSecuritySealLifecycle {

    param(
        [Parameter(Mandatory)][string]$SealId,
        [Parameter(Mandatory)][string]$SecuritySealHash,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$ExecutionId,
        [Parameter(Mandatory)][bool]$SealValid,
        [Parameter(Mandatory)][bool]$Immutable,
        [Parameter(Mandatory)][bool]$PermanentSeal
    )

    $config = Get-GlobalSealLifecycleConfig

    if (-not $config.enabled) {
        throw "SEAL_LIFECYCLE_DISABLED"
    }

    if (-not $config.lifecycleEnabled) {
        throw "LIFECYCLE_DISABLED"
    }

    if (-not $SealValid) {
        throw "SEAL_VALIDATION_REQUIRED"
    }

    if (-not $Immutable) {
        throw "SEAL_IMMUTABILITY_REQUIRED"
    }

    if (-not $PermanentSeal) {
        throw "PERMANENT_SEAL_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($SealId)) {
        throw "SEAL_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($SecuritySealHash)) {
        throw "SEAL_HASH_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw "TENANT_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        throw "CLIENT_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($ProjectId)) {
        throw "PROJECT_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "EXECUTION_ID_REQUIRED"
    }

    $records = @(Get-GlobalSealLifecycleRecords)

    foreach ($existing in $records) {

        if ($existing.SealId -eq $SealId) {
            throw "SEAL_LIFECYCLE_ALREADY_REGISTERED"
        }
    }

    $now = (Get-Date).ToUniversalTime().ToString("o")
    $lifecycleId = New-GlobalSealLifecycleId

    $canonical = (
        $lifecycleId + "|" +
        $SealId + "|" +
        $SecuritySealHash + "|" +
        $TenantId + "|" +
        $ClientId + "|" +
        $ProjectId + "|" +
        $ExecutionId + "|" +
        $now
    )

    $integrityHash = Get-GlobalSealLifecycleHash `
        -Value $canonical

    $record = [pscustomobject][ordered]@{
        LifecycleId       = $lifecycleId
        IntegrityHash     = $integrityHash

        SealId            = $SealId
        SecuritySealHash  = $SecuritySealHash

        TenantId          = $TenantId
        ClientId          = $ClientId
        ProjectId         = $ProjectId
        ExecutionId       = $ExecutionId

        SealValid         = $SealValid
        Immutable         = $Immutable
        PermanentSeal     = $PermanentSeal

        LifecycleState    = "SEALED"
        Decision          = "ALLOW"

        Revoked           = $false
        Closed            = $false
        Expired           = $false

        ReactivationAllowed = $false
        ReopenAllowed       = $false
        ReuseAllowed        = $false
        MutationAllowed     = $false

        CreatedAtUtc      = $now
        ActivatedAtUtc    = $null
        RevokedAtUtc      = $null
        ClosedAtUtc       = $null

        RevocationReason  = $null
        RevocationActor   = $null

        RawSecret         = $null
        RawCredential     = $null
    }

    $records += $record

    Save-GlobalSealLifecycleRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "SEAL_LIFECYCLE_REGISTERED"
        LifecycleId = $lifecycleId
        LifecycleState = "SEALED"
    }
}

function Activate-GlobalSecuritySeal {

    param(
        [Parameter(Mandatory)]
        [string]$LifecycleId
    )

    $records = @(Get-GlobalSealLifecycleRecords)

    $target = $null
    $index = -1

    for ($i = 0; $i -lt $records.Count; $i++) {

        if ($records[$i].LifecycleId -eq $LifecycleId) {

            $target = $records[$i]
            $index = $i
            break
        }
    }

    if ($null -eq $target) {
        throw "LIFECYCLE_NOT_FOUND"
    }

    if ($target.LifecycleState -ne "SEALED") {
        throw "SEAL_NOT_ACTIVATABLE"
    }

    $target.LifecycleState = "ACTIVE"
    $target.Decision = "ALLOW"
    $target.ActivatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")

    $records[$index] = $target

    Save-GlobalSealLifecycleRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "SEAL_ACTIVATED"
        LifecycleState = "ACTIVE"
    }
}

function Revoke-GlobalSecuritySeal {

    param(
        [Parameter(Mandatory)]
        [string]$LifecycleId,

        [Parameter(Mandatory)]
        [string]$Reason,

        [Parameter(Mandatory)]
        [string]$Actor
    )

    $config = Get-GlobalSealLifecycleConfig

    if (-not $config.revocationEnabled) {
        throw "SEAL_REVOCATION_DISABLED"
    }

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        throw "SEAL_REVOCATION_REASON_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Actor)) {
        throw "SEAL_REVOCATION_ACTOR_REQUIRED"
    }

    $records = @(Get-GlobalSealLifecycleRecords)

    $target = $null
    $index = -1

    for ($i = 0; $i -lt $records.Count; $i++) {

        if ($records[$i].LifecycleId -eq $LifecycleId) {

            $target = $records[$i]
            $index = $i
            break
        }
    }

    if ($null -eq $target) {
        throw "LIFECYCLE_NOT_FOUND"
    }

    if (
        $target.LifecycleState -eq "REVOKED" -or
        $target.LifecycleState -eq "CLOSED"
    ) {
        throw "SEAL_ALREADY_TERMINAL"
    }

    $now = (Get-Date).ToUniversalTime().ToString("o")

    $target.LifecycleState = "REVOKED"
    $target.Decision = "BLOCK"
    $target.Revoked = $true
    $target.Expired = $false
    $target.RevokedAtUtc = $now
    $target.RevocationReason = $Reason
    $target.RevocationActor = $Actor

    $records[$index] = $target

    Save-GlobalSealLifecycleRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "BLOCK"
        Code = "SEAL_REVOKED"
        LifecycleState = "REVOKED"
    }
}

function Close-GlobalSecuritySeal {

    param(
        [Parameter(Mandatory)]
        [string]$LifecycleId
    )

    $config = Get-GlobalSealLifecycleConfig

    if (-not $config.closureEnabled) {
        throw "SEAL_CLOSURE_DISABLED"
    }

    $records = @(Get-GlobalSealLifecycleRecords)

    $target = $null
    $index = -1

    for ($i = 0; $i -lt $records.Count; $i++) {

        if ($records[$i].LifecycleId -eq $LifecycleId) {

            $target = $records[$i]
            $index = $i
            break
        }
    }

    if ($null -eq $target) {
        throw "LIFECYCLE_NOT_FOUND"
    }

    if ($target.LifecycleState -ne "REVOKED") {
        throw "SEAL_MUST_BE_REVOKED"
    }

    $target.LifecycleState = "CLOSED"
    $target.Decision = "BLOCK"
    $target.Closed = $true
    $target.ReactivationAllowed = $false
    $target.ReopenAllowed = $false
    $target.ReuseAllowed = $false
    $target.MutationAllowed = $false
    $target.ClosedAtUtc = (Get-Date).ToUniversalTime().ToString("o")

    $records[$index] = $target

    Save-GlobalSealLifecycleRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "BLOCK"
        Code = "SEAL_CLOSED_PERMANENTLY"
        LifecycleState = "CLOSED"
    }
}

function Test-GlobalSecuritySealLifecycle {

    param(
        [Parameter(Mandatory)]
        [string]$LifecycleId
    )

    $records = @(Get-GlobalSealLifecycleRecords)

    foreach ($record in $records) {

        if ($record.LifecycleId -ne $LifecycleId) {
            continue
        }

        if ($record.LifecycleState -eq "SEALED") {

            return [pscustomobject]@{
                Allowed = $true
                Decision = "ALLOW"
                Code = "SEAL_READY"
            }
        }

        if ($record.LifecycleState -eq "ACTIVE") {

            return [pscustomobject]@{
                Allowed = $true
                Decision = "ALLOW"
                Code = "SEAL_ACTIVE"
            }
        }

        if (
            $record.LifecycleState -eq "REVOKED" -or
            $record.LifecycleState -eq "CLOSED" -or
            $record.LifecycleState -eq "EXPIRED"
        ) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "SEAL_TERMINAL_STATE"
                LifecycleState = $record.LifecycleState
            }
        }
    }

    return [pscustomobject]@{
        Allowed = $false
        Decision = "BLOCK"
        Code = "LIFECYCLE_NOT_FOUND"
    }
}

function Test-GlobalSealLifecycleIntegrity {

    $records = @(Get-GlobalSealLifecycleRecords)

    foreach ($record in $records) {

        $canonical = (
            $record.LifecycleId + "|" +
            $record.SealId + "|" +
            $record.SecuritySealHash + "|" +
            $record.TenantId + "|" +
            $record.ClientId + "|" +
            $record.ProjectId + "|" +
            $record.ExecutionId + "|" +
            $record.CreatedAtUtc
        )

        $expectedHash = Get-GlobalSealLifecycleHash `
            -Value $canonical

        if ($record.IntegrityHash -ne $expectedHash) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "LIFECYCLE_HASH_INVALID"
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

        if ($record.ReuseAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "REUSE_ALLOWED"
            }
        }

        if ($record.LifecycleState -eq "CLOSED") {

            if ($record.Closed -ne $true) {

                return [pscustomobject]@{
                    Allowed = $false
                    Decision = "BLOCK"
                    Code = "CLOSED_FLAG_INVALID"
                }
            }
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "SEAL_LIFECYCLE_INTEGRITY_VALID"
    }
}

function Test-GlobalSealLifecycleScope {

    param(
        [Parameter(Mandatory)][string]$LifecycleId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$ExecutionId
    )

    $records = @(Get-GlobalSealLifecycleRecords)

    foreach ($record in $records) {

        if ($record.LifecycleId -ne $LifecycleId) {
            continue
        }

        if ($record.TenantId -ne $TenantId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_TENANT_LIFECYCLE"
            }
        }

        if ($record.ClientId -ne $ClientId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_CLIENT_LIFECYCLE"
            }
        }

        if ($record.ProjectId -ne $ProjectId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_PROJECT_LIFECYCLE"
            }
        }

        if ($record.ExecutionId -ne $ExecutionId) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_EXECUTION_LIFECYCLE"
            }
        }

        return [pscustomobject]@{
            Allowed = $true
            Decision = "ALLOW"
            Code = "SEAL_LIFECYCLE_SCOPE_VALID"
        }
    }

    return [pscustomobject]@{
        Allowed = $false
        Decision = "BLOCK"
        Code = "LIFECYCLE_NOT_FOUND"
    }
}

function Reset-GlobalSealLifecycle {

    Save-GlobalSealLifecycleRecords
}
