function Get-ExecutionEventConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Execution Event Config introuvable : $ConfigPath"
    }

    try {
        return (
            Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        )
    }
    catch {
        throw "Execution Event Config invalide."
    }
}

function Test-ExecutionTransition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [AllowEmptyString()]
        [string]$FromState,

        [AllowEmptyString()]
        [string]$ToState
    )

    if ([string]::IsNullOrWhiteSpace($FromState)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "FROM_STATE_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ToState)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "TO_STATE_REQUIRED"
        }
    }

    $config = Get-ExecutionEventConfig -ConfigPath $ConfigPath

    $allowedStates = @(
        $config.allowedStates
    )

    if ($allowedStates -notcontains $FromState) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "INVALID_FROM_STATE"
            state = $FromState
        }
    }

    if ($allowedStates -notcontains $ToState) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "INVALID_TO_STATE"
            state = $ToState
        }
    }

    $allowed = @(
        $config.allowedTransitions | Where-Object {
            $_.from -eq $FromState -and
            $_.to -eq $ToState
        }
    )

    if ($allowed.Count -eq 1) {
        return [pscustomobject]@{
            status = "ALLOWED"
            fromState = $FromState
            toState = $ToState
        }
    }

    return [pscustomobject]@{
        status = "BLOCKED"
        reason = "INVALID_TRANSITION"
        fromState = $FromState
        toState = $ToState
    }
}

function New-ExecutionEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [AllowEmptyString()]
        [string]$ExecutionId,

        [AllowEmptyString()]
        [string]$CorrelationId,

        [AllowEmptyString()]
        [string]$TenantId,

        [AllowEmptyString()]
        [string]$ClientId,

        [AllowEmptyString()]
        [string]$ProjectId,

        [AllowEmptyString()]
        [string]$WorkerId,

        [AllowEmptyString()]
        [string]$SkillId,

        [AllowEmptyString()]
        [string]$TaskId,

        [AllowEmptyString()]
        [string]$EventType,

        [AllowEmptyString()]
        [string]$FromState,

        [AllowEmptyString()]
        [string]$ToState,

        [AllowEmptyString()]
        [string]$Message = "",

        [object]$Data = $null
    )

    $config = Get-ExecutionEventConfig `
        -ConfigPath $ConfigPath

    if ($config.eventBusEnabled -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "EVENT_BUS_DISABLED"
        }
    }

    $context = @{
        ExecutionId = $ExecutionId
        CorrelationId = $CorrelationId
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        WorkerId = $WorkerId
        SkillId = $SkillId
        TaskId = $TaskId
        EventType = $EventType
        FromState = $FromState
        ToState = $ToState
    }

    foreach ($field in $context.Keys) {
        if (
            [string]::IsNullOrWhiteSpace(
                [string]$context[$field]
            )
        ) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "EVENT_CONTEXT_INCOMPLETE"
                field = $field
            }
        }
    }

    $transition = Test-ExecutionTransition `
        -ConfigPath $ConfigPath `
        -FromState $FromState `
        -ToState $ToState

    if ($transition.status -ne "ALLOWED") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = $transition.reason
            fromState = $FromState
            toState = $ToState
        }
    }

    $safeData = $null

    if ($null -ne $Data) {
        $safeData = [ordered]@{}

        foreach ($property in $Data.PSObject.Properties) {

            if (
                $property.Name -match
                '(?i)(api.?key|access.?token|refresh.?token|client.?secret|password|passwd|private.?key|bearer|secret)'
            ) {
                continue
            }

            $safeData[$property.Name] = $property.Value
        }
    }

    return [pscustomobject]@{
        status = "CREATED"
        eventId = "EVENT-$([guid]::NewGuid().ToString())"
        eventVersion = "1.0"

        eventType = $EventType

        executionId = $ExecutionId
        correlationId = $CorrelationId

        tenantId = $TenantId
        clientId = $ClientId
        projectId = $ProjectId

        workerId = $WorkerId
        skillId = $SkillId
        taskId = $TaskId

        fromState = $FromState
        toState = $ToState

        message = $Message

        data = $safeData

        recordedAtUtc = [DateTime]::UtcNow.ToString("o")

        secretExposure = $false
        externalCallPerformed = $false
    }
}

function Write-ExecutionEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EventPath,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Event
    )

    if ($null -eq $Event) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "EVENT_REQUIRED"
        }
    }

    if ($Event.status -ne "CREATED") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "INVALID_EVENT"
        }
    }

    $json = $Event |
        ConvertTo-Json -Depth 30 -Compress

    Add-Content `
        -LiteralPath $EventPath `
        -Value $json `
        -Encoding UTF8

    return [pscustomobject]@{
        status = "RECORDED"
        eventId = $Event.eventId
        eventPath = $EventPath
        appendOnly = $true
        secretExposure = $false
    }
}

function Get-ExecutionLifecycleState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [AllowEmptyString()]
        [string]$CurrentState,

        [AllowEmptyString()]
        [string]$RequestedState
    )

    $transition = Test-ExecutionTransition `
        -ConfigPath $ConfigPath `
        -FromState $CurrentState `
        -ToState $RequestedState

    if ($transition.status -ne "ALLOWED") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = $transition.reason
            currentState = $CurrentState
            requestedState = $RequestedState
        }
    }

    return [pscustomobject]@{
        status = "AUTHORIZED"
        currentState = $CurrentState
        nextState = $RequestedState
    }
}

function Get-ExecutionEventHistory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EventPath
    )

    if (-not (Test-Path -LiteralPath $EventPath)) {
        return @()
    }

    $lines = Get-Content `
        -LiteralPath $EventPath `
        -Encoding UTF8

    $events = @()

    foreach ($line in $lines) {

        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $events += ($line | ConvertFrom-Json)
        }
        catch {
            throw "Evénement JSON invalide dans le ledger."
        }
    }

    return $events
}