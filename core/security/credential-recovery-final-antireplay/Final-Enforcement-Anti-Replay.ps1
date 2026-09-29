function Get-FinalEnforcementAntiReplayConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "ANTI_REPLAY_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "ANTI_REPLAY_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-FinalEnforcementConsumptions {

    $path = Join-Path $PSScriptRoot "state\consumptions.json"

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

function Save-FinalEnforcementConsumptions {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-FinalEnforcementAntiReplayConfig
    $path = Join-Path $PSScriptRoot "state\consumptions.json"

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "ANTI_REPLAY_RECORD_LIMIT"
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

function Get-FinalEnforcementAntiReplayHash {

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

function New-FinalEnforcementConsumptionId {

    return "CONSUME-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function New-FinalEnforcementNonce {

    return [guid]::NewGuid().ToString("N")
}

function Invoke-FinalEnforcementConsumption {

    param(
        [Parameter(Mandatory)][string]$EnforcementId,
        [Parameter(Mandatory)][string]$RecoveryId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$ExecutionId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Connector,
        [Parameter(Mandatory)][string]$ContextHash,
        [Parameter(Mandatory)][string]$Nonce,
        [Parameter(Mandatory)][bool]$Enforced,
        [Parameter(Mandatory)][bool]$PermanentLock,
        [Parameter(Mandatory)][bool]$Immutable,
        [Parameter(Mandatory)][bool]$FreshBinding
    )

    $config = Get-FinalEnforcementAntiReplayConfig

    if (-not $config.enabled) {
        throw "ANTI_REPLAY_DISABLED"
    }

    if (-not $config.antiReplayEnabled) {
        throw "ANTI_REPLAY_GUARD_DISABLED"
    }

    if (-not $Enforced) {
        throw "ENFORCEMENT_REQUIRED"
    }

    if (-not $PermanentLock) {
        throw "PERMANENT_LOCK_REQUIRED"
    }

    if (-not $Immutable) {
        throw "IMMUTABLE_ENFORCEMENT_REQUIRED"
    }

    if (-not $FreshBinding) {
        throw "FRESH_BINDING_REQUIRED"
    }

    $required = @(
        $EnforcementId
        $RecoveryId
        $TenantId
        $ClientId
        $ProjectId
        $UserId
        $WorkerId
        $ExecutionId
        $Action
        $Connector
        $ContextHash
        $Nonce
    )

    foreach ($value in $required) {

        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "ANTI_REPLAY_FIELD_REQUIRED"
        }
    }

    $records = @(Get-FinalEnforcementConsumptions)

    foreach ($existing in $records) {

        if ($existing.EnforcementId -eq $EnforcementId) {

            throw "ENFORCEMENT_ALREADY_CONSUMED"
        }

        if ($existing.Nonce -eq $Nonce) {

            throw "NONCE_ALREADY_USED"
        }

        if ($existing.ExecutionId -eq $ExecutionId) {

            throw "EXECUTION_ALREADY_BOUND"
        }
    }

    $sameContext = @(
        $records |
        Where-Object {
            $_.TenantId -eq $TenantId -and
            $_.ClientId -eq $ClientId -and
            $_.ProjectId -eq $ProjectId -and
            $_.UserId -eq $UserId -and
            $_.WorkerId -eq $WorkerId -and
            $_.ContextHash -eq $ContextHash
        }
    )

    foreach ($existingContext in $sameContext) {

        if ($existingContext.Action -eq $Action -and
            $existingContext.Connector -eq $Connector) {

            throw "CONTEXT_BINDING_ALREADY_CONSUMED"
        }
    }

    $now = (Get-Date).ToUniversalTime().ToString("o")
    $consumptionId = New-FinalEnforcementConsumptionId

    $canonical = (
        $consumptionId + "|" +
        $EnforcementId + "|" +
        $RecoveryId + "|" +
        $TenantId + "|" +
        $ClientId + "|" +
        $ProjectId + "|" +
        $UserId + "|" +
        $WorkerId + "|" +
        $ExecutionId + "|" +
        $Action + "|" +
        $Connector + "|" +
        $ContextHash + "|" +
        $Nonce + "|" +
        $now
    )

    $integrityHash = Get-FinalEnforcementAntiReplayHash `
        -Value $canonical

    $record = [pscustomobject][ordered]@{
        ConsumptionId = $consumptionId
        EnforcementId = $EnforcementId
        RecoveryId    = $RecoveryId
        TenantId      = $TenantId
        ClientId      = $ClientId
        ProjectId     = $ProjectId
        UserId        = $UserId
        WorkerId      = $WorkerId
        ExecutionId   = $ExecutionId
        Action        = $Action
        Connector     = $Connector
        ContextHash   = $ContextHash
        Nonce         = $Nonce
        Enforced      = $Enforced
        PermanentLock = $PermanentLock
        Immutable     = $Immutable
        FreshBinding  = $FreshBinding
        Decision      = "ALLOW"
        ConsumptionStatus = "CONSUMED"
        OneTimeUse    = $true
        ReplayBlocked = $true
        CreatedAtUtc  = $now
        ConsumedAtUtc = $now
        IntegrityHash = $integrityHash
        RawSecret     = $null
        RawCredential = $null
    }

    $records += $record

    Save-FinalEnforcementConsumptions `
        -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "ENFORCEMENT_CONSUMED_ONCE"
        ConsumptionId = $consumptionId
        ConsumptionStatus = "CONSUMED"
        ReplayBlocked = $true
    }
}

function Test-FinalEnforcementReplay {

    param(
        [Parameter(Mandatory)]
        [string]$EnforcementId
    )

    $records = @(Get-FinalEnforcementConsumptions)

    $matches = @(
        $records |
        Where-Object {
            $_.EnforcementId -eq $EnforcementId
        }
    )

    if ($matches.Count -eq 0) {

        return [pscustomobject]@{
            Allowed = $true
            Decision = "ALLOW"
            Code = "ENFORCEMENT_NOT_CONSUMED"
        }
    }

    return [pscustomobject]@{
        Allowed = $false
        Decision = "BLOCK"
        Code = "ENFORCEMENT_ALREADY_CONSUMED"
    }
}

function Test-FinalEnforcementConsumptionIntegrity {

    $records = @(Get-FinalEnforcementConsumptions)

    foreach ($record in $records) {

        $canonical = (
            $record.ConsumptionId + "|" +
            $record.EnforcementId + "|" +
            $record.RecoveryId + "|" +
            $record.TenantId + "|" +
            $record.ClientId + "|" +
            $record.ProjectId + "|" +
            $record.UserId + "|" +
            $record.WorkerId + "|" +
            $record.ExecutionId + "|" +
            $record.Action + "|" +
            $record.Connector + "|" +
            $record.ContextHash + "|" +
            $record.Nonce + "|" +
            $record.CreatedAtUtc
        )

        $expectedHash = Get-FinalEnforcementAntiReplayHash `
            -Value $canonical

        if ($record.IntegrityHash -ne $expectedHash) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CONSUMPTION_HASH_INVALID"
                ConsumptionId = $record.ConsumptionId
            }
        }

        if ($record.OneTimeUse -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "ONE_TIME_FLAG_INVALID"
                ConsumptionId = $record.ConsumptionId
            }
        }

        if ($record.ReplayBlocked -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "REPLAY_BLOCK_FLAG_INVALID"
                ConsumptionId = $record.ConsumptionId
            }
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "CONSUMPTION_INTEGRITY_VALID"
    }
}

function Reset-FinalEnforcementAntiReplay {

    Save-FinalEnforcementConsumptions
}
