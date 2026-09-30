function Get-ExecutionGatewayConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Execution Gateway Config introuvable : $ConfigPath"
    }

    try {
        return (
            Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        )
    }
    catch {
        throw "Execution Gateway Config invalide."
    }
}

function Invoke-ExternalConnectorExecutionGateway {
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
        [string]$ToolId,

        [AllowEmptyString()]
        [string]$Action,

        [AllowEmptyString()]
        [string]$ConnectorId,

        [AllowEmptyString()]
        [string]$AdapterId,

        [AllowEmptyString()]
        [string]$CredentialRef,

        [AllowEmptyString()]
        [string]$IdempotencyKey,

        [ValidateSet(
            "SIMULATION",
            "CONTROLLED",
            "LIVE"
        )]
        [string]$Mode = "SIMULATION",

        [bool]$CapabilityAuthorized = $false,

        [AllowEmptyString()]
        [string]$PolicyDecision,

        [ValidateSet(
            "HEALTHY",
            "DEGRADED",
            "UNAVAILABLE",
            "DISABLED",
            "UNKNOWN"
        )]
        [string]$HealthState = "UNKNOWN",

        [bool]$HealthExecutionAllowed = $false,

        [bool]$IdempotencyValid = $false,

        [bool]$DuplicateExecution = $false,

        [int]$Attempt = 1,

        [int]$MaxAttempts = 3,

        [bool]$TimeoutValid = $true,

        [bool]$DirectConnectorExecution = $false,

        [bool]$SecretForwardingAttempt = $false
    )

    # ========================================================
    # GATEWAY CONFIGURATION
    # ========================================================

    $config = Get-ExecutionGatewayConfig `
        -ConfigPath $ConfigPath

    if ($config.enabled -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "GATEWAY_DISABLED"
        }
    }

    if ($config.allowDirectConnectorExecution -ne $false) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "DIRECT_CONNECTOR_EXECUTION_CONFIGURATION_INVALID"
        }
    }

    if ($config.allowSecretForwarding -ne $false) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "SECRET_FORWARDING_CONFIGURATION_INVALID"
        }
    }

    # ========================================================
    # SECRET FORWARDING
    # ========================================================

    if ($SecretForwardingAttempt) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "SECRET_FORWARDING_ATTEMPT"
        }
    }

    # ========================================================
    # DIRECT CONNECTOR EXECUTION
    # ========================================================

    if ($DirectConnectorExecution) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "DIRECT_CONNECTOR_EXECUTION_FORBIDDEN"
        }
    }

    # ========================================================
    # EXECUTION CONTEXT
    # ========================================================

    if ($config.requireExecutionContext -eq $true) {

        if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CONTEXT_INCOMPLETE"
                field = "ExecutionId"
            }
        }

        if ([string]::IsNullOrWhiteSpace($CorrelationId)) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CONTEXT_INCOMPLETE"
                field = "CorrelationId"
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

        if ([string]::IsNullOrWhiteSpace($WorkerId)) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CONTEXT_INCOMPLETE"
                field = "WorkerId"
            }
        }

        if ([string]::IsNullOrWhiteSpace($SkillId)) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CONTEXT_INCOMPLETE"
                field = "SkillId"
            }
        }

        if ([string]::IsNullOrWhiteSpace($TaskId)) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CONTEXT_INCOMPLETE"
                field = "TaskId"
            }
        }

        if ([string]::IsNullOrWhiteSpace($ToolId)) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CONTEXT_INCOMPLETE"
                field = "ToolId"
            }
        }

        if ([string]::IsNullOrWhiteSpace($Action)) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CONTEXT_INCOMPLETE"
                field = "Action"
            }
        }
    }

    # ========================================================
    # CAPABILITY
    # ========================================================

    if ($config.requireCapabilityAuthorization -eq $true) {

        if ($CapabilityAuthorized -ne $true) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CAPABILITY_NOT_AUTHORIZED"
            }
        }
    }

    # ========================================================
    # POLICY
    # ========================================================

    if ($config.requirePolicyAuthorization -eq $true) {

        if ([string]::IsNullOrWhiteSpace($PolicyDecision)) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "POLICY_DECISION_REQUIRED"
            }
        }

        if ($PolicyDecision -eq "BLOCKED") {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "POLICY_BLOCKED"
            }
        }

        if ($PolicyDecision -eq "NEEDS_HUMAN") {
            return [pscustomobject]@{
                status = "NEEDS_HUMAN"
                reason = "HUMAN_APPROVAL_REQUIRED"
            }
        }

        if (
            $Mode -eq "LIVE" -and
            $PolicyDecision -ne "LIVE"
        ) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "LIVE_POLICY_NOT_AUTHORIZED"
            }
        }
    }

    # ========================================================
    # CONNECTOR / ADAPTER
    # ========================================================

    if ($config.requireAdapterResolution -eq $true) {

        if ([string]::IsNullOrWhiteSpace($ConnectorId)) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CONNECTOR_REQUIRED"
            }
        }

        if ([string]::IsNullOrWhiteSpace($AdapterId)) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "ADAPTER_REQUIRED"
            }
        }
    }

    # ========================================================
    # CREDENTIAL REFERENCE
    # ========================================================

    if ($config.requireCredentialReference -eq $true) {

        if ([string]::IsNullOrWhiteSpace($CredentialRef)) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CREDENTIAL_REFERENCE_REQUIRED"
            }
        }
    }

    # ========================================================
    # HEALTH
    # ========================================================

    if ($config.requireHealthApproval -eq $true) {

        if (
            $HealthExecutionAllowed -ne $true
        ) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "HEALTH_NOT_APPROVED"
                healthState = $HealthState
            }
        }

        if (
            $HealthState -eq "UNAVAILABLE" -or
            $HealthState -eq "DISABLED" -or
            $HealthState -eq "UNKNOWN"
        ) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CONNECTOR_UNAVAILABLE"
                healthState = $HealthState
            }
        }
    }

    # ========================================================
    # TIMEOUT
    # ========================================================

    if ($TimeoutValid -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "TIMEOUT_INVALID"
        }
    }

    # ========================================================
    # RETRY
    # ========================================================

    if ($Attempt -lt 1) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "INVALID_ATTEMPT"
        }
    }

    if ($Attempt -gt $MaxAttempts) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "RETRY_EXHAUSTED"
        }
    }

    # ========================================================
    # IDEMPOTENCY
    # ========================================================

    if ($config.requireIdempotency -eq $true) {

        if ([string]::IsNullOrWhiteSpace($IdempotencyKey)) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "IDEMPOTENCY_KEY_REQUIRED"
            }
        }

        if ($IdempotencyValid -ne $true) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "IDEMPOTENCY_INVALID"
            }
        }

        if ($DuplicateExecution) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "DUPLICATE_EXECUTION"
                idempotencyKey = $IdempotencyKey
            }
        }
    }

    # ========================================================
    # LIVE
    # ========================================================

    if ($Mode -eq "LIVE") {

        if ($config.liveExecutionEnabled -ne $true) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "LIVE_EXECUTION_DISABLED"
            }
        }
    }

    # ========================================================
    # EXECUTION GATE PASSED
    # ========================================================

    return [pscustomobject]@{
        status = "AUTHORIZED"
        gatewayVersion = $config.gatewayVersion

        executionId = $ExecutionId
        correlationId = $CorrelationId

        tenantId = $TenantId
        clientId = $ClientId
        projectId = $ProjectId

        workerId = $WorkerId
        skillId = $SkillId
        taskId = $TaskId
        toolId = $ToolId
        action = $Action

        connectorId = $ConnectorId
        adapterId = $AdapterId

        credentialRef = $CredentialRef
        credentialSecretExposed = $false

        capabilityAuthorized = $CapabilityAuthorized
        policyDecision = $PolicyDecision

        healthState = $HealthState
        healthApproved = $HealthExecutionAllowed

        idempotencyKey = $IdempotencyKey
        idempotencyValid = $IdempotencyValid
        duplicateExecution = $false

        attempt = $Attempt
        maxAttempts = $MaxAttempts
        timeoutValid = $TimeoutValid

        mode = $Mode

        externalCallAllowed = $false
        externalCallPerformed = $false

        directExecution = $false
        secretForwarding = $false
    }
}