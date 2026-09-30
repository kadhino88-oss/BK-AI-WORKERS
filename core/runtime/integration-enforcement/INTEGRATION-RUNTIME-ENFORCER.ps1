param(
    [Parameter(Mandatory = $true)]
    [string]$PolicyDecision,

    [Parameter(Mandatory = $true)]
    [string]$PolicyStatus,

    [Parameter(Mandatory = $true)]
    [bool]$PolicyAllowed,

    [Parameter(Mandatory = $true)]
    [string]$WorkerId,

    [Parameter(Mandatory = $true)]
    [string]$SkillId,

    [Parameter(Mandatory = $true)]
    [string]$ToolId,

    [Parameter(Mandatory = $true)]
    [string]$Action,

    [string]$ExecutionId,

    [string]$CorrelationId,

    [string]$TenantId,

    [string]$ClientId,

    [string]$ProjectId,

    [string]$Mode = "SIMULATION",

    [switch]$Execute
)

$ErrorActionPreference = "Stop"

function New-RuntimeDecision {
    param(
        [string]$Decision,
        [string]$Status,
        [string]$Reason,
        [bool]$ExecutionAllowed,
        [bool]$ExternalCallAllowed,
        [bool]$HumanApprovalRequired
    )

    [PSCustomObject]@{
        schema = "BK-AI-WORKERS-INTEGRATION-RUNTIME-DECISION"
        version = "7H-16"
        timestamp = (Get-Date).ToString("o")

        executionId = $ExecutionId
        correlationId = $CorrelationId

        tenantId = $TenantId
        clientId = $ClientId
        projectId = $ProjectId

        workerId = $WorkerId
        skillId = $SkillId
        toolId = $ToolId
        action = $Action

        mode = $Mode

        policyDecision = $PolicyDecision
        policyStatus = $PolicyStatus
        policyAllowed = $PolicyAllowed

        decision = $Decision
        status = $Status

        executionAllowed = $ExecutionAllowed
        externalCallAllowed = $ExternalCallAllowed
        humanApprovalRequired = $HumanApprovalRequired

        executed = $false
        reason = $Reason
    }
}

# ============================================================
# IDENTITE OBLIGATOIRE
# ============================================================

$Required = [ordered]@{
    ExecutionId = $ExecutionId
    CorrelationId = $CorrelationId
    TenantId = $TenantId
    ClientId = $ClientId
    ProjectId = $ProjectId
    WorkerId = $WorkerId
    SkillId = $SkillId
    ToolId = $ToolId
    Action = $Action
}

foreach ($Item in $Required.GetEnumerator()) {

    if ([string]::IsNullOrWhiteSpace([string]$Item.Value)) {

        return New-RuntimeDecision `
            -Decision "BLOCKED" `
            -Status "CONTEXT_INCOMPLETE" `
            -Reason "Champ obligatoire absent : $($Item.Key)" `
            -ExecutionAllowed $false `
            -ExternalCallAllowed $false `
            -HumanApprovalRequired $false
    }
}

# ============================================================
# COHERENCE POLICY
# ============================================================

if (-not $PolicyAllowed) {

    if ($PolicyDecision -eq "NEEDS_HUMAN") {

        return New-RuntimeDecision `
            -Decision "NEEDS_HUMAN" `
            -Status "HUMAN_APPROVAL_REQUIRED" `
            -Reason "La politique d'exécution exige une validation humaine." `
            -ExecutionAllowed $false `
            -ExternalCallAllowed $false `
            -HumanApprovalRequired $true
    }

    return New-RuntimeDecision `
        -Decision "BLOCKED" `
        -Status "POLICY_BLOCKED" `
        -Reason "La politique d'exécution interdit l'opération." `
        -ExecutionAllowed $false `
        -ExternalCallAllowed $false `
        -HumanApprovalRequired $false
}

# ============================================================
# MODE
# ============================================================

$ModeUpper = $Mode.ToUpperInvariant()

if ($ModeUpper -eq "SIMULATION") {

    if ($Execute) {

        return New-RuntimeDecision `
            -Decision "BLOCKED" `
            -Status "SIMULATION_NO_EXTERNAL_EXECUTION" `
            -Reason "Une simulation ne peut pas déclencher une action externe réelle." `
            -ExecutionAllowed $false `
            -ExternalCallAllowed $false `
            -HumanApprovalRequired $false
    }

    return New-RuntimeDecision `
        -Decision "SIMULATION" `
        -Status "RUNTIME_SIMULATION_ALLOWED" `
        -Reason "Execution de simulation autorisée ; aucun appel externe réel." `
        -ExecutionAllowed $true `
        -ExternalCallAllowed $false `
        -HumanApprovalRequired $false
}

# ============================================================
# MODE LIVE
# ============================================================

if ($ModeUpper -eq "LIVE") {

    if (-not $Execute) {

        return New-RuntimeDecision `
            -Decision "LIVE_READY" `
            -Status "READY_FOR_EXTERNAL_EXECUTION" `
            -Reason "Le Runtime peut préparer l'exécution LIVE sans la déclencher." `
            -ExecutionAllowed $true `
            -ExternalCallAllowed $false `
            -HumanApprovalRequired $false
    }

    return New-RuntimeDecision `
        -Decision "LIVE_EXECUTION_AUTHORIZED" `
        -Status "EXTERNAL_EXECUTION_ALLOWED" `
        -Reason "La politique autorise l'exécution LIVE et le Runtime peut transmettre vers l'adaptateur d'intégration." `
        -ExecutionAllowed $true `
        -ExternalCallAllowed $true `
        -HumanApprovalRequired $false
}

# ============================================================
# MODE INCONNU
# ============================================================

return New-RuntimeDecision `
    -Decision "BLOCKED" `
    -Status "INVALID_MODE" `
    -Reason "Mode Runtime inconnu." `
    -ExecutionAllowed $false `
    -ExternalCallAllowed $false `
    -HumanApprovalRequired $false