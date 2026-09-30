param(
    [Parameter(Mandatory = $true)]
    [string]$AuthorizationDecision,

    [Parameter(Mandatory = $true)]
    [string]$WorkerId,

    [Parameter(Mandatory = $true)]
    [string]$SkillId,

    [Parameter(Mandatory = $true)]
    [string]$ToolId,

    [Parameter(Mandatory = $true)]
    [string]$Action,

    [string]$Mode = "SIMULATION",

    [bool]$HumanApproved = $false,

    [switch]$FinancialRequested
)

$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$ConfigPath = "$Root\core\runtime\execution-policy\EXECUTION-POLICY-CONFIG.json"

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Execution Policy Config introuvable."
}

$Config = Get-Content `
    -LiteralPath $ConfigPath `
    -Raw `
    -Encoding UTF8 |
    ConvertFrom-Json

function New-PolicyDecision {
    param(
        [string]$Decision,
        [string]$Status,
        [string]$Reason,
        [bool]$Allowed,
        [bool]$HumanRequired
    )

    [PSCustomObject]@{
        schema = "BK-AI-WORKERS-EXECUTION-POLICY-DECISION"
        version = "7H-15"
        timestamp = (Get-Date).ToString("o")

        workerId = $WorkerId
        skillId = $SkillId
        toolId = $ToolId
        action = $Action
        mode = $Mode

        authorizationDecision = $AuthorizationDecision

        decision = $Decision
        status = $Status
        allowed = $Allowed
        humanApprovalRequired = $HumanRequired

        reason = $Reason
    }
}

# ============================================================
# AUTHORIZATION MUST COME FIRST
# ============================================================

if ($AuthorizationDecision -ne "AUTHORIZED") {

    if ($AuthorizationDecision -eq "NEEDS_HUMAN") {

        return New-PolicyDecision `
            -Decision "NEEDS_HUMAN" `
            -Status "KADER_APPROVAL_REQUIRED" `
            -Reason "L'autorisation précédente exige une validation humaine." `
            -Allowed $false `
            -HumanRequired $true
    }

    return New-PolicyDecision `
        -Decision "BLOCKED" `
        -Status "AUTHORIZATION_FAILED" `
        -Reason "Une exécution ne peut pas être autorisée sans Capability Enforcement valide." `
        -Allowed $false `
        -HumanRequired $false
}

# ============================================================
# FINANCE
# ============================================================

$ActionUpper = $Action.ToUpperInvariant()
$ToolUpper = $ToolId.ToUpperInvariant()

$FinancialAction = @(
    $Config.financial.actions
) -contains $ActionUpper

$FinancialTool = @(
    "PAYMENTS",
    "PAYMENT",
    "BANKING",
    "ACCOUNTING",
    "ERP"
) -contains $ToolUpper

if ($FinancialRequested -or $FinancialAction -or $FinancialTool) {

    if ($HumanApproved) {

        return New-PolicyDecision `
            -Decision "LIVE" `
            -Status "HUMAN_APPROVED" `
            -Reason "Operation financière validée explicitement par un humain." `
            -Allowed $true `
            -HumanRequired $true
    }

    return New-PolicyDecision `
        -Decision "NEEDS_HUMAN" `
        -Status "KADER_APPROVAL_REQUIRED" `
        -Reason "Toute opération financière réelle nécessite une validation humaine." `
        -Allowed $false `
        -HumanRequired $true
}

# ============================================================
# BLOCK MODE UNKNOWN
# ============================================================

$ModeUpper = $Mode.ToUpperInvariant()

if ($ModeUpper -notin @("SIMULATION","LIVE")) {

    return New-PolicyDecision `
        -Decision "BLOCKED" `
        -Status "INVALID_MODE" `
        -Reason "Mode d'exécution inconnu." `
        -Allowed $false `
        -HumanRequired $false
}

# ============================================================
# SIMULATION
# ============================================================

if ($ModeUpper -eq "SIMULATION") {

    return New-PolicyDecision `
        -Decision "SIMULATION" `
        -Status "SIMULATION_ALLOWED" `
        -Reason "Execution autorisée uniquement en simulation." `
        -Allowed $true `
        -HumanRequired $false
}

# ============================================================
# LIVE
# ============================================================

if ($ModeUpper -eq "LIVE") {

    if (-not $Config.defaults.liveExecution) {

        return New-PolicyDecision `
            -Decision "BLOCKED" `
            -Status "LIVE_DISABLED" `
            -Reason "L'exécution LIVE est désactivée par défaut." `
            -Allowed $false `
            -HumanRequired $false
    }

    if ($ActionUpper -notin @($Config.liveAllowedActions)) {

        return New-PolicyDecision `
            -Decision "BLOCKED" `
            -Status "ACTION_NOT_LIVE_ALLOWED" `
            -Reason "Cette action n'est pas autorisée en LIVE." `
            -Allowed $false `
            -HumanRequired $false
    }

    if (
        $ActionUpper -in @($Config.highRiskActions) -and
        -not $HumanApproved
    ) {

        return New-PolicyDecision `
            -Decision "NEEDS_HUMAN" `
            -Status "HIGH_RISK_APPROVAL_REQUIRED" `
            -Reason "Cette action à haut risque nécessite une validation humaine selon la politique actuelle." `
            -Allowed $false `
            -HumanRequired $true
    }

    return New-PolicyDecision `
        -Decision "LIVE" `
        -Status "LIVE_ALLOWED" `
        -Reason "Execution LIVE autorisée par la politique." `
        -Allowed $true `
        -HumanRequired $false
}