function Get-OrchestratorControllerConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Orchestrator Controller Config introuvable : $ConfigPath"
    }

    try {
        return (
            Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        )
    }
    catch {
        throw "Orchestrator Controller Config invalide."
    }
}

function New-OrchestratorExecutionRequest {
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

        [bool]$CapabilityAuthorized = $false,

        [bool]$AdapterResolved = $false,

        [bool]$CredentialResolved = $false,

        [bool]$ConnectorResolved = $false,

        [bool]$HealthExecutionAllowed = $false,

        [bool]$IdempotencyValid = $false,

        [bool]$DuplicateExecution = $false,

        [bool]$TimeoutValid = $true,

        [int]$Attempt = 1,

        [int]$MaxAttempts = 3,

        [ValidateSet(
            "SIMULATION",
            "CONTROLLED",
            "LIVE"
        )]
        [string]$Mode = "SIMULATION",

        [bool]$DirectConnectorExecution = $false,

        [bool]$SecretForwardingAttempt = $false
    )

    $config = Get-OrchestratorControllerConfig `
        -ConfigPath $ConfigPath

    if ($config.enabled -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "ORCHESTRATOR_DISABLED"
        }
    }

    if ($config.singleEntryPoint -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "SINGLE_ENTRY_POINT_CONFIGURATION_INVALID"
        }
    }

    if ($config.allowBypass -ne $false) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "BYPASS_CONFIGURATION_INVALID"
        }
    }

    if ($config.allowDirectConnectorExecution -ne $false) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "DIRECT_EXECUTION_CONFIGURATION_INVALID"
        }
    }

    if ($config.allowSecretPropagation -ne $false) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "SECRET_PROPAGATION_CONFIGURATION_INVALID"
        }
    }

    # ========================================================
    # ORDRE STRICT DES ÉTAPES
    # ========================================================

    $stages = @(
        "CAPABILITY",
        "CONTEXT",
        "POLICY",
        "ADAPTER",
        "CREDENTIAL",
        "HEALTH",
        "EXECUTION_CONTROLS",
        "GATEWAY",
        "CONNECTOR",
        "RESULT",
        "EVENT",
        "AUDIT"
    )

    # ========================================================
    # CAPABILITY
    # ========================================================

    if ($CapabilityAuthorized -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CAPABILITY_NOT_AUTHORIZED"
            failedStage = "CAPABILITY"
            executionId = $ExecutionId
        }
    }

    # ========================================================
    # CONTEXT
    # ========================================================

    $contextFields = [ordered]@{
        ExecutionId = $ExecutionId
        CorrelationId = $CorrelationId
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        WorkerId = $WorkerId
        SkillId = $SkillId
        TaskId = $TaskId
        ToolId = $ToolId
        Action = $Action
    }

    foreach ($field in $contextFields.Keys) {

        if (
            [string]::IsNullOrWhiteSpace(
                [string]$contextFields[$field]
            )
        ) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CONTEXT_INCOMPLETE"
                failedStage = "CONTEXT"
                field = $field
                executionId = $ExecutionId
            }
        }
    }

    # ========================================================
    # POLICY
    # ========================================================

    if ([string]::IsNullOrWhiteSpace($PolicyDecision)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "POLICY_DECISION_REQUIRED"
            failedStage = "POLICY"
            executionId = $ExecutionId
        }
    }

    if ($PolicyDecision -eq "BLOCKED") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "POLICY_BLOCKED"
            failedStage = "POLICY"
            executionId = $ExecutionId
        }
    }

    if ($PolicyDecision -eq "NEEDS_HUMAN") {
        return [pscustomobject]@{
            status = "NEEDS_HUMAN"
            reason = "HUMAN_APPROVAL_REQUIRED"
            failedStage = "POLICY"
            executionId = $ExecutionId
        }
    }

    # ========================================================
    # ADAPTER
    # ========================================================

    if ($config.requireAdapter -and -not $AdapterResolved) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "ADAPTER_NOT_RESOLVED"
            failedStage = "ADAPTER"
            executionId = $ExecutionId
        }
    }

    if ([string]::IsNullOrWhiteSpace($AdapterId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "ADAPTER_REQUIRED"
            failedStage = "ADAPTER"
            executionId = $ExecutionId
        }
    }

    # ========================================================
    # CREDENTIAL
    # ========================================================

    if ($config.requireCredential -and -not $CredentialResolved) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CREDENTIAL_NOT_RESOLVED"
            failedStage = "CREDENTIAL"
            executionId = $ExecutionId
        }
    }

    if ([string]::IsNullOrWhiteSpace($CredentialRef)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CREDENTIAL_REFERENCE_REQUIRED"
            failedStage = "CREDENTIAL"
            executionId = $ExecutionId
        }
    }

    # ========================================================
    # HEALTH
    # ========================================================

    if ($config.requireHealth -and -not $HealthExecutionAllowed) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "HEALTH_NOT_APPROVED"
            failedStage = "HEALTH"
            executionId = $ExecutionId
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
            failedStage = "HEALTH"
            executionId = $ExecutionId
        }
    }

    # ========================================================
    # EXECUTION CONTROLS
    # ========================================================

    if ($Attempt -lt 1) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "INVALID_ATTEMPT"
            failedStage = "EXECUTION_CONTROLS"
            executionId = $ExecutionId
        }
    }

    if ($Attempt -gt $MaxAttempts) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "RETRY_EXHAUSTED"
            failedStage = "EXECUTION_CONTROLS"
            executionId = $ExecutionId
        }
    }

    if (-not $TimeoutValid) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "TIMEOUT_INVALID"
            failedStage = "EXECUTION_CONTROLS"
            executionId = $ExecutionId
        }
    }

    if ([string]::IsNullOrWhiteSpace($IdempotencyKey)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "IDEMPOTENCY_KEY_REQUIRED"
            failedStage = "EXECUTION_CONTROLS"
            executionId = $ExecutionId
        }
    }

    if (-not $IdempotencyValid) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "IDEMPOTENCY_INVALID"
            failedStage = "EXECUTION_CONTROLS"
            executionId = $ExecutionId
        }
    }

    if ($DuplicateExecution) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "DUPLICATE_EXECUTION"
            failedStage = "EXECUTION_CONTROLS"
            executionId = $ExecutionId
        }
    }

    # ========================================================
    # GATEWAY
    # ========================================================

    if ($config.requireGateway) {
        if (
            [string]::IsNullOrWhiteSpace($ConnectorId)
        ) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CONNECTOR_REQUIRED"
                failedStage = "GATEWAY"
                executionId = $ExecutionId
            }
        }

        if ($DirectConnectorExecution) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "DIRECT_CONNECTOR_EXECUTION_FORBIDDEN"
                failedStage = "GATEWAY"
                executionId = $ExecutionId
            }
        }
    }

    # ========================================================
    # CONNECTOR
    # ========================================================

    if ($config.requireConnector -and -not $ConnectorResolved) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONNECTOR_NOT_RESOLVED"
            failedStage = "CONNECTOR"
            executionId = $ExecutionId
        }
    }

    # ========================================================
    # SECRET FORWARDING
    # ========================================================

    if ($SecretForwardingAttempt) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "SECRET_FORWARDING_ATTEMPT"
            failedStage = "CONNECTOR"
            executionId = $ExecutionId
        }
    }

    # ========================================================
    # LIVE
    # ========================================================

    if (
        $Mode -eq "LIVE" -and
        $config.liveExecutionEnabled -ne $true
    ) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "LIVE_EXECUTION_DISABLED"
            failedStage = "CONNECTOR"
            executionId = $ExecutionId
        }
    }

    # ========================================================
    # PIPELINE COMPLETE
    # ========================================================

    return [pscustomobject]@{
        status = "AUTHORIZED"

        controllerVersion = $config.version

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

        policyDecision = $PolicyDecision
        healthState = $HealthState

        idempotencyKey = $IdempotencyKey

        attempt = $Attempt
        maxAttempts = $MaxAttempts
        timeoutValid = $TimeoutValid

        mode = $Mode

        pipelineStages = $stages
        pipelineCompleted = $true

        externalCallAllowed = $false
        externalCallPerformed = $false

        secretExposure = $false
        directConnectorExecution = $false
        secretForwarding = $false

        resultRequired = $true
        eventRequired = $true
        auditRequired = $true
    }
}