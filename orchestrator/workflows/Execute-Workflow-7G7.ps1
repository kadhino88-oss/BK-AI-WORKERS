# BK AI WORKERS
# WORKFLOW EXECUTOR
# PHASE 7G-7
# CONTROLLED MULTI-WORKER EXECUTION

param(
    [Parameter(Mandatory=$true)]
    [string]$WorkflowPath
)

$ErrorActionPreference = "Stop"

$projectRoot = "C:\Users\FEUCOM\BK-AI-WORKERS"
$runtimePath = Join-Path $projectRoot "memory\runtime"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " WORKFLOW EXECUTOR"
Write-Host " PHASE 7G-7"
Write-Host " CONTROLLED MULTI-WORKER EXECUTION"
Write-Host "============================================"
Write-Host ""

if (!(Test-Path -LiteralPath $WorkflowPath)) {
    Write-Host "WORKFLOW : NOT FOUND"
    exit 1
}

try {
    $workflow = Get-Content -LiteralPath $WorkflowPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "WORKFLOW JSON : INVALID"
    exit 1
}

$workflowId = $workflow.workflow_id
$clientId = $workflow.client_id
$projectId = $workflow.project_id
$sourceTaskId = $workflow.source_task_id
$campaignTaskId = $workflow.campaign_task_id

Write-Host "WORKFLOW : $workflowId"
Write-Host "CLIENT   : $clientId"
Write-Host "PROJECT  : $projectId"
Write-Host "SOURCE   : $sourceTaskId"
Write-Host "CAMPAIGN : $campaignTaskId"
Write-Host ""

if ($workflow.security_status -ne "VALID") {
    Write-Host "SECURITY : INVALID"
    exit 1
}

if ($workflow.financial_actions -ne $false) {
    Write-Host "FINANCE : ERROR"
    exit 1
}

if ($workflow.external_actions -ne $false) {
    Write-Host "EXTERNAL : ERROR"
    exit 1
}

if ($workflow.execution_mode -ne "CONTROLLED") {
    Write-Host "EXECUTION MODE : INVALID"
    exit 1
}

Write-Host "SECURITY        : VALID"
Write-Host "FINANCE         : BLOCKED"
Write-Host "EXTERNAL        : BLOCKED"
Write-Host "EXECUTION MODE  : CONTROLLED"

$steps = @($workflow.steps)

if ($steps.Count -eq 0) {
    Write-Host "STEPS : EMPTY"
    exit 1
}

$state = [ordered]@{
    workflow_id = $workflowId
    client_id = $clientId
    project_id = $projectId
    source_task_id = $sourceTaskId
    campaign_task_id = $campaignTaskId
    status = "RUNNING"
    execution_mode = "CONTROLLED"
    security_status = "VALID"
    financial_actions = $false
    external_actions = $false
    started_at = (Get-Date).ToString("o")
    steps = @()
}

$completed = @{}

foreach ($step in $steps) {

    $stepId = $step.id
    $worker = $step.worker
    $depends = @($step.depends_on)

    Write-Host ""
    Write-Host "--------------------------------------------"
    Write-Host "STEP : $stepId"
    Write-Host "WORKER : $worker"
    Write-Host "--------------------------------------------"

    $dependencyFailure = $false

    foreach ($dependency in $depends) {
        if (!$completed.ContainsKey($dependency) -or $completed[$dependency] -ne "SUCCESS") {
            Write-Host "DEPENDENCY : BLOCKED"
            Write-Host "WAITING FOR : $dependency"
            $dependencyFailure = $true
        }
    }

    if ($dependencyFailure) {
        $stepStatus = "BLOCKED"
        $reason = "DEPENDENCY_NOT_COMPLETED"
    }
    elseif ($worker -eq "ORCHESTRATOR") {
        Write-Host "MODE : LOCAL CONSOLIDATION"
        Write-Host "STATUS : SUCCESS"
        $stepStatus = "SUCCESS"
        $reason = "FINAL_CONSOLIDATION"
    }
    else {
        Write-Host "MODE : CONTROLLED LOCAL WORKER"
        Write-Host "OBJECTIVE : $($step.objective)"
        Write-Host "FINANCE : BLOCKED"
        Write-Host "EXTERNAL : BLOCKED"
        Write-Host "STATUS : SUCCESS"
        $stepStatus = "SUCCESS"
        $reason = "LOCAL_CONTROLLED_EXECUTION"
    }

    $completed[$stepId] = $stepStatus

    $state.steps += [ordered]@{
        id = $stepId
        worker = $worker
        objective = $step.objective
        depends_on = $depends
        status = $stepStatus
        reason = $reason
        executed_at = (Get-Date).ToString("o")
    }

    if ($stepStatus -ne "SUCCESS") {
        $state.status = "BLOCKED"
        break
    }
}

$failedSteps = @($state.steps | Where-Object { $_.status -ne "SUCCESS" })

if ($failedSteps.Count -eq 0) {
    $state.status = "SUCCESS"
}
else {
    $state.status = "BLOCKED"
}

$state.completed_at = (Get-Date).ToString("o")
$state.successful_steps = @($state.steps | Where-Object { $_.status -eq "SUCCESS" }).Count
$state.total_steps = $steps.Count

New-Item -ItemType Directory -Force -Path $runtimePath | Out-Null

$statePath = Join-Path $runtimePath "WORKFLOW-STATE-$workflowId.json"

$state |
    ConvertTo-Json -Depth 30 |
    Set-Content -LiteralPath $statePath -Encoding UTF8

$reportPath = Join-Path $runtimePath "WORKFLOW-REPORT-$workflowId.json"

$report = [ordered]@{
    workflow_id = $workflowId
    client_id = $clientId
    project_id = $projectId
    campaign_task_id = $campaignTaskId
    status = $state.status
    execution_mode = "CONTROLLED_LOCAL"
    total_steps = $steps.Count
    successful_steps = $state.successful_steps
    failed_steps = $failedSteps.Count
    workers = @($state.steps | ForEach-Object { $_.worker })
    security_status = "VALID"
    financial_actions = $false
    external_actions = $false
    state_file = $statePath
    next_action = if ($state.status -eq "SUCCESS") {
        "Workflow terminé. Les résultats peuvent maintenant être consolidés par l'Orchestrator."
    }
    else {
        "Corriger les dépendances bloquées avant nouvelle exécution."
    }
    generated_at = (Get-Date).ToString("o")
}

$report |
    ConvertTo-Json -Depth 30 |
    Set-Content -LiteralPath $reportPath -Encoding UTF8

Write-Host ""
Write-Host "============================================"
Write-Host " PHASE 7G-7 RESULT"
Write-Host "============================================"
Write-Host ""

Write-Host "WORKFLOW       : $workflowId"
Write-Host "STATUS         : $($state.status)"
Write-Host "TOTAL STEPS    : $($steps.Count)"
Write-Host "SUCCESS STEPS  : $($state.successful_steps)"
Write-Host "FAILED STEPS   : $($failedSteps.Count)"
Write-Host "SECURITY       : VALID"
Write-Host "FINANCE        : BLOCKED"
Write-Host "EXTERNAL       : BLOCKED"
Write-Host "MODE           : CONTROLLED_LOCAL"
Write-Host ""

Write-Host "STATE FILE     : $statePath"
Write-Host "REPORT FILE    : $reportPath"
Write-Host ""

if ($state.status -eq "SUCCESS") {
    Write-Host "WORKFLOW EXECUTION : SUCCESS"
    exit 0
}

Write-Host "WORKFLOW EXECUTION : BLOCKED"
exit 1