function Get-ExecutionPipelineConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Execution Pipeline Config introuvable : $ConfigPath"
    }

    try {
        return (
            Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        )
    }
    catch {
        throw "Execution Pipeline Config invalide."
    }
}

function New-PipelineResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status,

        [AllowEmptyString()]
        [string]$Reason = "",

        [AllowEmptyString()]
        [string]$Stage = "",

        [AllowEmptyString()]
        [string]$ExecutionId = ""
    )

    return [pscustomobject]@{
        status = $Status
        reason = $Reason
        failedStage = $Stage
        executionId = $ExecutionId
        timestampUtc = [DateTime]::UtcNow.ToString("o")
        externalCallPerformed = $false
        secretExposure = $false
    }
}

function Invoke-ExternalConnectorExecutionPipeline {
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

        [bool]$SecretForwardingAttempt = $false,

        [bool]$AdapterResolved = $false,

        [bool]$CredentialResolved = $false,

        [bool]$ConnectorResolved = $false
    )

    $config = Get-ExecutionPipelineConfig `
        -ConfigPath $ConfigPath

    # ========================================================
    # PIPELINE CONFIGURATION
    # ========================================================

    if ($config.enabled -ne $true) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "PIPELINE_DISABLED" `
            -Stage "PIPELINE" `
            -ExecutionId $ExecutionId
    }

    if ($config.allowStageBypass -ne $false) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "STAGE_BYPASS_CONFIGURATION_INVALID" `
            -Stage "PIPELINE" `
            -ExecutionId $ExecutionId
    }

    if ($config.allowSecretPropagation -ne $false) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "SECRET_PROPAGATION_CONFIGURATION_INVALID" `
            -Stage "PIPELINE" `
            -ExecutionId $ExecutionId
    }

    if ($config.allowDirectConnectorExecution -ne $false) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "DIRECT_EXECUTION_CONFIGURATION_INVALID" `
            -Stage "PIPELINE" `
            -ExecutionId $ExecutionId
    }

    # ========================================================
    # STAGE 1 - CAPABILITY
    # ========================================================

    if ($CapabilityAuthorized -ne $true) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "CAPABILITY_NOT_AUTHORIZED" `
            -Stage "CAPABILITY" `
            -ExecutionId $ExecutionId
    }

    # ========================================================
    # STAGE 2 - CONTEXT
    # ========================================================

    $contextFields = @{
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

        if ([string]::IsNullOrWhiteSpace([string]$contextFields[$field])) {
            return New-PipelineResult `
                -Status "BLOCKED" `
                -Reason "CONTEXT_INCOMPLETE" `
                -Stage "CONTEXT:$field" `
                -ExecutionId $ExecutionId
        }
    }

    # ========================================================
    # STAGE 3 - POLICY
    # ========================================================

    if ([string]::IsNullOrWhiteSpace($PolicyDecision)) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "POLICY_DECISION_REQUIRED" `
            -Stage "POLICY" `
            -ExecutionId $ExecutionId
    }

    if ($PolicyDecision -eq "BLOCKED") {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "POLICY_BLOCKED" `
            -Stage "POLICY" `
            -ExecutionId $ExecutionId
    }

    if ($PolicyDecision -eq "NEEDS_HUMAN") {
        return New-PipelineResult `
            -Status "NEEDS_HUMAN" `
            -Reason "HUMAN_APPROVAL_REQUIRED" `
            -Stage "POLICY" `
            -ExecutionId $ExecutionId
    }

    # ========================================================
    # STAGE 4 - ADAPTER
    # ========================================================

    if (-not $AdapterResolved) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "ADAPTER_NOT_RESOLVED" `
            -Stage "ADAPTER" `
            -ExecutionId $ExecutionId
    }

    if ([string]::IsNullOrWhiteSpace($AdapterId)) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "ADAPTER_REQUIRED" `
            -Stage "ADAPTER" `
            -ExecutionId $ExecutionId
    }

    # ========================================================
    # STAGE 5 - CREDENTIAL
    # ========================================================

    if (-not $CredentialResolved) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "CREDENTIAL_NOT_RESOLVED" `
            -Stage "CREDENTIAL" `
            -ExecutionId $ExecutionId
    }

    if ([string]::IsNullOrWhiteSpace($CredentialRef)) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "CREDENTIAL_REFERENCE_REQUIRED" `
            -Stage "CREDENTIAL" `
            -ExecutionId $ExecutionId
    }

    # ========================================================
    # STAGE 6 - HEALTH
    # ========================================================

    if ($HealthExecutionAllowed -ne $true) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "HEALTH_NOT_APPROVED" `
            -Stage "HEALTH" `
            -ExecutionId $ExecutionId
    }

    if (
        $HealthState -eq "UNAVAILABLE" -or
        $HealthState -eq "DISABLED" -or
        $HealthState -eq "UNKNOWN"
    ) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "CONNECTOR_UNAVAILABLE" `
            -Stage "HEALTH" `
            -ExecutionId $ExecutionId
    }

    # ========================================================
    # STAGE 7 - RETRY / TIMEOUT / IDEMPOTENCY
    # ========================================================

    if ($Attempt -lt 1) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "INVALID_ATTEMPT" `
            -Stage "RETRY" `
            -ExecutionId $ExecutionId
    }

    if ($Attempt -gt $MaxAttempts) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "RETRY_EXHAUSTED" `
            -Stage "RETRY" `
            -ExecutionId $ExecutionId
    }

    if ($TimeoutValid -ne $true) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "TIMEOUT_INVALID" `
            -Stage "TIMEOUT" `
            -ExecutionId $ExecutionId
    }

    if ([string]::IsNullOrWhiteSpace($IdempotencyKey)) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "IDEMPOTENCY_KEY_REQUIRED" `
            -Stage "IDEMPOTENCY" `
            -ExecutionId $ExecutionId
    }

    if ($IdempotencyValid -ne $true) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "IDEMPOTENCY_INVALID" `
            -Stage "IDEMPOTENCY" `
            -ExecutionId $ExecutionId
    }

    if ($DuplicateExecution) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "DUPLICATE_EXECUTION" `
            -Stage "IDEMPOTENCY" `
            -ExecutionId $ExecutionId
    }

    # ========================================================
    # STAGE 8 - GATEWAY
    # ========================================================

    if ($DirectConnectorExecution) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "DIRECT_CONNECTOR_EXECUTION_FORBIDDEN" `
            -Stage "GATEWAY" `
            -ExecutionId $ExecutionId
    }

    # ========================================================
    # STAGE 9 - CONNECTOR
    # ========================================================

    if (-not $ConnectorResolved) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "CONNECTOR_NOT_RESOLVED" `
            -Stage "CONNECTOR" `
            -ExecutionId $ExecutionId
    }

    if ([string]::IsNullOrWhiteSpace($ConnectorId)) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "CONNECTOR_REQUIRED" `
            -Stage "CONNECTOR" `
            -ExecutionId $ExecutionId
    }

    # ========================================================
    # SECRET PROPAGATION
    # ========================================================

    if ($SecretForwardingAttempt) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "SECRET_FORWARDING_ATTEMPT" `
            -Stage "SECURITY" `
            -ExecutionId $ExecutionId
    }

    # ========================================================
    # LIVE
    # ========================================================

    if (
        $Mode -eq "LIVE" -and
        $config.liveExecutionEnabled -ne $true
    ) {
        return New-PipelineResult `
            -Status "BLOCKED" `
            -Reason "LIVE_EXECUTION_DISABLED" `
            -Stage "CONNECTOR" `
            -ExecutionId $ExecutionId
    }

    # ========================================================
    # FINAL RESULT
    # ========================================================

    return [pscustomobject]@{
        status = "AUTHORIZED"
        pipelineVersion = $config.pipelineVersion

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

        adapterId = $AdapterId
        connectorId = $ConnectorId
        credentialRef = $CredentialRef

        capabilityAuthorized = $true
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

        pipelineCompleted = $true
        externalCallAllowed = $false
        externalCallPerformed = $false

        secretExposure = $false
        directExecution = $false
        secretForwarding = $false

        auditRequired = $true
    }
}