$ErrorActionPreference = "Stop"

$RuntimeRoot = Split-Path -Parent $PSCommandPath
$StateDir = Join-Path $RuntimeRoot "state"
$ConfigPath = Join-Path $RuntimeRoot "EXECUTION-DEPENDENCY-CONFIG.json"
$StatePath = Join-Path $StateDir "dependencies.json"

function Get-DependencyConfig {

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration Dependency Manager introuvable."
    }

    return Get-Content `
        -LiteralPath $ConfigPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
}

function Get-DependencyMap {

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

function Save-DependencyMap {

    param(
        [hashtable]$Map
    )

    if ($null -eq $Map) {
        throw "Map Dependency requise."
    }

    $config = Get-DependencyConfig

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

function Get-DependencyField {

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

function Convert-ToDependencyRecord {

    param(
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        throw "Record Dependency requis."
    }

    $result = [ordered]@{}

    foreach ($field in @(
        "ExecutionId",
        "TenantId",
        "ClientId",
        "ProjectId",
        "WorkerId",
        "Status",
        "Dependencies",
        "CreatedAtUtc",
        "UpdatedAtUtc"
    )) {

        $result[$field] = Get-DependencyField `
            -InputObject $InputObject `
            -Name $field
    }

    if ($null -eq $result["Dependencies"]) {
        $result["Dependencies"] = @()
    }
    else {
        $result["Dependencies"] = @(
            $result["Dependencies"] |
            ForEach-Object { [string]$_ }
        )
    }

    return $result
}

function New-DependencyExecution {

    param(
        [string]$ExecutionId,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [ValidateSet(
            "WAITING",
            "READY",
            "RUNNING",
            "COMPLETED",
            "FAILED",
            "CANCELLED"
        )]
        [string]$Status = "WAITING"
    )

    foreach ($value in @(
        $ExecutionId,
        $TenantId,
        $ClientId,
        $ProjectId,
        $WorkerId
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

    return [ordered]@{
        ExecutionId = $ExecutionId
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        WorkerId = $WorkerId
        Status = $Status
        Dependencies = @()
        CreatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        UpdatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Save-DependencyExecution {

    param(
        [object]$Execution
    )

    if ($null -eq $Execution) {
        throw "Execution requise."
    }

    $record = Convert-ToDependencyRecord -InputObject $Execution

    if ([string]::IsNullOrWhiteSpace(
        [string]$record["ExecutionId"]
    )) {
        throw "ExecutionId requis."
    }

    if ([string]::IsNullOrWhiteSpace(
        [string]$record["TenantId"]
    )) {
        throw "TenantId requis."
    }

    $map = Get-DependencyMap

    $map[$record["ExecutionId"]] = $record

    Save-DependencyMap -Map $map | Out-Null

    return $true
}

function Get-DependencyExecution {

    param(
        [string]$ExecutionId,
        [AllowEmptyString()]
        [string]$TenantId
    )

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId requis."
    }

    $map = Get-DependencyMap

    if (-not $map.ContainsKey($ExecutionId)) {
        return $null
    }

    $record = Convert-ToDependencyRecord `
        -InputObject $map[$ExecutionId]

    if (
        $TenantId -and
        [string]$record["TenantId"] -ne $TenantId
    ) {
        return $null
    }

    return [pscustomobject]$record
}

function Get-ExecutionDependencies {

    param(
        [string]$ExecutionId,
        [string]$TenantId
    )

    $execution = Get-DependencyExecution `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId

    if ($null -eq $execution) {
        return @()
    }

    return @(
        $execution.Dependencies
    )
}

function Test-DependencyCycle {

    param(
        [string]$ExecutionId,
        [string]$DependencyId,
        [hashtable]$Graph
    )

    if ($ExecutionId -eq $DependencyId) {
        return $true
    }

    $visited = @{}

    function Visit-Node {

        param(
            [string]$Node
        )

        if ($Node -eq $ExecutionId) {
            return $true
        }

        if ($visited.ContainsKey($Node)) {
            return $false
        }

        $visited[$Node] = $true

        if (-not $Graph.ContainsKey($Node)) {
            return $false
        }

        foreach ($next in @($Graph[$Node])) {

            if (Visit-Node -Node ([string]$next)) {
                return $true
            }
        }

        return $false
    }

    return [bool](Visit-Node -Node $DependencyId)
}

function Add-ExecutionDependency {

    param(
        [string]$ExecutionId,
        [string]$TenantId,
        [string]$DependencyId
    )

    $config = Get-DependencyConfig

    if (-not $config.dependencyManagerEnabled) {
        throw "Dependency Manager desactive."
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId requis."
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw "TenantId requis."
    }

    if ([string]::IsNullOrWhiteSpace($DependencyId)) {
        throw "DependencyId requis."
    }

    if ($ExecutionId -eq $DependencyId) {
        return [pscustomobject]@{
            Added = $false
            Reason = "Auto-dependance interdite."
        }
    }

    $map = Get-DependencyMap

    if (-not $map.ContainsKey($ExecutionId)) {
        return [pscustomobject]@{
            Added = $false
            Reason = "Execution introuvable."
        }
    }

    if (-not $map.ContainsKey($DependencyId)) {
        return [pscustomobject]@{
            Added = $false
            Reason = "Dependency introuvable."
        }
    }

    $target = Convert-ToDependencyRecord `
        -InputObject $map[$ExecutionId]

    $dependency = Convert-ToDependencyRecord `
        -InputObject $map[$DependencyId]

    if (
        [string]$target["TenantId"] -ne $TenantId
    ) {
        return [pscustomobject]@{
            Added = $false
            Reason = "Isolation tenant refusee."
        }
    }

    if (
        [string]$dependency["TenantId"] -ne $TenantId
    ) {
        return [pscustomobject]@{
            Added = $false
            Reason = "Dependency cross-tenant refusee."
        }
    }

    $dependencies = @($target["Dependencies"])

    if ($dependencies -contains $DependencyId) {
        return [pscustomobject]@{
            Added = $false
            Reason = "Dependency deja presente."
        }
    }

    if (
        $dependencies.Count -ge
        [int]$config.maxDependenciesPerExecution
    ) {
        return [pscustomobject]@{
            Added = $false
            Reason = "Nombre maximal de dependances atteint."
        }
    }

    $graph = @{}

    foreach ($key in $map.Keys) {

        $record = Convert-ToDependencyRecord `
            -InputObject $map[$key]

        $graph[$key] = @(
            $record["Dependencies"]
        )
    }

    $candidate = @(
        $dependencies + $DependencyId
    )

    $graph[$ExecutionId] = $candidate

    if ($config.cycleDetectionEnabled) {

        if (
            Test-DependencyCycle `
                -ExecutionId $ExecutionId `
                -DependencyId $DependencyId `
                -Graph $graph
        ) {

            return [pscustomobject]@{
                Added = $false
                Reason = "Cycle de dependance detecte."
            }
        }
    }

    $target["Dependencies"] = $candidate
    $target["UpdatedAtUtc"] = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    $map[$ExecutionId] = $target

    Save-DependencyMap -Map $map | Out-Null

    return [pscustomobject]@{
        Added = $true
        Reason = "Dependency ajoutee."
    }
}

function Set-DependencyExecutionStatus {

    param(
        [string]$ExecutionId,
        [string]$TenantId,
        [ValidateSet(
            "WAITING",
            "READY",
            "RUNNING",
            "COMPLETED",
            "FAILED",
            "CANCELLED"
        )]
        [string]$Status
    )

    $execution = Get-DependencyExecution `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId

    if ($null -eq $execution) {
        return $false
    }

    $record = Convert-ToDependencyRecord `
        -InputObject $execution

    $record["Status"] = $Status
    $record["UpdatedAtUtc"] = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    Save-DependencyExecution `
        -Execution $record | Out-Null

    return $true
}

function Test-PrerequisitesSatisfied {

    param(
        [string]$ExecutionId,
        [string]$TenantId
    )

    $config = Get-DependencyConfig

    if (-not $config.prerequisiteChecksEnabled) {
        return $true
    }

    $execution = Get-DependencyExecution `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId

    if ($null -eq $execution) {
        return $false
    }

    foreach ($dependencyId in @(
        $execution.Dependencies
    )) {

        $dependency = Get-DependencyExecution `
            -ExecutionId ([string]$dependencyId) `
            -TenantId $TenantId

        if ($null -eq $dependency) {
            return $false
        }

        if ([string]$dependency.Status -ne "COMPLETED") {
            return $false
        }
    }

    return $true
}

function Test-ExecutionReady {

    param(
        [string]$ExecutionId,
        [string]$TenantId
    )

    $execution = Get-DependencyExecution `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId

    if ($null -eq $execution) {
        return $false
    }

    if (
        [string]$execution.Status -in @(
            "COMPLETED",
            "FAILED",
            "CANCELLED"
        )
    ) {
        return $false
    }

    return [bool](
        Test-PrerequisitesSatisfied `
            -ExecutionId $ExecutionId `
            -TenantId $TenantId
    )
}

function Reset-DependencyState {

    if (Test-Path -LiteralPath $StatePath) {
        Remove-Item -LiteralPath $StatePath -Force
    }

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $StateDir | Out-Null

    return $true
}