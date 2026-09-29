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

    [string]$TaskId,

    [string]$Mode = "SIMULATION",

    [switch]$FinancialRequested
)

$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$EnforcerPath = Join-Path `
    $Root `
    "core\permissions\capability-matrix\CAPABILITY-ENFORCER.ps1"

$AuditDir = Join-Path `
    $Root `
    "core\logging\audit"

$AuditPath = Join-Path `
    $AuditDir `
    "CAPABILITY-AUDIT.jsonl"

$ToolsDir = Join-Path `
    $Root `
    "core\tools"

New-Item -ItemType Directory -Force -Path $AuditDir | Out-Null

function Write-Audit {
    param(
        [Parameter(Mandatory = $true)]
        $Decision,

        [bool]$ExecutionDelegated = $false,

        [string]$ExecutionStatus = "NOT_EXECUTED",

        [string]$ExecutionError = ""
    )

    $Record = [ordered]@{
        schema = "BK-AI-WORKERS-CAPABILITY-AUDIT-7H12"
        version = "7H-12"
        timestamp = (Get-Date).ToString("o")
        workerId = $Decision.workerId
        skillId = $Decision.skillId
        toolId = $Decision.toolId
        action = $Decision.action
        clientId = $Decision.clientId
        projectId = $Decision.projectId
        taskId = $TaskId
        mode = $Decision.mode
        decision = $Decision.decision
        status = $Decision.status
        authorized = $Decision.authorized
        humanApprovalRequired = $Decision.humanApprovalRequired
        reason = $Decision.reason
        executionDelegated = $ExecutionDelegated
        executionStatus = $ExecutionStatus
        executionError = $ExecutionError
    }

    $Json = $Record | ConvertTo-Json -Compress -Depth 12

    Add-Content `
        -LiteralPath $AuditPath `
        -Value $Json `
        -Encoding UTF8
}

# ============================================================
# 1. ENFORCER
# ============================================================

if (-not (Test-Path -LiteralPath $EnforcerPath)) {
    throw "CAPABILITY-ENFORCER.ps1 introuvable."
}

$Decision = & $EnforcerPath `
    -WorkerId $WorkerId `
    -SkillId $SkillId `
    -ToolId $ToolId `
    -Action $Action `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -Mode $Mode `
    -FinancialRequested:$FinancialRequested

if ($null -eq $Decision) {
    throw "Aucune décision retournée par Capability Enforcer."
}

# ============================================================
# 2. BLOCAGE PAR CAPABILITY
# ============================================================

if ($Decision.decision -ne "AUTHORIZED") {

    Write-Audit `
        -Decision $Decision `
        -ExecutionDelegated:$false `
        -ExecutionStatus "BLOCKED"

    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Yellow
    Write-Host "       TOOL ROUTER : EXECUTION BLOQUEE" -ForegroundColor Yellow
    Write-Host "==============================================" -ForegroundColor Yellow
    Write-Host ""

    Write-Host "Worker   : $WorkerId"
    Write-Host "Skill    : $SkillId"
    Write-Host "Tool     : $ToolId"
    Write-Host "Action   : $Action"
    Write-Host "Client   : $ClientId"
    Write-Host "Projet   : $ProjectId"
    Write-Host "Task     : $TaskId"
    Write-Host ""
    Write-Host "Decision : $($Decision.decision)" -ForegroundColor Yellow
    Write-Host "Status   : $($Decision.status)" -ForegroundColor Yellow
    Write-Host "Raison   : $($Decision.reason)" -ForegroundColor Yellow
    Write-Host ""

    return $Decision
}

# ============================================================
# 3. RECHERCHE ROUTER LEGACY
# ============================================================

$LegacyRouters = @(
    Get-ChildItem `
        -LiteralPath $ToolsDir `
        -Filter "TOOL-ROUTER-LEGACY-*.ps1" `
        -File `
        -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending
)

$LegacyRouter = $LegacyRouters | Select-Object -First 1

if ($null -eq $LegacyRouter) {

    Write-Audit `
        -Decision $Decision `
        -ExecutionDelegated:$false `
        -ExecutionStatus "AUTHORIZED_NOT_DELEGATED"

    return [PSCustomObject]@{
        authorization = $Decision
        executionDelegated = $false
        executionStatus = "AUTHORIZED_NOT_DELEGATED"
        reason = "Aucun Router legacy disponible."
    }
}

# ============================================================
# 4. INSPECTION DU CONTRAT LEGACY
# ============================================================

try {

    $LegacyCommand = Get-Command `
        -Name $LegacyRouter.FullName `
        -ErrorAction Stop

    $SupportedParameters = @(
        $LegacyCommand.Parameters.Keys
    )

}
catch {

    Write-Audit `
        -Decision $Decision `
        -ExecutionDelegated:$false `
        -ExecutionStatus "LEGACY_INSPECTION_FAILED" `
        -ExecutionError $_.Exception.Message

    return [PSCustomObject]@{
        authorization = $Decision
        executionDelegated = $false
        executionStatus = "LEGACY_INSPECTION_FAILED"
        error = $_.Exception.Message
    }
}

# ============================================================
# 5. CONSTRUCTION DES PARAMETRES
# ============================================================

$CandidateParams = [ordered]@{
    WorkerId = $WorkerId
    SkillId = $SkillId
    ToolId = $ToolId
    Action = $Action
    ClientId = $ClientId
    ProjectId = $ProjectId
    TaskId = $TaskId
    Mode = $Mode
}

$LegacyParams = @{}

foreach ($Name in $CandidateParams.Keys) {

    if ($SupportedParameters -contains $Name) {

        $Value = $CandidateParams[$Name]

        if ($null -ne $Value) {

            $LegacyParams[$Name] = $Value
        }
    }
}

# ============================================================
# 6. DETECTION DES PARAMETRES OBLIGATOIRES DU LEGACY
# ============================================================

$MissingMandatory = @()

foreach ($ParameterName in $SupportedParameters) {

    $ParameterMetadata = $LegacyCommand.Parameters[$ParameterName]

    if ($null -eq $ParameterMetadata) {
        continue
    }

    $IsMandatory = $false

    foreach ($Attribute in @($ParameterMetadata.Attributes)) {

        if (
            $Attribute.PSObject.Properties.Name -contains "Mandatory" `
            -and $Attribute.Mandatory -eq $true
        ) {
            $IsMandatory = $true
            break
        }
    }

    if ($IsMandatory) {

        if (
            (-not $LegacyParams.ContainsKey($ParameterName)) `
            -or `
            [string]::IsNullOrWhiteSpace([string]$LegacyParams[$ParameterName])
        ) {

            $MissingMandatory += $ParameterName
        }
    }
}

# ============================================================
# 7. AUCUNE INVITE INTERACTIVE
# ============================================================

if ($MissingMandatory.Count -gt 0) {

    $MissingList = $MissingMandatory -join ", "

    $WriteMessage = "Paramètre(s) obligatoire(s) du Router legacy manquant(s) : $MissingList"

    Write-Audit `
        -Decision $Decision `
        -ExecutionDelegated:$false `
        -ExecutionStatus "LEGACY_PREREQUISITE_MISSING" `
        -ExecutionError $WriteMessage

    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Yellow
    Write-Host "       DELEGATION LEGACY NON EXECUTEE" -ForegroundColor Yellow
    Write-Host "==============================================" -ForegroundColor Yellow
    Write-Host ""

    Write-Host $WriteMessage -ForegroundColor Yellow
    Write-Host "Aucune invite interactive n'est autorisée." -ForegroundColor Cyan
    Write-Host ""

    return [PSCustomObject]@{
        authorization = $Decision
        executionDelegated = $false
        executionStatus = "LEGACY_PREREQUISITE_MISSING"
        missingMandatoryParameters = @($MissingMandatory)
        legacyRouter = $LegacyRouter.FullName
    }
}

# ============================================================
# 8. DELEGATION LEGACY
# ============================================================

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host "        TOOL ROUTER : AUTORISATION OK" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host ""

Write-Host "Worker : $WorkerId"
Write-Host "Skill  : $SkillId"
Write-Host "Tool   : $ToolId"
Write-Host "Action : $Action"
Write-Host "Client : $ClientId"
Write-Host "Projet : $ProjectId"
Write-Host "Task   : $TaskId"
Write-Host ""

Write-Host "Router legacy :" -ForegroundColor Cyan
Write-Host $LegacyRouter.FullName
Write-Host ""

Write-Host "Paramètres transmis :" -ForegroundColor Cyan

foreach ($Key in $LegacyParams.Keys) {
    Write-Host " - $Key"
}

try {

    $LegacyResult = & $LegacyRouter.FullName @LegacyParams

    Write-Audit `
        -Decision $Decision `
        -ExecutionDelegated:$true `
        -ExecutionStatus "DELEGATED_SUCCESS"

    return [PSCustomObject]@{
        authorization = $Decision
        executionDelegated = $true
        executionStatus = "DELEGATED_SUCCESS"
        legacyRouter = $LegacyRouter.FullName
        legacyParameters = @($LegacyParams.Keys)
        legacyResult = $LegacyResult
    }

}
catch {

    $ErrorMessage = $_.Exception.Message

    Write-Audit `
        -Decision $Decision `
        -ExecutionDelegated:$false `
        -ExecutionStatus "DELEGATION_FAILED" `
        -ExecutionError $ErrorMessage

    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Red
    Write-Host "          ERREUR DE DELEGATION" -ForegroundColor Red
    Write-Host "==============================================" -ForegroundColor Red
    Write-Host ""

    Write-Host $ErrorMessage -ForegroundColor Red
    Write-Host ""

    return [PSCustomObject]@{
        authorization = $Decision
        executionDelegated = $false
        executionStatus = "DELEGATION_FAILED"
        legacyRouter = $LegacyRouter.FullName
        legacyParameters = @($LegacyParams.Keys)
        executionError = $ErrorMessage
    }
}