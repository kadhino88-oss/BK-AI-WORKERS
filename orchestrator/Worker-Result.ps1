# ============================================================
# BK AI WORKERS
# WORKER RESULT ENGINE
# PHASE 6B-2
# ============================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$ExecutionPath
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "============================================"
Write-Host " WORKER RESULT"
Write-Host "============================================"
Write-Host ""

# ------------------------------------------------------------
# ROOT
# ------------------------------------------------------------

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$Runtime = Join-Path $Root "memory\runtime"

# ------------------------------------------------------------
# VALIDATION DU FICHIER D'EXECUTION
# ------------------------------------------------------------

if (-not (Test-Path $ExecutionPath)) {
    Write-Host "STATUS : ERROR" -ForegroundColor Red
    Write-Host "REASON : EXECUTION FILE NOT FOUND"
    Write-Host "FILE   : $ExecutionPath"
    exit 1
}

# ------------------------------------------------------------
# CHARGEMENT
# ------------------------------------------------------------

try {
    $Execution = Get-Content $ExecutionPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Write-Host "STATUS : ERROR" -ForegroundColor Red
    Write-Host "REASON : INVALID EXECUTION JSON"
    exit 1
}

# ------------------------------------------------------------
# IDENTITE
# ------------------------------------------------------------

$ClientId = $Execution.client_id
$ProjectId = $Execution.project_id
$WorkerId = $Execution.worker_id
$TaskId = $Execution.task_id

if ([string]::IsNullOrWhiteSpace($ClientId)) {
    $ClientId = $Execution.context.client_id
}

if ([string]::IsNullOrWhiteSpace($ProjectId)) {
    $ProjectId = $Execution.context.project_id
}

if ([string]::IsNullOrWhiteSpace($WorkerId)) {
    $WorkerId = $Execution.context.worker_id
}

if ([string]::IsNullOrWhiteSpace($TaskId)) {
    $TaskId = $Execution.context.task_id
}

# ------------------------------------------------------------
# VALIDATION IDENTITE
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($ClientId) -or
    [string]::IsNullOrWhiteSpace($ProjectId) -or
    [string]::IsNullOrWhiteSpace($WorkerId) -or
    [string]::IsNullOrWhiteSpace($TaskId)) {

    Write-Host "STATUS : ERROR" -ForegroundColor Red
    Write-Host "REASON : EXECUTION IDENTITY INCOMPLETE"
    exit 1
}

Write-Host "CLIENT  : $ClientId"
Write-Host "PROJECT : $ProjectId"
Write-Host "WORKER  : $WorkerId"
Write-Host "TASK    : $TaskId"
Write-Host ""

# ------------------------------------------------------------
# SECURITE
# ------------------------------------------------------------

$FinancialActions = $false
$ExternalActions = $false

if ($null -ne $Execution.permissions) {

    if ($Execution.permissions.financial_actions -eq $true) {
        $FinancialActions = $true
    }

    if ($Execution.permissions.external_actions -eq $true) {
        $ExternalActions = $true
    }
}

if ($FinancialActions) {

    Write-Host "STATUS : BLOCKED" -ForegroundColor Red
    Write-Host "REASON : FINANCIAL ACTION DETECTED"
    exit 1
}

if ($ExternalActions) {

    Write-Host "STATUS : BLOCKED" -ForegroundColor Red
    Write-Host "REASON : EXTERNAL ACTION DETECTED"
    exit 1
}

Write-Host "SECURITY : VALID"
Write-Host "FINANCE  : BLOCKED"
Write-Host "EXTERNAL : BLOCKED"
Write-Host ""

# ------------------------------------------------------------
# RESULTAT WORKER
# ------------------------------------------------------------

$WorkerStatus = "SUCCESS"

if ($null -ne $Execution.result) {

    if (-not [string]::IsNullOrWhiteSpace($Execution.result.status)) {
        $WorkerStatus = $Execution.result.status
    }
}

if (-not [string]::IsNullOrWhiteSpace($Execution.status)) {

    if ($Execution.status -in @(
        "SUCCESS",
        "PARTIAL_SUCCESS",
        "BLOCKED",
        "NEEDS_HUMAN",
        "ERROR"
    )) {
        $WorkerStatus = $Execution.status
    }
}

# ------------------------------------------------------------
# RESULTAT FINAL
# ------------------------------------------------------------

$ResultPath = Join-Path $Runtime "RESULT-$TaskId.json"

$Result = [ordered]@{
    result_id = "RESULT-$TaskId"
    client_id = $ClientId
    project_id = $ProjectId
    worker_id = $WorkerId
    task_id = $TaskId

    status = $WorkerStatus

    execution_file = $ExecutionPath

    security = [ordered]@{
        financial_actions = $false
        external_actions = $false
        validated = $true
    }

    mode = "SIMULATION"

    completed_at = (Get-Date).ToString("o")
}

$Result | ConvertTo-Json -Depth 10 |
    Set-Content -Path $ResultPath -Encoding UTF8

# ------------------------------------------------------------
# AFFICHAGE
# ------------------------------------------------------------

Write-Host ""
Write-Host "RESULT : $WorkerStatus" -ForegroundColor Green
Write-Host "MODE   : SIMULATION"
Write-Host ""
Write-Host "OUTPUT : $ResultPath"
Write-Host ""
Write-Host "WORKER RESULT : READY" -ForegroundColor Green
Write-Host ""

exit 0