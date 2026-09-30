function Get-RateLimitQuotaConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Rate Limit / Quota Config introuvable : $ConfigPath"
    }

    try {
        return (
            Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        )
    }
    catch {
        throw "Rate Limit / Quota Config invalide."
    }
}

function Get-RateLimitKey {
    param(
        [AllowEmptyString()]
        [string]$Scope,

        [AllowEmptyString()]
        [string]$TenantId,

        [AllowEmptyString()]
        [string]$ClientId,

        [AllowEmptyString()]
        [string]$ProjectId,

        [AllowEmptyString()]
        [string]$WorkerId,

        [AllowEmptyString()]
        [string]$ConnectorId,

        [AllowEmptyString()]
        [string]$Provider
    )

    if ([string]::IsNullOrWhiteSpace($Scope)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "SCOPE_REQUIRED"
        }
    }

    switch ($Scope) {

        "tenant" {
            if ([string]::IsNullOrWhiteSpace($TenantId)) {
                return [pscustomobject]@{
                    status = "BLOCKED"
                    reason = "CONTEXT_INCOMPLETE"
                    field = "TenantId"
                }
            }

            return [pscustomobject]@{
                status = "CREATED"
                scope = $Scope
                key = "TENANT|$TenantId"
            }
        }

        "client" {
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

            return [pscustomobject]@{
                status = "CREATED"
                scope = $Scope
                key = "TENANT|$TenantId|CLIENT|$ClientId"
            }
        }

        "project" {
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

            return [pscustomobject]@{
                status = "CREATED"
                scope = $Scope
                key = "TENANT|$TenantId|CLIENT|$ClientId|PROJECT|$ProjectId"
            }
        }

        "worker" {
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

            if ([string]::IsNullOrWhiteSpace($WorkerId)) {
                return [pscustomobject]@{
                    status = "BLOCKED"
                    reason = "CONTEXT_INCOMPLETE"
                    field = "WorkerId"
                }
            }

            return [pscustomobject]@{
                status = "CREATED"
                scope = $Scope
                key = "TENANT|$TenantId|CLIENT|$ClientId|PROJECT|$ProjectId|WORKER|$WorkerId"
            }
        }

        "connector" {
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
                    reason = "CONTEXT_INCOMPLETE"
                    field = "ConnectorId"
                }
            }

            return [pscustomobject]@{
                status = "CREATED"
                scope = $Scope
                key = "TENANT|$TenantId|CLIENT|$ClientId|PROJECT|$ProjectId|CONNECTOR|$ConnectorId"
            }
        }

        "provider" {
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

            if ([string]::IsNullOrWhiteSpace($Provider)) {
                return [pscustomobject]@{
                    status = "BLOCKED"
                    reason = "CONTEXT_INCOMPLETE"
                    field = "Provider"
                }
            }

            return [pscustomobject]@{
                status = "CREATED"
                scope = $Scope
                key = "TENANT|$TenantId|CLIENT|$ClientId|PROVIDER|$Provider"
            }
        }

        default {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "INVALID_SCOPE"
                scope = $Scope
            }
        }
    }
}

function Get-QuotaLimit {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Config,

        [AllowEmptyString()]
        [string]$Scope
    )

    if ([string]::IsNullOrWhiteSpace($Scope)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "SCOPE_REQUIRED"
        }
    }

    $property = $Scope

    $limit = $Config.limits.$property

    if ($null -eq $limit) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "LIMIT_NOT_CONFIGURED"
            scope = $Scope
        }
    }

    return [pscustomobject]@{
        status = "VALID"
        scope = $Scope
        limit = [int]$limit
    }
}

function Get-QuotaState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath,

        [AllowEmptyString()]
        [string]$Key,

        [int64]$CurrentUnixTime,

        [int]$WindowSeconds
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "RATE_LIMIT_KEY_REQUIRED"
        }
    }

    if (-not (Test-Path -LiteralPath $StatePath)) {
        return [pscustomobject]@{
            status = "NEW"
            key = $Key
            windowStartUnix = $CurrentUnixTime
            windowSeconds = $WindowSeconds
            consumption = 0
        }
    }

    try {
        $state =
            Get-Content `
                -LiteralPath $StatePath `
                -Raw `
                -Encoding UTF8 |
            ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "STATE_INVALID"
        }
    }

    if ($state.key -ne $Key) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "STATE_KEY_MISMATCH"
        }
    }

    $windowEnd = [int64]$state.windowStartUnix +
        [int64]$state.windowSeconds

    if ($CurrentUnixTime -ge $windowEnd) {
        return [pscustomobject]@{
            status = "RESET"
            key = $Key
            windowStartUnix = $CurrentUnixTime
            windowSeconds = $WindowSeconds
            consumption = 0
        }
    }

    return [pscustomobject]@{
        status = "ACTIVE"
        key = $Key
        windowStartUnix = [int64]$state.windowStartUnix
        windowSeconds = [int]$state.windowSeconds
        consumption = [int]$state.consumption
    }
}

function Consume-Quota {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [AllowEmptyString()]
        [string]$Scope,

        [AllowEmptyString()]
        [string]$TenantId,

        [AllowEmptyString()]
        [string]$ClientId,

        [AllowEmptyString()]
        [string]$ProjectId,

        [AllowEmptyString()]
        [string]$WorkerId,

        [AllowEmptyString()]
        [string]$ConnectorId,

        [AllowEmptyString()]
        [string]$Provider,

        [int]$Units = 1
    )

    $config = Get-RateLimitQuotaConfig `
        -ConfigPath $ConfigPath

    if ($config.enabled -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "QUOTA_MANAGER_DISABLED"
        }
    }

    if ($config.quotaEnabled -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "QUOTA_DISABLED"
        }
    }

    if ($Units -lt 1 -and
        $config.allowNegativeConsumption -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "INVALID_CONSUMPTION"
        }
    }

    $keyResult = Get-RateLimitKey `
        -Scope $Scope `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -WorkerId $WorkerId `
        -ConnectorId $ConnectorId `
        -Provider $Provider

    if ($keyResult.status -ne "CREATED") {
        return $keyResult
    }

    $limitResult = Get-QuotaLimit `
        -Config $config `
        -Scope $Scope

    if ($limitResult.status -ne "VALID") {
        return $limitResult
    }

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $StateDirectory | Out-Null

    $safeName = (
        [System.BitConverter]::ToString(
            (
                [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                    [System.Text.Encoding]::UTF8.GetBytes(
                        $keyResult.key
                    )
                )
            )
        ).Replace("-", "").ToLowerInvariant()
    )

    $statePath = Join-Path `
        $StateDirectory `
        "$safeName.json"

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $state = Get-QuotaState `
        -StatePath $statePath `
        -Key $keyResult.key `
        -CurrentUnixTime $now `
        -WindowSeconds ([int]$config.windowSeconds)

    if (
        $state.status -eq "BLOCKED"
    ) {
        return $state
    }

    $currentConsumption = [int]$state.consumption

    $newConsumption = $currentConsumption + $Units

    if ($newConsumption -gt $limitResult.limit) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "QUOTA_EXCEEDED"
            scope = $Scope
            key = $keyResult.key
            limit = $limitResult.limit
            consumption = $currentConsumption
            requestedUnits = $Units
            remaining = [Math]::Max(
                0,
                $limitResult.limit - $currentConsumption
            )
        }
    }

    $newState = [ordered]@{
        version = "1.0"
        key = $keyResult.key
        scope = $Scope

        windowStartUnix = [int64]$state.windowStartUnix
        windowSeconds = [int]$state.windowSeconds

        consumption = $newConsumption
        limit = $limitResult.limit

        secretExposure = $false
        containsSecret = $false
    }

    $newState |
        ConvertTo-Json -Depth 20 |
        Set-Content `
            -LiteralPath $statePath `
            -Encoding UTF8

    return [pscustomobject]@{
        status = "CONSUMED"
        scope = $Scope
        key = $keyResult.key
        limit = $limitResult.limit
        previousConsumption = $currentConsumption
        consumption = $newConsumption
        remaining = $limitResult.limit - $newConsumption
        windowSeconds = [int]$config.windowSeconds
        statePath = $statePath
        secretExposure = $false
    }
}

function Test-RateLimit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [AllowEmptyString()]
        [string]$Scope,

        [AllowEmptyString()]
        [string]$TenantId,

        [AllowEmptyString()]
        [string]$ClientId,

        [AllowEmptyString()]
        [string]$ProjectId,

        [AllowEmptyString()]
        [string]$WorkerId,

        [AllowEmptyString()]
        [string]$ConnectorId,

        [AllowEmptyString()]
        [string]$Provider,

        [int]$RequestedUnits = 1
    )

    $config = Get-RateLimitQuotaConfig `
        -ConfigPath $ConfigPath

    $keyResult = Get-RateLimitKey `
        -Scope $Scope `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -WorkerId $WorkerId `
        -ConnectorId $ConnectorId `
        -Provider $Provider

    if ($keyResult.status -ne "CREATED") {
        return $keyResult
    }

    $limitResult = Get-QuotaLimit `
        -Config $config `
        -Scope $Scope

    if ($limitResult.status -ne "VALID") {
        return $limitResult
    }

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $StateDirectory | Out-Null

    $bytes = [System.Text.Encoding]::UTF8.GetBytes(
        $keyResult.key
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $hash = $sha.ComputeHash($bytes)
        $safeName =
            [System.BitConverter]::ToString(
                $hash
            ).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }

    $statePath = Join-Path `
        $StateDirectory `
        "$safeName.json"

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $state = Get-QuotaState `
        -StatePath $statePath `
        -Key $keyResult.key `
        -CurrentUnixTime $now `
        -WindowSeconds ([int]$config.windowSeconds)

    if ($state.status -eq "BLOCKED") {
        return $state
    }

    $consumption = [int]$state.consumption

    if (
        ($consumption + $RequestedUnits) -ge
        $limitResult.limit
    ) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "RATE_LIMIT_EXCEEDED"
            scope = $Scope
            key = $keyResult.key
            limit = $limitResult.limit
            consumption = $consumption
            requestedUnits = $RequestedUnits
        }
    }

    return [pscustomobject]@{
        status = "ALLOWED"
        scope = $Scope
        key = $keyResult.key
        limit = $limitResult.limit
        consumption = $consumption
        requestedUnits = $RequestedUnits
        remaining = $limitResult.limit -
            ($consumption + $RequestedUnits)
        secretExposure = $false
    }
}

function Reset-QuotaState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory
    )

    if (-not (Test-Path -LiteralPath $StateDirectory)) {
        return [pscustomobject]@{
            status = "EMPTY"
        }
    }

    Get-ChildItem `
        -LiteralPath $StateDirectory `
        -Filter "*.json" `
        -File `
        -ErrorAction SilentlyContinue |
        Remove-Item -Force

    return [pscustomobject]@{
        status = "RESET"
        stateDirectory = $StateDirectory
    }
}