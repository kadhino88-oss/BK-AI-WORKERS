$ErrorActionPreference = "Stop"

$RuntimeRoot = Split-Path -Parent $PSCommandPath
$StateDir = Join-Path $RuntimeRoot "state"
$ConfigPath = Join-Path $RuntimeRoot "CIRCUIT-BREAKER-CONFIG.json"
$StatePath = Join-Path $StateDir "circuit-state.json"

function Get-CircuitBreakerConfig {

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration Circuit Breaker introuvable."
    }

    return Get-Content `
        -LiteralPath $ConfigPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
}

function New-CircuitKey {

    param(
        [ValidateSet(
            "tenant",
            "client",
            "project",
            "worker",
            "connector",
            "provider"
        )]
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
        [string]$ProviderId
    )

    $values = @{
        tenant = $TenantId
        client = $ClientId
        project = $ProjectId
        worker = $WorkerId
        connector = $ConnectorId
        provider = $ProviderId
    }

    $selected = [string]$values[$Scope]

    if ([string]::IsNullOrWhiteSpace($selected)) {
        throw "Contexte $Scope incomplet."
    }

    if ($selected.Length -gt 200) {
        throw "Identifiant $Scope trop long."
    }

    if ($selected -match '[\r\n]') {
        throw "Identifiant $Scope invalide."
    }

    $raw = "scope=$Scope|id=$selected"

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)

    return "${Scope}:" + (
        [System.BitConverter]::ToString($hash)
    ).Replace("-","").ToLowerInvariant()
}

function Get-CircuitStateMap {

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    if (-not (Test-Path -LiteralPath $StatePath)) {
        return @{}
    }

    $raw = Get-Content `
        -LiteralPath $StatePath `
        -Raw `
        -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    $object = $raw | ConvertFrom-Json

    $map = @{}

    foreach ($property in $object.PSObject.Properties) {
        $map[$property.Name] = $property.Value
    }

    return $map
}

function Save-CircuitStateMap {
    param(
        [hashtable]$Map
    )

    if ($null -eq $Map) {
        throw "Map état requise."
    }

    $config = Get-CircuitBreakerConfig

    if ($Map.Count -gt [int]$config.maxStateEntries) {
        throw "Nombre maximal d'états dépassé."
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    $Map |
        ConvertTo-Json -Depth 10 |
        Set-Content `
            -LiteralPath $StatePath `
            -Encoding UTF8

    return $true
}

function New-EmptyCircuitState {

    return [ordered]@{
        State = "CLOSED"
        FailureCount = 0
        SuccessCount = 0
        OpenedAtUtc = $null
        LastFailureAtUtc = $null
        LastSuccessAtUtc = $null
        UpdatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Get-CircuitState {

    param(
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        throw "Key requise."
    }

    $map = Get-CircuitStateMap

    if (-not $map.ContainsKey($Key)) {
        return [pscustomobject](New-EmptyCircuitState)
    }

    return $map[$Key]
}

function Set-CircuitState {

    param(
        [string]$Key,
        [ValidateSet("CLOSED","OPEN","HALF_OPEN")]
        [string]$State,
        [int]$FailureCount = 0,
        [int]$SuccessCount = 0,
        [AllowEmptyString()]
        [string]$OpenedAtUtc,
        [AllowEmptyString()]
        [string]$LastFailureAtUtc,
        [AllowEmptyString()]
        [string]$LastSuccessAtUtc
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        throw "Key requise."
    }

    if ($FailureCount -lt 0) {
        throw "FailureCount invalide."
    }

    if ($SuccessCount -lt 0) {
        throw "SuccessCount invalide."
    }

    $map = Get-CircuitStateMap

    $map[$Key] = [ordered]@{
        State = $State
        FailureCount = $FailureCount
        SuccessCount = $SuccessCount
        OpenedAtUtc = $OpenedAtUtc
        LastFailureAtUtc = $LastFailureAtUtc
        LastSuccessAtUtc = $LastSuccessAtUtc
        UpdatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    Save-CircuitStateMap -Map $map | Out-Null

    return $true
}

function Test-CircuitAccess {

    param(
        [string]$Key
    )

    $config = Get-CircuitBreakerConfig

    if (-not $config.enabled -or -not $config.circuitBreakerEnabled) {

        return [pscustomobject]@{
            Allowed = $true
            State = "DISABLED"
            Reason = "Circuit breaker desactive."
        }
    }

    if ([string]::IsNullOrWhiteSpace($Key)) {

        return [pscustomobject]@{
            Allowed = $false
            State = "OPEN"
            Reason = "Key manquante."
        }
    }

    $state = Get-CircuitState -Key $Key

    if ($state.State -eq "CLOSED") {

        return [pscustomobject]@{
            Allowed = $true
            State = "CLOSED"
            Reason = "Circuit disponible."
        }
    }

    if ($state.State -eq "HALF_OPEN") {

        return [pscustomobject]@{
            Allowed = $true
            State = "HALF_OPEN"
            Reason = "Tentative de recuperation."
        }
    }

    if ($state.State -eq "OPEN") {

        if ([string]::IsNullOrWhiteSpace([string]$state.OpenedAtUtc)) {

            return [pscustomobject]@{
                Allowed = $false
                State = "OPEN"
                Reason = "Circuit ouvert sans horodatage."
            }
        }

        $cooldown = [double]$config.cooldownSeconds

        try {

            $opened = [DateTimeOffset]::Parse(
                [string]$state.OpenedAtUtc
            ).ToUniversalTime()

            $now = [DateTimeOffset]::UtcNow

            $age = ($now - $opened).TotalSeconds

            if ($age -ge $cooldown) {

                Set-CircuitState `
                    -Key $Key `
                    -State "HALF_OPEN" `
                    -FailureCount ([int]$state.FailureCount) `
                    -SuccessCount 0 `
                    -OpenedAtUtc ([string]$state.OpenedAtUtc) `
                    -LastFailureAtUtc ([string]$state.LastFailureAtUtc) `
                    -LastSuccessAtUtc ([string]$state.LastSuccessAtUtc) | Out-Null

                return [pscustomobject]@{
                    Allowed = $true
                    State = "HALF_OPEN"
                    Reason = "Cooldown termine."
                }
            }
        }
        catch {

            return [pscustomobject]@{
                Allowed = $false
                State = "OPEN"
                Reason = "Horodatage du circuit invalide."
            }
        }

        return [pscustomobject]@{
            Allowed = $false
            State = "OPEN"
            Reason = "Circuit ouvert pendant cooldown."
        }
    }

    return [pscustomobject]@{
        Allowed = $false
        State = "OPEN"
        Reason = "Etat circuit invalide."
    }
}
function Register-CircuitSuccess {

    param(
        [string]$Key
    )

    $config = Get-CircuitBreakerConfig
    $state = Get-CircuitState -Key $Key
    $now = (Get-Date).ToUniversalTime().ToString("o")

    if ($state.State -eq "HALF_OPEN") {

        $newSuccess = [int]$state.SuccessCount + 1

        if ($newSuccess -ge [int]$config.successThreshold) {

            Set-CircuitState `
                -Key $Key `
                -State "CLOSED" `
                -FailureCount 0 `
                -SuccessCount 0 `
                -OpenedAtUtc "" `
                -LastFailureAtUtc $state.LastFailureAtUtc `
                -LastSuccessAtUtc $now | Out-Null

            return [pscustomobject]@{
                State = "CLOSED"
                SuccessCount = 0
                Recovered = $true
            }
        }

        Set-CircuitState `
            -Key $Key `
            -State "HALF_OPEN" `
            -FailureCount $state.FailureCount `
            -SuccessCount $newSuccess `
            -OpenedAtUtc $state.OpenedAtUtc `
            -LastFailureAtUtc $state.LastFailureAtUtc `
            -LastSuccessAtUtc $now | Out-Null

        return [pscustomobject]@{
            State = "HALF_OPEN"
            SuccessCount = $newSuccess
            Recovered = $false
        }
    }

    Set-CircuitState `
        -Key $Key `
        -State "CLOSED" `
        -FailureCount 0 `
        -SuccessCount 0 `
        -OpenedAtUtc "" `
        -LastFailureAtUtc $state.LastFailureAtUtc `
        -LastSuccessAtUtc $now | Out-Null

    return [pscustomobject]@{
        State = "CLOSED"
        SuccessCount = 0
        Recovered = $false
    }
}

function Register-CircuitFailure {

    param(
        [string]$Key
    )

    $config = Get-CircuitBreakerConfig
    $state = Get-CircuitState -Key $Key
    $now = (Get-Date).ToUniversalTime().ToString("o")

    if ($state.State -eq "HALF_OPEN") {

        Set-CircuitState `
            -Key $Key `
            -State "OPEN" `
            -FailureCount ([int]$state.FailureCount + 1) `
            -SuccessCount 0 `
            -OpenedAtUtc $now `
            -LastFailureAtUtc $now `
            -LastSuccessAtUtc $state.LastSuccessAtUtc | Out-Null

        return [pscustomobject]@{
            State = "OPEN"
            FailureCount = [int]$state.FailureCount + 1
            Opened = $true
        }
    }

    $newFailure = [int]$state.FailureCount + 1

    if ($newFailure -ge [int]$config.failureThreshold) {

        Set-CircuitState `
            -Key $Key `
            -State "OPEN" `
            -FailureCount $newFailure `
            -SuccessCount 0 `
            -OpenedAtUtc $now `
            -LastFailureAtUtc $now `
            -LastSuccessAtUtc $state.LastSuccessAtUtc | Out-Null

        return [pscustomobject]@{
            State = "OPEN"
            FailureCount = $newFailure
            Opened = $true
        }
    }

    Set-CircuitState `
        -Key $Key `
        -State "CLOSED" `
        -FailureCount $newFailure `
        -SuccessCount 0 `
        -OpenedAtUtc "" `
        -LastFailureAtUtc $now `
        -LastSuccessAtUtc $state.LastSuccessAtUtc | Out-Null

    return [pscustomobject]@{
        State = "CLOSED"
        FailureCount = $newFailure
        Opened = $false
    }
}

function Reset-CircuitState {

    if (Test-Path -LiteralPath $StatePath) {
        Remove-Item -LiteralPath $StatePath -Force
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    return $true
}