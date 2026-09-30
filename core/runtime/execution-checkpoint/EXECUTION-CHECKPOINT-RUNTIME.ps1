$ErrorActionPreference = "Stop"

$RuntimeRoot = Split-Path -Parent $PSCommandPath
$StateDir = Join-Path $RuntimeRoot "state"
$ConfigPath = Join-Path $RuntimeRoot "EXECUTION-CHECKPOINT-CONFIG.json"
$StatePath = Join-Path $StateDir "checkpoints.json"

function Get-CheckpointConfig {

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration Checkpoint introuvable."
    }

    return Get-Content `
        -LiteralPath $ConfigPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
}

function Get-CheckpointMap {

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

function Save-CheckpointMap {

    param(
        [hashtable]$Map
    )

    if ($null -eq $Map) {
        throw "Map checkpoint requise."
    }

    $config = Get-CheckpointConfig

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

function Get-CheckpointField {

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

function New-Checkpoint {

    param(
        [string]$ExecutionId,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [int]$Sequence,
        [string]$Stage,
        [string]$Status,
        [string]$StateHash
    )

    foreach ($value in @(
        $ExecutionId,
        $TenantId,
        $ClientId,
        $ProjectId,
        $WorkerId,
        $Stage,
        $Status,
        $StateHash
    )) {

        if ($value -and $value -match '[\r\n]') {
            throw "Valeur checkpoint invalide."
        }
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId requis."
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw "TenantId requis."
    }

    if ($Sequence -lt 0) {
        throw "Sequence invalide."
    }

    if ([string]::IsNullOrWhiteSpace($Stage)) {
        throw "Stage requis."
    }

    if ([string]::IsNullOrWhiteSpace($Status)) {
        throw "Status requis."
    }

    if ([string]::IsNullOrWhiteSpace($StateHash)) {
        throw "StateHash requis."
    }

    return [ordered]@{
        CheckpointId = [Guid]::NewGuid().ToString()
        ExecutionId = $ExecutionId
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        WorkerId = $WorkerId
        Sequence = $Sequence
        Stage = $Stage
        Status = $Status
        StateHash = $StateHash
        CreatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        ValidatedAtUtc = $null
        ResumedAtUtc = $null
    }
}

function Save-Checkpoint {

    param(
        [object]$Checkpoint
    )

    $config = Get-CheckpointConfig

    if (-not $config.enabled -or -not $config.checkpointEnabled) {
        throw "Checkpoint desactive."
    }

    if ($null -eq $Checkpoint) {
        throw "Checkpoint requis."
    }

    $executionId = [string](
        Get-CheckpointField `
            -InputObject $Checkpoint `
            -Name "ExecutionId"
    )

    if ([string]::IsNullOrWhiteSpace($executionId)) {
        throw "ExecutionId requis."
    }

    $map = Get-CheckpointMap

    $existingForExecution = @(
        $map.Values |
        Where-Object {
            [string](
                Get-CheckpointField $_ "ExecutionId"
            ) -eq $executionId
        }
    ).Count

    if ($existingForExecution -ge [int]$config.maxCheckpointsPerExecution) {
        throw "Nombre maximal de checkpoints atteint."
    }

    $normalized = [ordered]@{}

    foreach ($field in @(
        "CheckpointId",
        "ExecutionId",
        "TenantId",
        "ClientId",
        "ProjectId",
        "WorkerId",
        "Sequence",
        "Stage",
        "Status",
        "StateHash",
        "CreatedAtUtc",
        "ValidatedAtUtc",
        "ResumedAtUtc"
    )) {

        $normalized[$field] = Get-CheckpointField `
            -InputObject $Checkpoint `
            -Name $field
    }

    if ([string]::IsNullOrWhiteSpace(
        [string]$normalized["CheckpointId"]
    )) {
        $normalized["CheckpointId"] = [Guid]::NewGuid().ToString()
    }

    $map[$normalized["CheckpointId"]] = $normalized

    Save-CheckpointMap -Map $map | Out-Null

    return $true
}

function Get-Checkpoints {

    param(
        [string]$ExecutionId,
        [AllowEmptyString()]
        [string]$TenantId,
        [AllowEmptyString()]
        [string]$ProjectId
    )

    $map = Get-CheckpointMap
    $result = @()

    foreach ($item in $map.Values) {

        $itemExecution = [string](
            Get-CheckpointField $item "ExecutionId"
        )

        $itemTenant = [string](
            Get-CheckpointField $item "TenantId"
        )

        $itemProject = [string](
            Get-CheckpointField $item "ProjectId"
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

        $result += [pscustomobject]$item
    }

    return @($result)
}

function Get-LatestCheckpoint {

    param(
        [string]$ExecutionId,
        [string]$TenantId
    )

    $items = @(
        Get-Checkpoints `
            -ExecutionId $ExecutionId `
            -TenantId $TenantId
    )

    if ($items.Count -eq 0) {
        return $null
    }

    return $items |
        Sort-Object {
            [int]$_.Sequence
        } |
        Select-Object -Last 1
}

function Validate-Checkpoint {

    param(
        [string]$CheckpointId,
        [string]$TenantId
    )

    if ([string]::IsNullOrWhiteSpace($CheckpointId)) {
        throw "CheckpointId requis."
    }

    $map = Get-CheckpointMap

    if (-not $map.ContainsKey($CheckpointId)) {

        return [pscustomobject]@{
            Valid = $false
            Reason = "Checkpoint introuvable."
        }
    }

    $checkpoint = $map[$CheckpointId]

    if ($TenantId -and [string]$checkpoint.TenantId -ne $TenantId) {

        return [pscustomobject]@{
            Valid = $false
            Reason = "Isolation tenant refusee."
        }
    }

    if (
        [string]::IsNullOrWhiteSpace(
            [string]$checkpoint.StateHash
        )
    ) {

        return [pscustomobject]@{
            Valid = $false
            Reason = "StateHash manquant."
        }
    }

    if (
        [string]::IsNullOrWhiteSpace(
            [string]$checkpoint.Stage
        )
    ) {

        return [pscustomobject]@{
            Valid = $false
            Reason = "Stage manquant."
        }
    }

    return [pscustomobject]@{
        Valid = $true
        Reason = "Checkpoint valide."
        Checkpoint = $checkpoint
    }
}

function Mark-CheckpointValidated {

    param(
        [string]$CheckpointId,
        [string]$TenantId
    )

    $validation = Validate-Checkpoint `
        -CheckpointId $CheckpointId `
        -TenantId $TenantId

    if (-not $validation.Valid) {
        return $false
    }

    $map = Get-CheckpointMap
    $checkpoint = $map[$CheckpointId]

    $checkpoint.ValidatedAtUtc = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    $map[$CheckpointId] = $checkpoint

    Save-CheckpointMap -Map $map | Out-Null

    return $true
}

function Resume-FromCheckpoint {

    param(
        [string]$CheckpointId,
        [string]$TenantId
    )

    $config = Get-CheckpointConfig

    if (-not $config.resumeEnabled) {
        throw "Resume desactive."
    }

    $validation = Validate-Checkpoint `
        -CheckpointId $CheckpointId `
        -TenantId $TenantId

    if (-not $validation.Valid) {

        return [pscustomobject]@{
            Resumed = $false
            Reason = $validation.Reason
        }
    }

    $map = Get-CheckpointMap
    $checkpoint = $map[$CheckpointId]

    if (
        [string]::IsNullOrWhiteSpace(
            [string]$checkpoint.ValidatedAtUtc
        )
    ) {

        return [pscustomobject]@{
            Resumed = $false
            Reason = "Checkpoint non valide."
        }
    }

    $checkpoint.ResumedAtUtc = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    $map[$CheckpointId] = $checkpoint

    Save-CheckpointMap -Map $map | Out-Null

    return [pscustomobject]@{
        Resumed = $true
        ExecutionId = [string]$checkpoint.ExecutionId
        Sequence = [int]$checkpoint.Sequence
        Stage = [string]$checkpoint.Stage
        StateHash = [string]$checkpoint.StateHash
    }
}

function Test-CheckpointTenantIsolation {

    param(
        [string]$CheckpointId,
        [string]$TenantId
    )

    $result = Validate-Checkpoint `
        -CheckpointId $CheckpointId `
        -TenantId $TenantId

    return [bool]$result.Valid
}

function Reset-CheckpointState {

    if (Test-Path -LiteralPath $StatePath) {
        Remove-Item -LiteralPath $StatePath -Force
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    return $true
}