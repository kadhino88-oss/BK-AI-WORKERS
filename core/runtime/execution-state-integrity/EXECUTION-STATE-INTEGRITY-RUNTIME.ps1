$ErrorActionPreference = "Stop"

$RuntimeRoot = Split-Path -Parent $PSCommandPath
$StateDir = Join-Path $RuntimeRoot "state"
$ConfigPath = Join-Path $RuntimeRoot "EXECUTION-STATE-INTEGRITY-CONFIG.json"
$StatePath = Join-Path $StateDir "execution-states.json"

function Get-StateIntegrityConfig {

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration State Integrity introuvable."
    }

    return Get-Content `
        -LiteralPath $ConfigPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
}

function Get-StateMap {

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

function Save-StateMap {

    param(
        [hashtable]$Map
    )

    if ($null -eq $Map) {
        throw "Map state requise."
    }

    $config = Get-StateIntegrityConfig

    if ($Map.Count -gt [int]$config.maxExecutions) {
        throw "Nombre maximal d'executions atteint."
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    $Map |
        ConvertTo-Json -Depth 20 |
        Set-Content `
            -LiteralPath $StatePath `
            -Encoding UTF8

    return $true
}

function Get-StateField {

    param(
        [object]$InputObject,
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {

        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }

        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]

    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Convert-ToStateHashtable {

    param(
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        throw "Objet state requis."
    }

    $result = [ordered]@{}

    foreach ($field in @(
        "ExecutionId",
        "TenantId",
        "ClientId",
        "ProjectId",
        "WorkerId",
        "Version",
        "Stage",
        "Status",
        "StateData",
        "StateHash",
        "CreatedAtUtc",
        "UpdatedAtUtc"
    )) {

        $value = Get-StateField `
            -InputObject $InputObject `
            -Name $field

        if ($null -ne $value) {
            $result[$field] = $value
        }
    }

    return $result
}

function Get-CanonicalStateJson {

    param(
        [object]$StateData
    )

    if ($null -eq $StateData) {
        throw "StateData requis."
    }

    return $StateData |
        ConvertTo-Json -Depth 20 -Compress
}

function Get-StateHash {

    param(
        [object]$StateData
    )

    $canonical = Get-CanonicalStateJson -StateData $StateData

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)

    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        $bytes
    )

    return (
        [System.BitConverter]::ToString($hash)
    ).Replace("-","").ToLowerInvariant()
}

function New-ExecutionState {

    param(
        [string]$ExecutionId,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [int]$Version = 1,
        [string]$Stage,
        [ValidateSet("RUNNING","PAUSED","COMPLETED","FAILED","READY")]
        [string]$Status,
        [object]$StateData
    )

    foreach ($value in @(
        $ExecutionId,
        $TenantId,
        $ClientId,
        $ProjectId,
        $WorkerId,
        $Stage
    )) {

        if ($value -and $value -match '[\r\n]') {
            throw "Valeur invalide."
        }
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId requis."
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw "TenantId requis."
    }

    if ($Version -lt 1) {
        throw "Version invalide."
    }

    if ([string]::IsNullOrWhiteSpace($Stage)) {
        throw "Stage requis."
    }

    if ($null -eq $StateData) {
        throw "StateData requis."
    }

    $hash = Get-StateHash -StateData $StateData
    $now = (Get-Date).ToUniversalTime().ToString("o")

    return [ordered]@{
        ExecutionId = $ExecutionId
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        WorkerId = $WorkerId
        Version = $Version
        Stage = $Stage
        Status = $Status
        StateData = $StateData
        StateHash = $hash
        CreatedAtUtc = $now
        UpdatedAtUtc = $now
    }
}

function Save-ExecutionState {

    param(
        [object]$State
    )

    $config = Get-StateIntegrityConfig

    if (-not $config.enabled -or -not $config.integrityEnabled) {
        throw "State Integrity desactive."
    }

    if ($null -eq $State) {
        throw "State requis."
    }

    $executionId = [string](
        Get-StateField $State "ExecutionId"
    )

    $tenantId = [string](
        Get-StateField $State "TenantId"
    )

    if ([string]::IsNullOrWhiteSpace($executionId)) {
        throw "ExecutionId requis."
    }

    if ([string]::IsNullOrWhiteSpace($tenantId)) {
        throw "TenantId requis."
    }

    $map = Get-StateMap

    $existingVersions = @(
        $map.Values |
        Where-Object {
            [string](
                Get-StateField $_ "ExecutionId"
            ) -eq $executionId
        }
    ).Count

    if ($existingVersions -ge [int]$config.maxVersionsPerExecution) {

        $sameExecution = @(
            $map.Keys |
            Where-Object {
                [string](
                    Get-StateField $map[$_] "ExecutionId"
                ) -eq $executionId
            }
        )

        if ($sameExecution.Count -gt 0) {
            $oldestKey = $sameExecution |
                Sort-Object {
                    [int](
                        Get-StateField $map[$_] "Version"
                    )
                } |
                Select-Object -First 1

            $map.Remove($oldestKey)
        }
    }

    $normalized = Convert-ToStateHashtable -InputObject $State

    $stateData = Get-StateField `
        -InputObject $State `
        -Name "StateData"

    if ($null -eq $stateData) {
        throw "StateData requis."
    }

    $normalized["StateHash"] = Get-StateHash -StateData $stateData
    $normalized["UpdatedAtUtc"] = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    if (-not $normalized.Contains("CreatedAtUtc")) {
        $normalized["CreatedAtUtc"] = (
            Get-Date
        ).ToUniversalTime().ToString("o")
    }

    $version = Get-StateField `
        -InputObject $State `
        -Name "Version"

    if ($null -eq $version -or [int]$version -lt 1) {
        throw "Version invalide."
    }

    $key = "{0}:v{1}" -f `
        $executionId,
        ([int]$version)

    $map[$key] = $normalized

    Save-StateMap -Map $map | Out-Null

    return $true
}

function Get-ExecutionStates {

    param(
        [string]$ExecutionId,
        [AllowEmptyString()]
        [string]$TenantId,
        [AllowEmptyString()]
        [string]$ProjectId
    )

    $map = Get-StateMap
    $result = @()

    foreach ($item in $map.Values) {

        $itemExecution = [string](
            Get-StateField $item "ExecutionId"
        )

        $itemTenant = [string](
            Get-StateField $item "TenantId"
        )

        $itemProject = [string](
            Get-StateField $item "ProjectId"
        )

        if ($ExecutionId -and $itemExecution -ne $ExecutionId) {
            continue
        }

        if ($TenantId -and $itemTenant -ne $TenantId) {
            continue
        }

        if ($ProjectId -and $itemProject -ne $ProjectId) {
            continue
        }

        $normalized = Convert-ToStateHashtable -InputObject $item

        $result += [pscustomobject]$normalized
    }

    return @($result)
}

function Get-LatestExecutionState {

    param(
        [string]$ExecutionId,
        [string]$TenantId
    )

    $states = @(
        Get-ExecutionStates `
            -ExecutionId $ExecutionId `
            -TenantId $TenantId
    )

    if ($states.Count -eq 0) {
        return $null
    }

    return $states |
        Sort-Object {
            [int]$_.Version
        } |
        Select-Object -Last 1
}

function Test-StateIntegrity {

    param(
        [string]$ExecutionId,
        [int]$Version,
        [string]$TenantId
    )

    $states = @(
        Get-ExecutionStates `
            -ExecutionId $ExecutionId `
            -TenantId $TenantId
    )

    $state = $states |
        Where-Object {
            [int]$_.Version -eq $Version
        } |
        Select-Object -First 1

    if ($null -eq $state) {

        return [pscustomobject]@{
            Valid = $false
            Reason = "Etat introuvable."
        }
    }

    $currentHash = Get-StateHash `
        -StateData $state.StateData

    if ($currentHash -ne $state.StateHash) {

        return [pscustomobject]@{
            Valid = $false
            Reason = "Hash d'integrite invalide."
        }
    }

    return [pscustomobject]@{
        Valid = $true
        Reason = "Integrite valide."
        State = $state
    }
}

function Update-ExecutionState {

    param(
        [string]$ExecutionId,
        [string]$TenantId,
        [int]$Version,
        [string]$Stage,
        [ValidateSet("RUNNING","PAUSED","COMPLETED","FAILED","READY")]
        [string]$Status,
        [object]$StateData
    )

    $validation = Test-StateIntegrity `
        -ExecutionId $ExecutionId `
        -Version $Version `
        -TenantId $TenantId

    if (-not $validation.Valid) {
        return $false
    }

    $current = $validation.State

    $next = New-ExecutionState `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId `
        -ClientId ([string]$current.ClientId) `
        -ProjectId ([string]$current.ProjectId) `
        -WorkerId ([string]$current.WorkerId) `
        -Version ($Version + 1) `
        -Stage $Stage `
        -Status $Status `
        -StateData $StateData

    Save-ExecutionState -State $next | Out-Null

    return $true
}

function Reset-StateIntegrity {

    if (Test-Path -LiteralPath $StatePath) {
        Remove-Item -LiteralPath $StatePath -Force
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    return $true
}