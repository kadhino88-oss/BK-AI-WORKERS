$ErrorActionPreference = "Stop"

$RuntimeRoot = Split-Path -Parent $PSCommandPath
$StateDir = Join-Path $RuntimeRoot "state"
$ConfigPath = Join-Path $RuntimeRoot "ADMISSION-CONTROL-CONFIG.json"
$StatePath = Join-Path $StateDir "admission-state.json"

function Get-AdmissionControlConfig {

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration Admission Control introuvable."
    }

    return Get-Content `
        -LiteralPath $ConfigPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
}

function New-AdmissionKey {

    param(
        [ValidateSet(
            "global",
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

    if ($Scope -eq "global") {
        return "global"
    }

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
    $digest = (
        [System.BitConverter]::ToString($hash)
    ).Replace("-","").ToLowerInvariant()

    return ("{0}:{1}" -f $Scope,$digest)
}

function Get-AdmissionStateMap {

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
        $map[$property.Name] = [int]$property.Value
    }

    return $map
}

function Save-AdmissionStateMap {

    param(
        [hashtable]$Map
    )

    if ($null -eq $Map) {
        throw "Map Etat requise."
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    $Map |
        ConvertTo-Json -Depth 10 |
        Set-Content `
            -LiteralPath $StatePath `
            -Encoding UTF8

    return $true
}

function Get-AdmissionCount {

    param(
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        throw "Key requise."
    }

    $map = Get-AdmissionStateMap

    if ($map.ContainsKey($Key)) {
        return [int]$map[$Key]
    }

    return 0
}

function Enter-AdmissionSlot {

    param(
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        throw "Key requise."
    }

    $map = Get-AdmissionStateMap

    if (-not $map.ContainsKey($Key)) {
        $map[$Key] = 0
    }

    $map[$Key] = [int]$map[$Key] + 1

    Save-AdmissionStateMap -Map $map | Out-Null

    return [int]$map[$Key]
}

function Leave-AdmissionSlot {

    param(
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        throw "Key requise."
    }

    $map = Get-AdmissionStateMap

    if (-not $map.ContainsKey($Key)) {
        return 0
    }

    $newValue = [int]$map[$Key] - 1

    if ($newValue -lt 0) {
        $newValue = 0
    }

    $map[$Key] = $newValue

    Save-AdmissionStateMap -Map $map | Out-Null

    return $newValue
}

function Get-AdmissionLimit {

    param(
        [ValidateSet(
            "global",
            "tenant",
            "client",
            "project",
            "worker",
            "connector",
            "provider"
        )]
        [string]$Scope
    )

    $config = Get-AdmissionControlConfig

    switch ($Scope) {
        "global"    { return [int]$config.maxGlobalInFlight }
        "tenant"    { return [int]$config.maxTenantInFlight }
        "client"    { return [int]$config.maxClientInFlight }
        "project"   { return [int]$config.maxProjectInFlight }
        "worker"    { return [int]$config.maxWorkerInFlight }
        "connector" { return [int]$config.maxConnectorInFlight }
        "provider"  { return [int]$config.maxProviderInFlight }
    }

    throw "Scope inconnue."
}

function Test-Admission {

    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [string]$ConnectorId,
        [string]$ProviderId,
        [int]$Priority = 50
    )

    $config = Get-AdmissionControlConfig

    if (-not $config.enabled -or -not $config.admissionControlEnabled) {

        return [pscustomobject]@{
            Allowed = $true
            Reason = "Admission control desactive."
            Bypassed = $true
        }
    }

    if ($Priority -lt 0 -or $Priority -gt 100) {
        throw "Priority invalide."
    }

    $keys = @(
        @{
            Scope = "global"
            Key = New-AdmissionKey -Scope global
        },
        @{
            Scope = "tenant"
            Key = New-AdmissionKey -Scope tenant -TenantId $TenantId
        },
        @{
            Scope = "client"
            Key = New-AdmissionKey -Scope client -ClientId $ClientId
        },
        @{
            Scope = "project"
            Key = New-AdmissionKey -Scope project -ProjectId $ProjectId
        },
        @{
            Scope = "worker"
            Key = New-AdmissionKey -Scope worker -WorkerId $WorkerId
        },
        @{
            Scope = "connector"
            Key = New-AdmissionKey -Scope connector -ConnectorId $ConnectorId
        },
        @{
            Scope = "provider"
            Key = New-AdmissionKey -Scope provider -ProviderId $ProviderId
        }
    )

    $bypass = (
        $config.allowPriorityBypass -eq $true -and
        $Priority -ge [int]$config.priorityBypassLevel
    )

    foreach ($item in $keys) {

        $count = Get-AdmissionCount -Key $item.Key
        $limit = Get-AdmissionLimit -Scope $item.Scope

        if ($count -ge $limit) {

            if ($bypass) {
                continue
            }

            return [pscustomobject]@{
                Allowed = $false
                Reason = "Capacity $($item.Scope) atteinte."
                Bypassed = $false
                Scope = $item.Scope
                Count = $count
                Limit = $limit
            }
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Reason = "Execution admise."
        Bypassed = $bypass
        Scope = $null
        Count = 0
        Limit = 0
    }
}

function Enter-ExecutionAdmission {

    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [string]$ConnectorId,
        [string]$ProviderId,
        [int]$Priority = 50
    )

    $decision = Test-Admission `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -WorkerId $WorkerId `
        -ConnectorId $ConnectorId `
        -ProviderId $ProviderId `
        -Priority $Priority

    if (-not $decision.Allowed) {
        return [pscustomobject]@{
            Entered = $false
            Decision = $decision
            Keys = @()
        }
    }

    $keys = @(
        New-AdmissionKey -Scope global
        New-AdmissionKey -Scope tenant -TenantId $TenantId
        New-AdmissionKey -Scope client -ClientId $ClientId
        New-AdmissionKey -Scope project -ProjectId $ProjectId
        New-AdmissionKey -Scope worker -WorkerId $WorkerId
        New-AdmissionKey -Scope connector -ConnectorId $ConnectorId
        New-AdmissionKey -Scope provider -ProviderId $ProviderId
    )

    foreach ($key in $keys) {
        Enter-AdmissionSlot -Key $key | Out-Null
    }

    return [pscustomobject]@{
        Entered = $true
        Decision = $decision
        Keys = $keys
    }
}

function Leave-ExecutionAdmission {

    param(
        [string[]]$Keys
    )

    if ($null -eq $Keys -or $Keys.Count -eq 0) {
        return $false
    }

    foreach ($key in $Keys) {
        Leave-AdmissionSlot -Key $key | Out-Null
    }

    return $true
}

function Get-AdmissionStatus {

    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [string]$ConnectorId,
        [string]$ProviderId
    )

    $scopes = @(
        @{
            Scope = "global"
            Key = New-AdmissionKey -Scope global
        },
        @{
            Scope = "tenant"
            Key = New-AdmissionKey -Scope tenant -TenantId $TenantId
        },
        @{
            Scope = "client"
            Key = New-AdmissionKey -Scope client -ClientId $ClientId
        },
        @{
            Scope = "project"
            Key = New-AdmissionKey -Scope project -ProjectId $ProjectId
        },
        @{
            Scope = "worker"
            Key = New-AdmissionKey -Scope worker -WorkerId $WorkerId
        },
        @{
            Scope = "connector"
            Key = New-AdmissionKey -Scope connector -ConnectorId $ConnectorId
        },
        @{
            Scope = "provider"
            Key = New-AdmissionKey -Scope provider -ProviderId $ProviderId
        }
    )

    $results = @()

    foreach ($item in $scopes) {

        $count = Get-AdmissionCount -Key $item.Key
        $limit = Get-AdmissionLimit -Scope $item.Scope

        $results += [pscustomobject]@{
            Scope = $item.Scope
            InFlight = $count
            Limit = $limit
            Available = [math]::Max(0,($limit - $count))
        }
    }

    return @($results)
}

function Reset-AdmissionState {

    if (Test-Path -LiteralPath $StatePath) {
        Remove-Item -LiteralPath $StatePath -Force
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    return $true
}