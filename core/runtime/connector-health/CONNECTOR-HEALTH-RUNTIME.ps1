function Get-ConnectorHealthConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Connector Health Config introuvable : $ConfigPath"
    }

    try {
        return (
            Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        )
    }
    catch {
        throw "Connector Health Config invalide."
    }
}

function Get-ConnectorHealthState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [AllowEmptyString()]
        [string]$ConnectorId
    )

    if ([string]::IsNullOrWhiteSpace($ConnectorId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONNECTOR_ID_REQUIRED"
        }
    }

    $config = Get-ConnectorHealthConfig -ConfigPath $ConfigPath

    $matches = @(
        $config.connectors | Where-Object {
            $_.connectorId -eq $ConnectorId
        }
    )

    if ($matches.Count -eq 0) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONNECTOR_NOT_FOUND"
        }
    }

    if ($matches.Count -gt 1) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "MULTIPLE_CONNECTOR_STATES"
        }
    }

    $connector = $matches[0]

    if (-not $connector.enabled) {
        return [pscustomobject]@{
            status = "DISABLED"
            connectorId = $connector.connectorId
            state = "DISABLED"
            available = $false
        }
    }

    $validStates = @(
        "HEALTHY",
        "DEGRADED",
        "UNAVAILABLE",
        "DISABLED",
        "UNKNOWN"
    )

    if ($validStates -notcontains $connector.state) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "INVALID_HEALTH_STATE"
            connectorId = $connector.connectorId
        }
    }

    switch ($connector.state) {

        "HEALTHY" {
            return [pscustomobject]@{
                status = "HEALTHY"
                connectorId = $connector.connectorId
                provider = $connector.provider
                category = $connector.category
                state = "HEALTHY"
                available = $true
            }
        }

        "DEGRADED" {
            return [pscustomobject]@{
                status = "DEGRADED"
                connectorId = $connector.connectorId
                provider = $connector.provider
                category = $connector.category
                state = "DEGRADED"
                available = $true
                retryRecommended = $true
            }
        }

        "UNAVAILABLE" {
            return [pscustomobject]@{
                status = "UNAVAILABLE"
                connectorId = $connector.connectorId
                provider = $connector.provider
                category = $connector.category
                state = "UNAVAILABLE"
                available = $false
            }
        }

        "DISABLED" {
            return [pscustomobject]@{
                status = "DISABLED"
                connectorId = $connector.connectorId
                provider = $connector.provider
                category = $connector.category
                state = "DISABLED"
                available = $false
            }
        }

        default {
            return [pscustomobject]@{
                status = "UNKNOWN"
                connectorId = $connector.connectorId
                provider = $connector.provider
                category = $connector.category
                state = "UNKNOWN"
                available = $false
            }
        }
    }
}

function Test-ConnectorAvailability {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$HealthState
    )

    if ($null -eq $HealthState) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "HEALTH_STATE_REQUIRED"
        }
    }

    switch ($HealthState.status) {

        "HEALTHY" {
            return [pscustomobject]@{
                status = "AVAILABLE"
                connectorId = $HealthState.connectorId
                available = $true
                executionAllowed = $true
            }
        }

        "DEGRADED" {
            return [pscustomobject]@{
                status = "AVAILABLE_WITH_CAUTION"
                connectorId = $HealthState.connectorId
                available = $true
                executionAllowed = $true
                retryRecommended = $true
            }
        }

        "UNAVAILABLE" {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CONNECTOR_UNAVAILABLE"
                connectorId = $HealthState.connectorId
                available = $false
                executionAllowed = $false
            }
        }

        "DISABLED" {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CONNECTOR_DISABLED"
                connectorId = $HealthState.connectorId
                available = $false
                executionAllowed = $false
            }
        }

        default {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CONNECTOR_HEALTH_UNKNOWN"
                connectorId = $HealthState.connectorId
                available = $false
                executionAllowed = $false
            }
        }
    }
}

function New-RetryPlan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [AllowEmptyString()]
        [string]$ConnectorId,

        [int]$Attempt = 1,

        [bool]$PreviousAttemptFailed = $false
    )

    if ([string]::IsNullOrWhiteSpace($ConnectorId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONNECTOR_ID_REQUIRED"
        }
    }

    $config = Get-ConnectorHealthConfig -ConfigPath $ConfigPath

    if ($config.retry.enabled -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "RETRY_DISABLED"
        }
    }

    if ($Attempt -lt 1) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "INVALID_ATTEMPT"
        }
    }

    $maxAttempts = [int]$config.retry.maxAttempts

    if ($Attempt -gt $maxAttempts) {
        return [pscustomobject]@{
            status = "EXHAUSTED"
            connectorId = $ConnectorId
            attempt = $Attempt
            maxAttempts = $maxAttempts
            retryAllowed = $false
        }
    }

    if (-not $PreviousAttemptFailed) {
        return [pscustomobject]@{
            status = "READY"
            connectorId = $ConnectorId
            attempt = $Attempt
            maxAttempts = $maxAttempts
            retryAllowed = $false
            backoffSeconds = 0
        }
    }

    if ($Attempt -eq $maxAttempts) {
        return [pscustomobject]@{
            status = "FINAL_ATTEMPT"
            connectorId = $ConnectorId
            attempt = $Attempt
            maxAttempts = $maxAttempts
            retryAllowed = $true
            backoffSeconds = [Math]::Min(
                ([int]$config.retry.backoffSeconds * [Math]::Pow(2, $Attempt - 1)),
                [int]$config.retry.maxBackoffSeconds
            )
        }
    }

    $backoff = [Math]::Min(
        ([int]$config.retry.backoffSeconds * [Math]::Pow(2, $Attempt - 1)),
        [int]$config.retry.maxBackoffSeconds
    )

    return [pscustomobject]@{
        status = "RETRY"
        connectorId = $ConnectorId
        attempt = $Attempt
        maxAttempts = $maxAttempts
        retryAllowed = $true
        backoffSeconds = $backoff
    }
}

function New-CircuitBreakerState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConnectorId,

        [int]$FailureCount = 0,

        [string]$State = "CLOSED"
    )

    if ([string]::IsNullOrWhiteSpace($ConnectorId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONNECTOR_ID_REQUIRED"
        }
    }

    $allowedStates = @(
        "CLOSED",
        "OPEN",
        "HALF_OPEN"
    )

    if ($allowedStates -notcontains $State) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "INVALID_CIRCUIT_STATE"
        }
    }

    return [pscustomobject]@{
        status = "VALID"
        connectorId = $ConnectorId
        circuitState = $State
        failureCount = $FailureCount
    }
}

function Evaluate-CircuitBreaker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$CircuitState
    )

    if ($null -eq $CircuitState) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CIRCUIT_STATE_REQUIRED"
        }
    }

    $config = Get-ConnectorHealthConfig -ConfigPath $ConfigPath

    if ($config.circuitBreaker.enabled -ne $true) {
        return [pscustomobject]@{
            status = "DISABLED"
            executionAllowed = $true
        }
    }

    $threshold = [int]$config.circuitBreaker.failureThreshold

    if ($CircuitState.circuitState -eq "OPEN") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CIRCUIT_OPEN"
            connectorId = $CircuitState.connectorId
            executionAllowed = $false
        }
    }

    if ($CircuitState.failureCount -ge $threshold) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "FAILURE_THRESHOLD_REACHED"
            connectorId = $CircuitState.connectorId
            executionAllowed = $false
            recommendedState = "OPEN"
        }
    }

    return [pscustomobject]@{
        status = "CLOSED"
        connectorId = $CircuitState.connectorId
        executionAllowed = $true
        failureCount = $CircuitState.failureCount
        threshold = $threshold
    }
}

function Invoke-HealthManagedExecution {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [AllowEmptyString()]
        [string]$ConnectorId,

        [AllowEmptyString()]
        [string]$ExecutionId,

        [AllowEmptyString()]
        [string]$TenantId,

        [AllowEmptyString()]
        [string]$ClientId,

        [AllowEmptyString()]
        [string]$ProjectId,

        [int]$FailureCount = 0,

        [ValidateSet("SIMULATION","CONTROLLED","LIVE")]
        [string]$Mode = "SIMULATION"
    )

    # --------------------------------------------------------
    # Contexte
    # --------------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($ConnectorId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "ConnectorId"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "ExecutionId"
        }
    }

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

    # --------------------------------------------------------
    # Health
    # --------------------------------------------------------

    $health = Get-ConnectorHealthState `
        -ConfigPath $ConfigPath `
        -ConnectorId $ConnectorId

    $availability = Test-ConnectorAvailability `
        -HealthState $health

    if (
        $availability.executionAllowed -ne $true
    ) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = $availability.reason
            connectorId = $ConnectorId
            healthStatus = $health.status
        }
    }

    # --------------------------------------------------------
    # Circuit Breaker
    # --------------------------------------------------------

    $circuit = New-CircuitBreakerState `
        -ConnectorId $ConnectorId `
        -FailureCount $FailureCount `
        -State $(if ($FailureCount -ge 3) { "OPEN" } else { "CLOSED" })

    $circuitDecision = Evaluate-CircuitBreaker `
        -ConfigPath $ConfigPath `
        -CircuitState $circuit

    if ($circuitDecision.executionAllowed -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = $circuitDecision.reason
            connectorId = $ConnectorId
            healthStatus = $health.status
        }
    }

    # --------------------------------------------------------
    # LIVE interdit
    # --------------------------------------------------------

    if ($Mode -eq "LIVE") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "LIVE_EXECUTION_DISABLED"
            connectorId = $ConnectorId
        }
    }

    # --------------------------------------------------------
    # SIMULATION / CONTROLLED
    # --------------------------------------------------------

    return [pscustomobject]@{
        status = "READY"
        connectorId = $ConnectorId
        executionId = $ExecutionId
        tenantId = $TenantId
        clientId = $ClientId
        projectId = $ProjectId
        healthStatus = $health.status
        availability = $availability.status
        circuitState = $circuitDecision.status
        mode = $Mode
        externalCallPerformed = $false
        secretExposure = $false
    }
}