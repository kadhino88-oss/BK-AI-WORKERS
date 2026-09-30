Set-StrictMode -Version 2.0

function Get-DeliveryStateConfig {

    $ConfigFile = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file missing: $ConfigFile"
    }

    return Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
}

function Get-DeliveryStates {

    return @(
        "REGISTERED"
        "AUTHORIZED"
        "DELIVERING"
        "DELIVERED"
        "FAILED"
        "BLOCKED"
    )
}

function Get-DeliveryAllowedTransitions {

    return @(
        "REGISTERED|AUTHORIZED"
        "AUTHORIZED|DELIVERING"
        "DELIVERING|DELIVERED"
        "AUTHORIZED|FAILED"
        "DELIVERING|FAILED"
        "FAILED|AUTHORIZED"
        "FAILED|BLOCKED"
        "REGISTERED|BLOCKED"
        "AUTHORIZED|BLOCKED"
        "DELIVERING|BLOCKED"
    )
}

function Get-DeliveryStateStore {

    $StateFile = Join-Path $PSScriptRoot "state\delivery-states.json"

    if (-not (Test-Path $StateFile)) {
        return @()
    }

    $Raw = Get-Content -Raw -Path $StateFile

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return @()
    }

    $Parsed = ConvertFrom-Json $Raw

    if ($null -eq $Parsed) {
        return @()
    }

    return @($Parsed)
}

function Save-DeliveryStateStore {

    param(
        [Parameter(Mandatory=$true)]
        $Records
    )

    $StateFile = Join-Path $PSScriptRoot "state\delivery-states.json"
    $Array = @($Records)

    if ($Array.Count -eq 0) {
        [System.IO.File]::WriteAllText(
            $StateFile,
            "[]",
            [System.Text.UTF8Encoding]::new($false)
        )

        return
    }

    $Json = ConvertTo-Json -InputObject $Array -Depth 20

    [System.IO.File]::WriteAllText(
        $StateFile,
        $Json,
        [System.Text.UTF8Encoding]::new($false)
    )

    return
}

function Get-DeliveryCurrentState {

    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$DeliveryId
    )

    if ([string]::IsNullOrWhiteSpace($DeliveryId)) {
        return $null
    }

    $Records = @(Get-DeliveryStateStore)

    $Record = @(
        $Records |
        Where-Object {
            [string]$_.DeliveryId -eq $DeliveryId
        }
    ) | Select-Object -First 1

    if ($null -eq $Record) {
        return $null
    }

    return $Record
}

function Test-DeliveryTransition {

    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$DeliveryId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$FromState,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ToState
    )

    if ([string]::IsNullOrWhiteSpace($DeliveryId)) {
        return [pscustomobject]@{
            Allowed = $false
            Status  = "BLOCKED"
            Reason  = "DELIVERY_ID_MISSING"
        }
    }

    if ([string]::IsNullOrWhiteSpace($FromState)) {
        return [pscustomobject]@{
            Allowed = $false
            Status  = "BLOCKED"
            Reason  = "FROM_STATE_MISSING"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ToState)) {
        return [pscustomobject]@{
            Allowed = $false
            Status  = "BLOCKED"
            Reason  = "TO_STATE_MISSING"
        }
    }

    $FromValid = $false
    $ToValid = $false

    foreach ($State in @(Get-DeliveryStates)) {
        if ($State -eq $FromState) {
            $FromValid = $true
        }

        if ($State -eq $ToState) {
            $ToValid = $true
        }
    }

    if (-not $FromValid) {
        return [pscustomobject]@{
            Allowed = $false
            Status  = "BLOCKED"
            Reason  = "FROM_STATE_INVALID"
        }
    }

    if (-not $ToValid) {
        return [pscustomobject]@{
            Allowed = $false
            Status  = "BLOCKED"
            Reason  = "TO_STATE_INVALID"
        }
    }

    $TransitionKey = $FromState + "|" + $ToState
    $Allowed = $false

    foreach ($Transition in @(Get-DeliveryAllowedTransitions)) {
        if ($Transition -eq $TransitionKey) {
            $Allowed = $true
            break
        }
    }

    if (-not $Allowed) {
        return [pscustomobject]@{
            Allowed = $false
            Status  = "BLOCKED"
            Reason  = "TRANSITION_NOT_ALLOWED"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Status  = "ALLOWED"
        Reason  = "TRANSITION_ALLOWED"
    }
}

function Initialize-DeliveryState {

    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$DeliveryId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ExecutionId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$TenantId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ClientId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ProjectId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$WorkerId
    )

    if ([string]::IsNullOrWhiteSpace($DeliveryId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "DELIVERY_ID_MISSING"
        }
    }

    $Existing = Get-DeliveryCurrentState -DeliveryId $DeliveryId

    if ($null -ne $Existing) {
        return [pscustomobject]@{
            Success = $true
            Status  = "EXISTS"
            Reason  = "STATE_ALREADY_INITIALIZED"
        }
    }

    $Records = @(Get-DeliveryStateStore)

    $Record = [pscustomobject][ordered]@{
        DeliveryId      = $DeliveryId
        ExecutionId     = $ExecutionId
        TenantId        = $TenantId
        ClientId        = $ClientId
        ProjectId       = $ProjectId
        WorkerId        = $WorkerId
        State           = "REGISTERED"
        TransitionCount = 0
        UpdatedAtUtc    = [DateTime]::UtcNow.ToString("o")
    }

    $Records += ,$Record

    $null = Save-DeliveryStateStore -Records $Records

    return [pscustomobject]@{
        Success = $true
        Status  = "REGISTERED"
        Reason  = "STATE_INITIALIZED"
    }
}

function Set-DeliveryState {

    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$DeliveryId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ToState
    )

    $Current = Get-DeliveryCurrentState -DeliveryId $DeliveryId

    if ($null -eq $Current) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "DELIVERY_NOT_INITIALIZED"
        }
    }

    $Transition = Test-DeliveryTransition `
        -DeliveryId $DeliveryId `
        -FromState ([string]$Current.State) `
        -ToState $ToState

    if (-not $Transition.Allowed) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = $Transition.Reason
        }
    }

    if (
        ([string]$Current.State -eq "DELIVERED") -or
        ([string]$Current.State -eq "BLOCKED")
    ) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "TERMINAL_STATE"
        }
    }

    $Records = @(Get-DeliveryStateStore)

    foreach ($Record in $Records) {
        if ([string]$Record.DeliveryId -eq $DeliveryId) {
            $Record.State = $ToState
            $Record.TransitionCount = [int]$Record.TransitionCount + 1
            $Record.UpdatedAtUtc = [DateTime]::UtcNow.ToString("o")
            break
        }
    }

    $null = Save-DeliveryStateStore -Records $Records

    return [pscustomobject]@{
        Success = $true
        Status  = $ToState
        Reason  = "STATE_TRANSITIONED"
    }
}

function Reset-DeliveryState {

    $null = Save-DeliveryStateStore -Records @()

    return
}