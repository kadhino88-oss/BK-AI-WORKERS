# BK AI WORKERS
# MAYA - CAMPAIGN PLANNER
# PHASE 7G-6
# MULTI-WORKER ORCHESTRATION
# TASK DERIVATION FIX

param(
    [Parameter(Mandatory=$true)]
    [string]$ClientId,

    [Parameter(Mandatory=$true)]
    [string]$ProjectId,

    [Parameter(Mandatory=$true)]
    [string]$TaskId,

    [Parameter(Mandatory=$true)]
    [string]$Objective,

    [Parameter(Mandatory=$true)]
    [string]$MayaResultPath
)

$ErrorActionPreference = "Stop"

$projectRoot = "C:\Users\FEUCOM\BK-AI-WORKERS"
$runtimePath = Join-Path $projectRoot "memory\runtime"
$workflowDir = Join-Path $projectRoot "orchestrator\workflows"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " MAYA - CAMPAIGN PLANNER"
Write-Host " PHASE 7G-6"
Write-Host " MULTI-WORKER ORCHESTRATION"
Write-Host "============================================"
Write-Host ""

Write-Host "CLIENT   : $ClientId"
Write-Host "PROJECT  : $ProjectId"
Write-Host "TASK     : $TaskId"
Write-Host ""

if (!(Test-Path -LiteralPath $MayaResultPath)) {
    Write-Host "MAYA RESULT : NOT FOUND"
    exit 1
}

try {
    $maya = Get-Content -LiteralPath $MayaResultPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "MAYA RESULT : INVALID JSON"
    exit 1
}

if ($maya.worker -ne "MAYA") {
    Write-Host "MAYA IDENTITY : INVALID"
    exit 1
}

if ($maya.client_id -ne $ClientId) {
    Write-Host "CLIENT IDENTITY : INVALID"
    exit 1
}

if ($maya.project_id -ne $ProjectId) {
    Write-Host "PROJECT IDENTITY : INVALID"
    exit 1
}

if ($maya.security_status -ne "VALID") {
    Write-Host "SECURITY : INVALID"
    exit 1
}

if ($maya.financial_actions -ne $false) {
    Write-Host "FINANCE : ERROR"
    exit 1
}

if ($maya.external_actions -ne $false) {
    Write-Host "EXTERNAL : ERROR"
    exit 1
}

$sourceTaskId = $maya.task_id

if ([string]::IsNullOrWhiteSpace($sourceTaskId)) {
    Write-Host "SOURCE TASK : INVALID"
    exit 1
}

Write-Host "MAYA RESULT   : VALID"
Write-Host "SOURCE TASK   : $sourceTaskId"
Write-Host "CAMPAIGN TASK : $TaskId"
Write-Host "SECURITY      : VALID"
Write-Host "FINANCE       : BLOCKED"
Write-Host "EXTERNAL      : BLOCKED"

$workflowId = "WF-$((Get-Date).ToString('yyyyMMdd-HHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0,6))"

$workflowPath = Join-Path $workflowDir "$workflowId.json"

$steps = @(
    [ordered]@{
        id = "STEP-01"
        worker = "MAYA"
        objective = "Finaliser la stratégie marketing et les priorités de campagne."
        depends_on = @()
        status = "READY"
        source_task_id = $sourceTaskId
    },
    [ordered]@{
        id = "STEP-02"
        worker = "ALEX"
        objective = "Transformer la stratégie en plan de prospection et liste de prospects prioritaires."
        depends_on = @("STEP-01")
        status = "BLOCKED"
    },
    [ordered]@{
        id = "STEP-03"
        worker = "EMMA"
        objective = "Transformer la stratégie en calendrier éditorial et contenus sociaux."
        depends_on = @("STEP-01")
        status = "BLOCKED"
    },
    [ordered]@{
        id = "STEP-04"
        worker = "LEA"
        objective = "Décliner la stratégie en direction artistique et assets créatifs."
        depends_on = @("STEP-01")
        status = "BLOCKED"
    },
    [ordered]@{
        id = "STEP-05"
        worker = "LUCAS"
        objective = "Créer la structure de landing page et le plan SEO à partir de la stratégie et des livrables disponibles."
        depends_on = @("STEP-01","STEP-03","STEP-04")
        status = "BLOCKED"
    },
    [ordered]@{
        id = "STEP-06"
        worker = "SAM"
        objective = "Effectuer le contrôle sécurité avant mise en production."
        depends_on = @("STEP-05")
        status = "BLOCKED"
    },
    [ordered]@{
        id = "STEP-07"
        worker = "ORCHESTRATOR"
        objective = "Consolider les résultats et produire le rapport final de campagne."
        depends_on = @("STEP-02","STEP-03","STEP-04","STEP-05","STEP-06")
        status = "BLOCKED"
    }
)

$workflow = [ordered]@{
    workflow_id = $workflowId
    client_id = $ClientId
    project_id = $ProjectId
    source_task_id = $sourceTaskId
    campaign_task_id = $TaskId
    type = "MARKETING_CAMPAIGN"
    objective = $Objective
    created_by = "MAYA"
    status = "READY"
    execution_mode = "CONTROLLED"
    financial_actions = $false
    external_actions = $false
    security_status = "VALID"
    provider = $maya.provider
    model = $maya.model
    source_maya_result = $MayaResultPath
    steps = $steps
    created_at = (Get-Date).ToString("o")
}

New-Item -ItemType Directory -Force -Path $workflowDir | Out-Null

$workflow |
    ConvertTo-Json -Depth 30 |
    Set-Content -LiteralPath $workflowPath -Encoding UTF8

$reportPath = Join-Path $runtimePath "MAYA-CAMPAIGN-$TaskId.json"

$report = [ordered]@{
    status = "SUCCESS"
    worker = "MAYA"
    client_id = $ClientId
    project_id = $ProjectId
    task_id = $TaskId
    source_task_id = $sourceTaskId
    workflow_id = $workflowId
    workflow_path = $workflowPath
    type = "MARKETING_CAMPAIGN"
    objective = $Objective
    workers = @(
        "MAYA",
        "ALEX",
        "EMMA",
        "LEA",
        "LUCAS",
        "SAM",
        "ORCHESTRATOR"
    )
    dependencies_validated = $true
    security_status = "VALID"
    financial_actions = $false
    external_actions = $false
    execution_mode = "CONTROLLED"
    next_action = "Orchestrator can execute workflow steps according to dependencies."
    generated_at = (Get-Date).ToString("o")
}

$report |
    ConvertTo-Json -Depth 30 |
    Set-Content -LiteralPath $reportPath -Encoding UTF8

Write-Host ""
Write-Host "============================================"
Write-Host " CAMPAIGN PLAN"
Write-Host "============================================"
Write-Host ""

Write-Host "WORKFLOW ID : $workflowId"
Write-Host "TYPE        : MARKETING_CAMPAIGN"
Write-Host "STATUS      : READY"
Write-Host "SOURCE TASK : $sourceTaskId"
Write-Host "CAMPAIGN TASK: $TaskId"
Write-Host ""

Write-Host "STEP-01 MAYA         : READY"
Write-Host "STEP-02 ALEX         : BLOCKED -> STEP-01"
Write-Host "STEP-03 EMMA         : BLOCKED -> STEP-01"
Write-Host "STEP-04 LEA          : BLOCKED -> STEP-01"
Write-Host "STEP-05 LUCAS        : BLOCKED -> STEP-01 + STEP-03 + STEP-04"
Write-Host "STEP-06 SAM          : BLOCKED -> STEP-05"
Write-Host "STEP-07 ORCHESTRATOR : BLOCKED -> ALL"

Write-Host ""
Write-Host "SECURITY       : VALID"
Write-Host "FINANCE        : BLOCKED"
Write-Host "EXTERNAL       : BLOCKED"
Write-Host "EXECUTION      : CONTROLLED"
Write-Host ""

Write-Host "WORKFLOW FILE : $workflowPath"
Write-Host "REPORT FILE   : $reportPath"
Write-Host ""
Write-Host "MAYA CAMPAIGN PLANNER : READY"