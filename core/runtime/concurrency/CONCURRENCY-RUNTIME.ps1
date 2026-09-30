function Get-ConcurrencyConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Concurrency Config introuvable : $ConfigPath"
    }

    try {
        return (
            Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        )
    }
    catch {
        throw "Concurrency Config invalide."
    }
}

function New-ExecutionLockKey {
    param(
        [AllowEmptyString()]
        [string]$TenantId,

        [AllowEmptyString()]
        [string]$ClientId,

        [AllowEmptyString()]
        [string]$ProjectId,

        [AllowEmptyString()]
        [string]$ConnectorId,

        [AllowEmptyString()]
        [string]$Operation
    )

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "TenantId"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "ClientId"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ProjectId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "ProjectId"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ConnectorId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONNECTOR_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($Operation)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "OPERATION_REQUIRED"
        }
    }

    $material = "$TenantId|$ClientId|$ProjectId|$ConnectorId|$Operation"

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($material)
        $hash = $sha.ComputeHash($bytes)
        $hex = [System.BitConverter]::ToString($hash).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }

    return [pscustomobject]@{
        status = "CREATED"
        lockKey = "LOCK-$hex"
        tenantId = $TenantId
        clientId = $ClientId
        projectId = $ProjectId
        connectorId = $ConnectorId
        operation = $Operation
    }
}

function Get-ExecutionLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LockPath
    )

    if (-not (Test-Path -LiteralPath $LockPath)) {
        return $null
    }

    try {
        return (
            Get-Content -LiteralPath $LockPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        )
    }
    catch {
        return $null
    }
}

function Test-ExecutionLockStale {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Lock,

        [int]$CurrentUnixTime
    )

    if ($null -eq $Lock) {
        return [pscustomobject]@{
            status = "NOT_FOUND"
            stale = $false
        }
    }

    if ($Lock.expiresAtUnix -le $CurrentUnixTime) {
        return [pscustomobject]@{
            status = "STALE"
            stale = $true
            lockKey = $Lock.lockKey
        }
    }

    return [pscustomobject]@{
        status = "ACTIVE"
        stale = $false
        lockKey = $Lock.lockKey
    }
}

function Acquire-ExecutionLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$LockDirectory,

        [AllowEmptyString()]
        [string]$TenantId,

        [AllowEmptyString()]
        [string]$ClientId,

        [AllowEmptyString()]
        [string]$ProjectId,

        [AllowEmptyString()]
        [string]$ConnectorId,

        [AllowEmptyString()]
        [string]$Operation,

        [AllowEmptyString()]
        [string]$ExecutionId,

        [int]$LockSeconds = 120,

        [AllowEmptyString()]
        [string]$OwnerId
    )

    $config = Get-ConcurrencyConfig `
        -ConfigPath $ConfigPath

    if ($config.enabled -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONCURRENCY_MANAGER_DISABLED"
        }
    }

    if ($config.lockEnabled -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "LOCK_DISABLED"
        }
    }

    if ($config.storeSecretsInLocks -ne $false) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "SECRET_STORAGE_CONFIGURATION_INVALID"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "EXECUTION_ID_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($OwnerId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "OWNER_ID_REQUIRED"
        }
    }

    if ($LockSeconds -lt [int]$config.minimumLockSeconds) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "LOCK_DURATION_TOO_LOW"
        }
    }

    if ($LockSeconds -gt [int]$config.maximumLockSeconds) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "LOCK_DURATION_TOO_HIGH"
        }
    }

    $key = New-ExecutionLockKey `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -ConnectorId $ConnectorId `
        -Operation $Operation

    if ($key.status -ne "CREATED") {
        return $key
    }

    New-Item -ItemType Directory -Force -Path $LockDirectory | Out-Null

    $lockPath = Join-Path `
        $LockDirectory `
        "$($key.lockKey).json"

    $currentUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $existing = Get-ExecutionLock `
        -LockPath $lockPath

    if ($null -ne $existing) {

        $stale = Test-ExecutionLockStale `
            -Lock $existing `
            -CurrentUnixTime $currentUnix

        if (-not $stale.stale) {
            return [pscustomobject]@{
                status = "LOCKED"
                reason = "CONCURRENT_EXECUTION"
                lockKey = $key.lockKey
                activeExecutionId = $existing.executionId
                ownerId = $existing.ownerId
                expiresAtUnix = $existing.expiresAtUnix
            }
        }

        Remove-Item `
            -LiteralPath $lockPath `
            -Force
    }

    $expires = $currentUnix + $LockSeconds

    $lock = [ordered]@{
        lockVersion = "1.0"
        lockId = "LOCK-ID-$([guid]::NewGuid().ToString())"
        lockKey = $key.lockKey

        tenantId = $TenantId
        clientId = $ClientId
        projectId = $ProjectId

        connectorId = $ConnectorId
        operation = $Operation

        executionId = $ExecutionId
        ownerId = $OwnerId

        createdAtUnix = $currentUnix
        expiresAtUnix = $expires

        secretExposure = $false
        containsSecret = $false
    }

    $lock |
        ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $lockPath -Encoding UTF8

    return [pscustomobject]@{
        status = "ACQUIRED"
        lockId = $lock.lockId
        lockKey = $lock.lockKey
        lockPath = $lockPath

        executionId = $ExecutionId
        ownerId = $OwnerId

        expiresAtUnix = $expires

        secretExposure = $false
        externalCallPerformed = $false
    }
}

function Release-ExecutionLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LockPath,

        [AllowEmptyString()]
        [string]$ExecutionId,

        [AllowEmptyString()]
        [string]$OwnerId
    )

    if (-not (Test-Path -LiteralPath $LockPath)) {
        return [pscustomobject]@{
            status = "NOT_FOUND"
            reason = "LOCK_NOT_FOUND"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "EXECUTION_ID_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($OwnerId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "OWNER_ID_REQUIRED"
        }
    }

    $lock = Get-ExecutionLock `
        -LockPath $LockPath

    if ($null -eq $lock) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "INVALID_LOCK"
        }
    }

    if ($lock.executionId -ne $ExecutionId) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "LOCK_OWNER_MISMATCH"
        }
    }

    if ($lock.ownerId -ne $OwnerId) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "LOCK_OWNER_MISMATCH"
        }
    }

    Remove-Item `
        -LiteralPath $LockPath `
        -Force

    return [pscustomobject]@{
        status = "RELEASED"
        lockId = $lock.lockId
        lockKey = $lock.lockKey
        executionId = $ExecutionId
        secretExposure = $false
    }
}