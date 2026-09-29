param(
    [Parameter(Mandatory = $true)]
    [string]$WorkerId,

    [Parameter(Mandatory = $true)]
    [string]$SkillId,

    [Parameter(Mandatory = $true)]
    [string]$ToolId,

    [Parameter(Mandatory = $true)]
    [string]$Action,

    [string]$ClientId,

    [string]$ProjectId,

    [string]$Mode = "SIMULATION",

    [switch]$FinancialRequested
)

$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$MatrixPath = Join-Path $Root "core\permissions\capability-matrix\CAPABILITY-MATRIX.json"

function New-Decision {
    param(
        [string]$Decision,
        [string]$Status,
        [string]$Reason,
        [bool]$Authorized,
        [bool]$HumanApprovalRequired = $false
    )

    return [PSCustomObject]@{
        schema = "BK-AI-WORKERS-CAPABILITY-DECISION-7H11"
        version = "7H-11"
        timestamp = (Get-Date).ToString("o")
        workerId = $WorkerId
        skillId = $SkillId
        toolId = $ToolId
        action = $Action
        clientId = $ClientId
        projectId = $ProjectId
        mode = $Mode
        decision = $Decision
        status = $Status
        authorized = $Authorized
        humanApprovalRequired = $HumanApprovalRequired
        reason = $Reason
    }
}

if (-not (Test-Path -LiteralPath $MatrixPath)) {
    return New-Decision `
        -Decision "DENIED" `
        -Status "BLOCKED" `
        -Reason "Capability Matrix introuvable." `
        -Authorized $false
}

if ([string]::IsNullOrWhiteSpace($ClientId)) {
    return New-Decision `
        -Decision "DENIED" `
        -Status "BLOCKED" `
        -Reason "ClientId obligatoire pour l'isolation client." `
        -Authorized $false
}

if ([string]::IsNullOrWhiteSpace($ProjectId)) {
    return New-Decision `
        -Decision "DENIED" `
        -Status "BLOCKED" `
        -Reason "ProjectId obligatoire pour l'isolation projet." `
        -Authorized $false
}

try {
    $Matrix = Get-Content -LiteralPath $MatrixPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    return New-Decision `
        -Decision "DENIED" `
        -Status "BLOCKED" `
        -Reason "Capability Matrix JSON invalide." `
        -Authorized $false
}

# ------------------------------------------------------------
# FINANCE : REGLE ABSOLUE
# ------------------------------------------------------------

$FinancialTools = @(
    "PAYMENTS",
    "PAYMENT",
    "ACCOUNTING",
    "BANKING",
    "ERP"
)

$FinancialActions = @(
    "FINANCIAL_COMMIT",
    "PAY",
    "PAYMENT",
    "TRANSFER",
    "INVEST",
    "REFUND",
    "BANK_CHANGE"
)

if (
    $FinancialRequested -or
    ($FinancialTools -contains $ToolId.ToUpper()) -or
    ($FinancialActions -contains $Action.ToUpper())
) {
    return New-Decision `
        -Decision "NEEDS_HUMAN" `
        -Status "KADER_APPROVAL_REQUIRED" `
        -Reason "Operation financiere : aucune execution autonome autorisee." `
        -Authorized $false `
        -HumanApprovalRequired $true
}

if ($Action.ToUpper() -eq "FINANCIAL_COMMIT") {
    return New-Decision `
        -Decision "NEEDS_HUMAN" `
        -Status "KADER_APPROVAL_REQUIRED" `
        -Reason "FINANCIAL_COMMIT exige une validation humaine." `
        -Authorized $false `
        -HumanApprovalRequired $true
}

# ------------------------------------------------------------
# WORKER
# ------------------------------------------------------------

$Worker = $Matrix.workers |
    Where-Object { $_.workerId -eq $WorkerId } |
    Select-Object -First 1

if ($null -eq $Worker) {
    return New-Decision `
        -Decision "DENIED" `
        -Status "WORKER_NOT_AUTHORIZED" `
        -Reason "Worker absent de la Capability Matrix." `
        -Authorized $false
}

# ------------------------------------------------------------
# TOOL + ACTION
# ------------------------------------------------------------

$Capability = @(
    $Worker.capabilities |
    Where-Object { $_.tool -eq $ToolId }
) | Select-Object -First 1

if ($null -eq $Capability) {
    return New-Decision `
        -Decision "DENIED" `
        -Status "TOOL_NOT_AUTHORIZED" `
        -Reason "Le Worker ne dispose pas de ce Tool." `
        -Authorized $false
}

$ActionAuthorized = @($Capability.actions) -contains $Action

if (-not $ActionAuthorized) {
    return New-Decision `
        -Decision "DENIED" `
        -Status "ACTION_NOT_AUTHORIZED" `
        -Reason "L'Action n'est pas autorisee pour ce Worker et ce Tool." `
        -Authorized $false
}

# ------------------------------------------------------------
# SKILL
# ------------------------------------------------------------

$SkillValidated = $false

$SkillRegistryRelative = [string]$Worker.skillsSource

if (-not [string]::IsNullOrWhiteSpace($SkillRegistryRelative)) {

    $SkillRegistryPath = $SkillRegistryRelative -replace "/", "\"

    if (-not [System.IO.Path]::IsPathRooted($SkillRegistryPath)) {
        $SkillRegistryPath = Join-Path $Root $SkillRegistryPath
    }

    if (Test-Path -LiteralPath $SkillRegistryPath) {

        try {
            $SkillRegistryRaw = Get-Content -LiteralPath $SkillRegistryPath -Raw -Encoding UTF8

            if ($SkillRegistryRaw -match [regex]::Escape($SkillId)) {
                $SkillValidated = $true
            }
        }
        catch {
            $SkillValidated = $false
        }
    }
}

if (-not $SkillValidated) {
    return New-Decision `
        -Decision "DENIED" `
        -Status "SKILL_NOT_AUTHORIZED" `
        -Reason "Skill absente ou non retrouvee dans le registre du Worker." `
        -Authorized $false
}

# ------------------------------------------------------------
# MODE LIVE
# ------------------------------------------------------------

if ($Mode.ToUpper() -eq "LIVE") {

    return New-Decision `
        -Decision "AUTHORIZED" `
        -Status "AUTHORIZATION_VALID" `
        -Reason "Capability autorisee. L'execution LIVE doit ensuite etre controlee par l'Integration Runtime et ses politiques d'execution." `
        -Authorized $true
}

# ------------------------------------------------------------
# SIMULATION
# ------------------------------------------------------------

return New-Decision `
    -Decision "AUTHORIZED" `
    -Status "SIMULATION_AUTHORIZED" `
    -Reason "Worker + Skill + Tool + Action autorises." `
    -Authorized $true