$ErrorActionPreference = "Stop"

$RuntimeRoot = Split-Path -Parent $PSCommandPath
$StateDir = Join-Path $RuntimeRoot "state"
$ConfigPath = Join-Path $RuntimeRoot "EXECUTION-STATE-MACHINE-CONFIG.json"
$StatePath = Join-Path $StateDir "state-machine.json"

function Get-StateMachineConfig {

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration State Machine introuvable."
    }

    return Get-Content `
        -LiteralPath $ConfigPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
}

function Get-StateMachineMap {

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

function Save-StateMachineMap {

    param(
        [hashtable]$Map
    )

    if ($null -eq $Map) {
        throw "Map State Machine requise."
    }

    $config = Get-StateMachineConfig

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

function New-ExecutionStateRecord {

    param(
        [string]$ExecutionId,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [ValidateSet(
            "CREATED",
            "QUEUED",
            "RUNNING",
            "PAUSED",
            "COMPLETED",
            "FAILED",
            "CANCELLED"
        )]
        [string]$State
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
        State = $State
        Version = 1
        CreatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        UpdatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        LastTransitionUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Get-AllowedTransitions {

    return @{
        CREATED   = @("QUEUED","CANCELLED")
        QUEUED    = @("RUNNING","CANCELLED")
        RUNNING   = @("PAUSED","COMPLETED","FAILED","CANCELLED")
        PAUSED    = @("RUNNING","CANCELLED")
        COMPLETED = @()
        FAILED    = @("QUEUED","CANCELLED")
        CANCELLED = @()
    }
}

function Test-StateTransition {

    param(
        [string]$FromState,
        [string]$ToState
    )

    if ([string]::IsNullOrWhiteSpace($FromState)) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($ToState)) {
        return $false
    }

    $allowed = Get-AllowedTransitions

    if (-not $allowed.ContainsKey($FromState)) {
        return $false
    }

    return @($allowed[$FromState] -contains $ToState)
}

function Save-ExecutionStateRecord {

    param(
        [object]$Record
    )

    if ($null -eq $Record) {
        throw "Record requise."
    }

    $executionId = [string](
        Get-StateField `
            -InputObject $Record `
            -Name "ExecutionId"
    )

    $tenantId = [string](
        Get-StateField `
            -InputObject $Record `
            -Name "TenantId"
    )

    if ([string]::IsNullOrWhiteSpace($executionId)) {
        throw "ExecutionId requis."
    }

    if ([string]::IsNullOrWhiteSpace($tenantId)) {
        throw "TenantId requis."
    }

    $map = Get-StateMachineMap

    $normalized = [ordered]@{}

    foreach ($field in @(
        "ExecutionId",
        "TenantId",
        "ClientId",
        "ProjectId",
        "WorkerId",
        "State",
        "Version",
        "CreatedAtUtc",
        "UpdatedAtUtc",
        "LastTransitionUtc"
    )) {

        $normalized[$field] = Get-StateField `
            -InputObject $Record `
            -Name $field
    }

    if ($null -eq $normalized["Version"]) {
        $normalized["Version"] = 1
    }

    $map[$executionId] = $normalized

    Save-StateMachineMap -Map $map | Out-Null

    return $true
}

function Get-ExecutionState {

    param(
        [string]$ExecutionId,
        [AllowEmptyString()]
        [string]$TenantId
    )

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId requis."
    }

    $map = Get-StateMachineMap

    if (-not $map.ContainsKey($ExecutionId)) {
        return $null
    }

    $record = $map[$ExecutionId]

    if ($TenantId -and [string](
        Get-StateField $record "TenantId"
    ) -ne $TenantId) {
        return $null
    }

    return [pscustomobject]$record
}

function Register-Execution {

    param(
        [string]$ExecutionId,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId
    )

    $config = Get-StateMachineConfig

    if (-not $config.enabled -or -not $config.stateMachineEnabled) {
        throw "State Machine desactivee."
    }

    $existing = Get-ExecutionState `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId

    if ($null -ne $existing) {
        return [pscustomobject]@{
            Registered = $false
            Reason = "Execution deja existante."
        }
    }

    $record = New-ExecutionStateRecord `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -WorkerId $WorkerId `
        -State "CREATED"

    Save-ExecutionStateRecord -Record $record | Out-Null

    return [pscustomobject]@{
        Registered = $true
        State = "CREATED"
        Version = 1
    }
}

function Transition-ExecutionState {

    param(
        [string]$ExecutionId,
        [string]$TenantId,
        [ValidateSet(
            "CREATED",
            "QUEUED",
            "RUNNING",
            "PAUSED",
            "COMPLETED",
            "FAILED",
            "CANCELLED"
        )]
        [string]$ToState
    )

    $config = Get-StateMachineConfig

    if (-not $config.transitionGuardsEnabled) {
        throw "Transition guards desactives."
    }

    $current = Get-ExecutionState `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId

    if ($null -eq $current) {

        return [pscustomobject]@{
            Transitioned = $false
            Reason = "Execution introuvable ou tenant invalide."
        }
    }

    $fromState = [string]$current.State

    if (
        $config.strictMode -eq $true -and
        -not (Test-StateTransition `
            -FromState $fromState `
            -ToState $ToState)
    ) {

        return [pscustomobject]@{
            Transitioned = $false
            Reason = "Transition interdite."
            FromState = $fromState
            ToState = $ToState
        }
    }

    if ($fromState -eq $ToState) {

        return [pscustomobject]@{
            Transitioned = $false
            Reason = "Meme etat interdit."
            FromState = $fromState
            ToState = $ToState
        }
    }

    $map = Get-StateMachineMap

    $record = $map[$ExecutionId]

    $record.State = $ToState
    $record.Version = [int]$record.Version + 1
    $record.UpdatedAtUtc = (
        Get-Date
    ).ToUniversalTime().ToString("o")
    $record.LastTransitionUtc = $record.UpdatedAtUtc

    $map[$ExecutionId] = $record

    Save-StateMachineMap -Map $map | Out-Null

    return [pscustomobject]@{
        Transitioned = $true
        FromState = $fromState
        ToState = $ToState
        Version = [int]$record.Version
    }
}

function Get-StateHistory {

    param(
        [string]$ExecutionId,
        [string]$TenantId
    )

    $record = Get-ExecutionState `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId

    if ($null -eq $record) {
        return @()
    }

    return @(
        [pscustomobject]@{
            ExecutionId = $record.ExecutionId
            TenantId = $record.TenantId
            CurrentState = $record.State
            Version = $record.Version
            UpdatedAtUtc = $record.UpdatedAtUtc
            LastTransitionUtc = $record.LastTransitionUtc
        }
    )
}

function Reset-StateMachineState {

    if (Test-Path -LiteralPath $StatePath) {
        Remove-Item -LiteralPath $StatePath -Force
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    return $true
}