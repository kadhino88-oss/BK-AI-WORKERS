function Get-RevocationSyncConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "REVOCATION_SYNC_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "REVOCATION_SYNC_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-RevocationSyncRecords {

    $path = Join-Path $PSScriptRoot "state\sync-records.json"

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

function Save-RevocationSyncRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-RevocationSyncConfig
    $path = Join-Path $PSScriptRoot "state\sync-records.json"

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "REVOCATION_SYNC_RECORD_LIMIT"
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

function Get-RevocationSyncHash {

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

function New-RevocationSyncId {

    return "SYNC-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Register-RevocationSource {

    param(
        [Parameter(Mandatory)][string]$EnforcementId,
        [Parameter(Mandatory)][string]$RecoveryId,
        [Parameter(Mandatory)][string]$ConsumptionId,
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$ExecutionId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId
    )

    $config = Get-RevocationSyncConfig

    if (-not $config.enabled) {
        throw "REVOCATION_SYNC_DISABLED"
    }

    $required = @(
        $EnforcementId
        $RecoveryId
        $ConsumptionId
        $AuthorizationId
        $ExecutionId
        $TenantId
        $ClientId
        $ProjectId
    )

    foreach ($value in $required) {

        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "SYNC_BINDING_REQUIRED"
        }
    }

    $records = @(Get-RevocationSyncRecords)

    foreach ($existing in $records) {

        if ($existing.EnforcementId -eq $EnforcementId) {
            throw "REVOCATION_SOURCE_ALREADY_REGISTERED"
        }
    }

    $now = (Get-Date).ToUniversalTime().ToString("o")

    $canonical = (
        $EnforcementId + "|" +
        $RecoveryId + "|" +
        $ConsumptionId + "|" +
        $AuthorizationId + "|" +
        $ExecutionId + "|" +
        $TenantId + "|" +
        $ClientId + "|" +
        $ProjectId + "|" +
        $now
    )

    $sourceHash = Get-RevocationSyncHash -Value $canonical

    $record = [pscustomobject][ordered]@{
        SyncId                   = New-RevocationSyncId
        EnforcementId            = $EnforcementId
        RecoveryId               = $RecoveryId
        ConsumptionId            = $ConsumptionId
        AuthorizationId          = $AuthorizationId
        ExecutionId              = $ExecutionId
        TenantId                 = $TenantId
        ClientId                 = $ClientId
        ProjectId                = $ProjectId

        SourceRevocationStatus   = "REVOKED"

        EnforcementStatus        = "REVOKED"
        ConsumptionStatus        = "REVOKED"
        AuthorizationStatus      = "REVOKED"
        ExecutionStatus          = "BLOCKED"

        EnforcementSynced        = $false
        ConsumptionSynced        = $false
        AuthorizationSynced      = $false
        ExecutionSynced          = $false

        PropagationStatus        = "PENDING"
        SynchronizationStatus    = "PENDING"

        KillSwitchActive         = $true
        ReactivationAllowed      = $false
        ReopenAllowed             = $false

        Decision                 = "BLOCK"

        SourceHash               = $sourceHash
        CreatedAtUtc             = $now
        PropagatedAtUtc          = $null
        SynchronizedAtUtc        = $null

        RawSecret                = $null
        RawCredential            = $null
    }

    $records += $record

    Save-RevocationSyncRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "BLOCK"
        Code = "REVOCATION_SOURCE_REGISTERED"
        SyncId = $record.SyncId
    }
}

function Invoke-RevocationPropagation {

    param(
        [Parameter(Mandatory)][string]$SyncId,
        [Parameter(Mandatory)][bool]$EnforcementRevoked,
        [Parameter(Mandatory)][bool]$ConsumptionRevoked,
        [Parameter(Mandatory)][bool]$AuthorizationRevoked,
        [Parameter(Mandatory)][bool]$ExecutionBlocked
    )

    $config = Get-RevocationSyncConfig

    if (-not $config.propagationEnabled) {
        throw "PROPAGATION_DISABLED"
    }

    $records = @(Get-RevocationSyncRecords)

    $target = $null
    $index = -1

    for ($i = 0; $i -lt $records.Count; $i++) {

        if ($records[$i].SyncId -eq $SyncId) {
            $target = $records[$i]
            $index = $i
            break
        }
    }

    if ($null -eq $target) {
        throw "SYNC_RECORD_NOT_FOUND"
    }

    if ($target.SourceRevocationStatus -ne "REVOKED") {
        throw "SOURCE_REVOCATION_REQUIRED"
    }

    if (-not $EnforcementRevoked) {
        throw "ENFORCEMENT_PROPAGATION_REQUIRED"
    }

    if (-not $ConsumptionRevoked) {
        throw "CONSUMPTION_PROPAGATION_REQUIRED"
    }

    if (-not $AuthorizationRevoked) {
        throw "AUTHORIZATION_PROPAGATION_REQUIRED"
    }

    if (-not $ExecutionBlocked) {
        throw "EXECUTION_BLOCK_REQUIRED"
    }

    $now = (Get-Date).ToUniversalTime().ToString("o")

    $target.EnforcementSynced = $true
    $target.ConsumptionSynced = $true
    $target.AuthorizationSynced = $true
    $target.ExecutionSynced = $true

    $target.PropagationStatus = "PROPAGATED"
    $target.SynchronizationStatus = "SYNCHRONIZED"

    $target.KillSwitchActive = $true
    $target.Decision = "BLOCK"

    $target.PropagatedAtUtc = $now
    $target.SynchronizedAtUtc = $now

    $records[$index] = $target

    Save-RevocationSyncRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "BLOCK"
        Code = "REVOCATION_PROPAGATED_AND_SYNCHRONIZED"
        SyncId = $SyncId
    }
}

function Test-RevocationPropagation {

    param(
        [Parameter(Mandatory)]
        [string]$SyncId
    )

    $records = @(Get-RevocationSyncRecords)

    foreach ($record in $records) {

        if ($record.SyncId -ne $SyncId) {
            continue
        }

        if ($record.SourceRevocationStatus -ne "REVOKED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "SOURCE_NOT_REVOKED"
            }
        }

        if ($record.EnforcementSynced -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "ENFORCEMENT_NOT_SYNCED"
            }
        }

        if ($record.ConsumptionSynced -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CONSUMPTION_NOT_SYNCED"
            }
        }

        if ($record.AuthorizationSynced -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "AUTHORIZATION_NOT_SYNCED"
            }
        }

        if ($record.ExecutionSynced -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "EXECUTION_NOT_SYNCED"
            }
        }

        if ($record.PropagationStatus -ne "PROPAGATED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "PROPAGATION_INCOMPLETE"
            }
        }

        if ($record.SynchronizationStatus -ne "SYNCHRONIZED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "SYNCHRONIZATION_INCOMPLETE"
            }
        }

        return [pscustomobject]@{
            Allowed = $true
            Decision = "ALLOW"
            Code = "REVOCATION_PROPAGATION_VALID"
        }
    }

    return [pscustomobject]@{
        Allowed = $false
        Decision = "BLOCK"
        Code = "SYNC_RECORD_NOT_FOUND"
    }
}

function Test-RevocationSynchronizationIntegrity {

    $records = @(Get-RevocationSyncRecords)

    foreach ($record in $records) {

        $canonical = (
            $record.EnforcementId + "|" +
            $record.RecoveryId + "|" +
            $record.ConsumptionId + "|" +
            $record.AuthorizationId + "|" +
            $record.ExecutionId + "|" +
            $record.TenantId + "|" +
            $record.ClientId + "|" +
            $record.ProjectId + "|" +
            $record.CreatedAtUtc
        )

        $expectedHash = Get-RevocationSyncHash `
            -Value $canonical

        if ($record.SourceHash -ne $expectedHash) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "SOURCE_HASH_INVALID"
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
            $record.EnforcementStatus -ne "REVOKED" -or
            $record.ConsumptionStatus -ne "REVOKED" -or
            $record.AuthorizationStatus -ne "REVOKED" -or
            $record.ExecutionStatus -ne "BLOCKED"
        ) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_MODULE_STATE_DRIFT"
            }
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "REVOCATION_SYNC_INTEGRITY_VALID"
    }
}

function Reset-RevocationSync {

    Save-RevocationSyncRecords
}
