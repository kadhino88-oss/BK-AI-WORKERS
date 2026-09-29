function Get-ConsumptionIsolationConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "ISOLATION_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "ISOLATION_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-AuthorizedConsumptionRecords {

    $path = Join-Path $PSScriptRoot "state\authorized-consumptions.json"

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

function Save-AuthorizedConsumptionRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-ConsumptionIsolationConfig
    $path = Join-Path $PSScriptRoot "state\authorized-consumptions.json"

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "ISOLATION_RECORD_LIMIT"
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

function Get-ConsumptionIsolationHash {

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

function New-ConsumptionAuthorizationId {

    return "CAUTH-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function New-ConsumptionContextHash {

    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Connector
    )

    $canonical = (
        $TenantId + "|" +
        $ClientId + "|" +
        $ProjectId + "|" +
        $UserId + "|" +
        $WorkerId + "|" +
        $Action + "|" +
        $Connector
    )

    return Get-ConsumptionIsolationHash -Value $canonical
}

function Authorize-FinalEnforcementConsumption {

    param(
        [Parameter(Mandatory)][string]$EnforcementId,
        [Parameter(Mandatory)][string]$RecoveryId,
        [Parameter(Mandatory)][string]$ConsumptionId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$ExecutionId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Connector,
        [Parameter(Mandatory)][string]$ContextHash,
        [Parameter(Mandatory)][bool]$Enforced,
        [Parameter(Mandatory)][bool]$Consumed,
        [Parameter(Mandatory)][bool]$ReplayBlocked,
        [Parameter(Mandatory)][bool]$PermanentLock,
        [Parameter(Mandatory)][bool]$Immutable
    )

    $config = Get-ConsumptionIsolationConfig

    if (-not $config.enabled) {
        throw "ISOLATION_GUARD_DISABLED"
    }

    if (-not $config.authorizationEnabled) {
        throw "CONSUMPTION_AUTHORIZATION_DISABLED"
    }

    if (-not $Enforced) {
        throw "ENFORCEMENT_REQUIRED"
    }

    if (-not $Consumed) {
        throw "CONSUMPTION_REQUIRED"
    }

    if (-not $ReplayBlocked) {
        throw "REPLAY_PROTECTION_REQUIRED"
    }

    if (-not $PermanentLock) {
        throw "PERMANENT_LOCK_REQUIRED"
    }

    if (-not $Immutable) {
        throw "IMMUTABLE_BINDING_REQUIRED"
    }

    $required = @(
        $EnforcementId
        $RecoveryId
        $ConsumptionId
        $TenantId
        $ClientId
        $ProjectId
        $UserId
        $WorkerId
        $ExecutionId
        $Action
        $Connector
        $ContextHash
    )

    foreach ($value in $required) {

        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "CONSUMPTION_AUTH_BINDING_REQUIRED"
        }
    }

    $expectedContextHash = New-ConsumptionContextHash `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -UserId $UserId `
        -WorkerId $WorkerId `
        -Action $Action `
        -Connector $Connector

    if ($ContextHash -ne $expectedContextHash) {
        throw "CONTEXT_HASH_MISMATCH"
    }

    $records = @(Get-AuthorizedConsumptionRecords)

    foreach ($existing in $records) {

        if ($existing.ConsumptionId -eq $ConsumptionId) {
            throw "CONSUMPTION_ALREADY_AUTHORIZED"
        }
    }

    $now = (Get-Date).ToUniversalTime().ToString("o")
    $authorizationId = New-ConsumptionAuthorizationId

    $canonical = (
        $authorizationId + "|" +
        $EnforcementId + "|" +
        $RecoveryId + "|" +
        $ConsumptionId + "|" +
        $TenantId + "|" +
        $ClientId + "|" +
        $ProjectId + "|" +
        $UserId + "|" +
        $WorkerId + "|" +
        $ExecutionId + "|" +
        $Action + "|" +
        $Connector + "|" +
        $ContextHash + "|" +
        $now
    )

    $integrityHash = Get-ConsumptionIsolationHash `
        -Value $canonical

    $record = [pscustomobject][ordered]@{
        AuthorizationId        = $authorizationId
        IntegrityHash          = $integrityHash
        EnforcementId          = $EnforcementId
        RecoveryId             = $RecoveryId
        ConsumptionId          = $ConsumptionId
        TenantId               = $TenantId
        ClientId               = $ClientId
        ProjectId              = $ProjectId
        UserId                 = $UserId
        WorkerId               = $WorkerId
        ExecutionId            = $ExecutionId
        Action                 = $Action
        Connector              = $Connector
        ContextHash            = $ContextHash
        Enforced               = $Enforced
        Consumed               = $Consumed
        ReplayBlocked          = $ReplayBlocked
        PermanentLock          = $PermanentLock
        Immutable              = $Immutable
        TenantIsolated         = $true
        ClientIsolated         = $true
        ProjectIsolated        = $true
        UserIsolated           = $true
        WorkerIsolated         = $true
        ActionBound            = $true
        ConnectorBound         = $true
        Decision               = "ALLOW"
        AuthorizationStatus    = "AUTHORIZED"
        CrossTenantAllowed     = $false
        CrossClientAllowed     = $false
        CrossProjectAllowed    = $false
        CrossUserAllowed       = $false
        CrossWorkerAllowed     = $false
        ActionDriftAllowed     = $false
        ConnectorDriftAllowed  = $false
        ContextDriftAllowed    = $false
        CreatedAtUtc           = $now
        RawSecret              = $null
        RawCredential          = $null
    }

    $records += $record

    Save-AuthorizedConsumptionRecords `
        -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "CONSUMPTION_AUTHORIZED_AND_ISOLATED"
        AuthorizationId = $authorizationId
        AuthorizationStatus = "AUTHORIZED"
        TenantIsolated = $true
    }
}

function Test-ConsumptionAuthorizationIntegrity {

    $records = @(Get-AuthorizedConsumptionRecords)

    foreach ($record in $records) {

        $canonical = (
            $record.AuthorizationId + "|" +
            $record.EnforcementId + "|" +
            $record.RecoveryId + "|" +
            $record.ConsumptionId + "|" +
            $record.TenantId + "|" +
            $record.ClientId + "|" +
            $record.ProjectId + "|" +
            $record.UserId + "|" +
            $record.WorkerId + "|" +
            $record.ExecutionId + "|" +
            $record.Action + "|" +
            $record.Connector + "|" +
            $record.ContextHash + "|" +
            $record.CreatedAtUtc
        )

        $expectedHash = Get-ConsumptionIsolationHash `
            -Value $canonical

        if ($record.IntegrityHash -ne $expectedHash) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CONSUMPTION_AUTH_HASH_INVALID"
            }
        }

        if ($record.TenantIsolated -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "TENANT_ISOLATION_INVALID"
            }
        }

        if ($record.CrossTenantAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CROSS_TENANT_ALLOWED"
            }
        }

        if ($record.ContextDriftAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CONTEXT_DRIFT_ALLOWED"
            }
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "CONSUMPTION_AUTHORIZATION_INTEGRITY_VALID"
    }
}

function Test-ConsumptionTenantIsolation {

    param(
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Connector
    )

    $records = @(Get-AuthorizedConsumptionRecords)

    $record = $null

    foreach ($item in $records) {

        if ($item.AuthorizationId -eq $AuthorizationId) {
            $record = $item
            break
        }
    }

    if ($null -eq $record) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "AUTHORIZATION_NOT_FOUND"
        }
    }

    if ($record.TenantId -ne $TenantId) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "CROSS_TENANT_MISMATCH"
        }
    }

    if ($record.ClientId -ne $ClientId) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "CROSS_CLIENT_MISMATCH"
        }
    }

    if ($record.ProjectId -ne $ProjectId) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "CROSS_PROJECT_MISMATCH"
        }
    }

    if ($record.UserId -ne $UserId) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "CROSS_USER_MISMATCH"
        }
    }

    if ($record.WorkerId -ne $WorkerId) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "CROSS_WORKER_MISMATCH"
        }
    }

    if ($record.Action -ne $Action) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "ACTION_DRIFT"
        }
    }

    if ($record.Connector -ne $Connector) {

        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "CONNECTOR_DRIFT"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "CONSUMPTION_SCOPE_VALID"
    }
}

function Reset-ConsumptionIsolation {

    Save-AuthorizedConsumptionRecords
}
