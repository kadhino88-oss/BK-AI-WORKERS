$ErrorActionPreference = "Stop"

$RuntimeRoot = Split-Path -Parent $PSCommandPath
$StateDir = Join-Path $RuntimeRoot "state"
$ConfigPath = Join-Path $RuntimeRoot "RESOURCE-FAIRNESS-CONFIG.json"
$StatePath = Join-Path $StateDir "fairness-state.json"

function Get-ResourceFairnessConfig {

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration Resource Fairness introuvable."
    }

    return Get-Content `
        -LiteralPath $ConfigPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
}

function New-FairnessKey {

    param(
        [ValidateSet("tenant","client","project","worker")]
        [string]$Scope,

        [AllowEmptyString()]
        [string]$TenantId,

        [AllowEmptyString()]
        [string]$ClientId,

        [AllowEmptyString()]
        [string]$ProjectId,

        [AllowEmptyString()]
        [string]$WorkerId
    )

    $values = @{
        tenant = $TenantId
        client = $ClientId
        project = $ProjectId
        worker = $WorkerId
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

    $digest = (
        [System.BitConverter]::ToString($hash)
    ).Replace("-","").ToLowerInvariant()

    return ("{0}:{1}" -f $Scope,$digest)
}

function Get-FairnessStateMap {

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

function Save-FairnessStateMap {

    param(
        [hashtable]$Map
    )

    if ($null -eq $Map) {
        throw "Map de fairness requise."
    }

    $config = Get-ResourceFairnessConfig

    if ($Map.Count -gt [int]$config.maxActiveEntries) {
        throw "Nombre maximal d'entrées fairness atteint."
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    $Map |
        ConvertTo-Json -Depth 10 |
        Set-Content `
            -LiteralPath $StatePath `
            -Encoding UTF8

    return $true
}

function Get-FairnessEntry {

    param(
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        throw "Key requise."
    }

    $map = Get-FairnessStateMap

    if (-not $map.ContainsKey($Key)) {

        return [pscustomobject]@{
            Weight = [int](Get-ResourceFairnessConfig).defaultWeight
            Usage = 0
            Grants = 0
            Denials = 0
            UpdatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        }
    }

    return $map[$Key]
}

function Set-FairnessWeight {

    param(
        [string]$Key,
        [int]$Weight
    )

    $config = Get-ResourceFairnessConfig

    if ([string]::IsNullOrWhiteSpace($Key)) {
        throw "Key requise."
    }

    if (
        $Weight -lt [int]$config.minWeight -or
        $Weight -gt [int]$config.maxWeight
    ) {
        throw "Weight hors plage."
    }

    $map = Get-FairnessStateMap
    $entry = Get-FairnessEntry -Key $Key

    $map[$Key] = [ordered]@{
        Weight = $Weight
        Usage = [int]$entry.Usage
        Grants = [int]$entry.Grants
        Denials = [int]$entry.Denials
        UpdatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    Save-FairnessStateMap -Map $map | Out-Null

    return [int]$Weight
}

function Get-FairnessWeight {

    param(
        [string]$Key
    )

    return [int](Get-FairnessEntry -Key $Key).Weight
}

function Test-FairnessAdmission {

    param(
        [string]$Key,
        [int]$RequestedUnits = 1,
        [int]$CurrentGlobalUsage = 0
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        throw "Key requise."
    }

    if ($RequestedUnits -le 0) {
        throw "RequestedUnits doit être supérieur à zéro."
    }

    if ($CurrentGlobalUsage -lt 0) {
        throw "CurrentGlobalUsage invalide."
    }

    $config = Get-ResourceFairnessConfig
    $entry = Get-FairnessEntry -Key $Key

    $weight = [int]$entry.Weight

    # Score simple et déterministe :
    # usage pondéré = usage / weight
    $effectiveUsage = 0

    if ($weight -gt 0) {
        $effectiveUsage = [math]::Round(
            ([double]$entry.Usage / [double]$weight),
            4
        )
    }

    $requestedEffective = [math]::Round(
        (
            [double]$entry.Usage +
            [double]$RequestedUnits
        ) / [double]$weight,
        4
    )

    $globalEffective = [double]$CurrentGlobalUsage

    $allowed = ($requestedEffective -le $globalEffective + 1)

    return [pscustomobject]@{
        Allowed = [bool]$allowed
        Key = $Key
        Weight = $weight
        Usage = [int]$entry.Usage
        RequestedUnits = $RequestedUnits
        EffectiveUsage = $effectiveUsage
        RequestedEffectiveUsage = $requestedEffective
        GlobalReference = $globalEffective
    }
}

function Grant-FairnessUsage {

    param(
        [string]$Key,
        [int]$Units = 1
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        throw "Key requise."
    }

    if ($Units -le 0) {
        throw "Units doit être supérieur à zéro."
    }

    $map = Get-FairnessStateMap
    $entry = Get-FairnessEntry -Key $Key

    $map[$Key] = [ordered]@{
        Weight = [int]$entry.Weight
        Usage = [int]$entry.Usage + $Units
        Grants = [int]$entry.Grants + 1
        Denials = [int]$entry.Denials
        UpdatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    Save-FairnessStateMap -Map $map | Out-Null

    return [pscustomobject]@{
        Granted = $true
        Usage = [int]$map[$Key].Usage
        Grants = [int]$map[$Key].Grants
    }
}

function Register-FairnessDenial {

    param(
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        throw "Key requise."
    }

    $map = Get-FairnessStateMap
    $entry = Get-FairnessEntry -Key $Key

    $map[$Key] = [ordered]@{
        Weight = [int]$entry.Weight
        Usage = [int]$entry.Usage
        Grants = [int]$entry.Grants
        Denials = [int]$entry.Denials + 1
        UpdatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    Save-FairnessStateMap -Map $map | Out-Null

    return [int]$map[$Key].Denials
}

function Release-FairnessUsage {

    param(
        [string]$Key,
        [int]$Units = 1
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        throw "Key requise."
    }

    if ($Units -le 0) {
        throw "Units doit être supérieur à zéro."
    }

    $map = Get-FairnessStateMap
    $entry = Get-FairnessEntry -Key $Key

    $newUsage = [int]$entry.Usage - $Units

    if ($newUsage -lt 0) {
        $newUsage = 0
    }

    $map[$Key] = [ordered]@{
        Weight = [int]$entry.Weight
        Usage = $newUsage
        Grants = [int]$entry.Grants
        Denials = [int]$entry.Denials
        UpdatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    Save-FairnessStateMap -Map $map | Out-Null

    return [int]$newUsage
}

function Get-FairnessReport {

    $map = Get-FairnessStateMap

    $items = @()

    foreach ($key in $map.Keys) {

        $entry = $map[$key]

        $items += [pscustomobject]@{
            Key = $key
            Weight = [int]$entry.Weight
            Usage = [int]$entry.Usage
            Grants = [int]$entry.Grants
            Denials = [int]$entry.Denials
        }
    }

    return @($items)
}

function Reset-FairnessState {

    if (Test-Path -LiteralPath $StatePath) {
        Remove-Item -LiteralPath $StatePath -Force
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    return $true
}