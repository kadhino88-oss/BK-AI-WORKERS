param(
    [Parameter(Mandatory = $true)]
    [string]$ContextPath,

    [Parameter(Mandatory = $true)]
    [string]$Objective
)

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

Write-Host ""
Write-Host "============================================"
Write-Host " WORKER EXECUTION ENGINE"
Write-Host " PHASE 6B-1"
Write-Host "============================================"
Write-Host ""

# =================================================
# 1. CHARGEMENT DU CONTEXTE
# =================================================

if (-not (Test-Path $ContextPath)) {
    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : WORKER CONTEXT NOT FOUND"
    exit 10
}

try {
    $Context = Get-Content $ContextPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "STATUS : ERROR"
    Write-Host "REASON : INVALID WORKER CONTEXT"
    exit 11
}

# =================================================
# 2. IDENTITE
# =================================================

$ClientId = $Context.context.client_id
$ProjectId = $Context.context.project_id
$WorkerId = $Context.context.worker_id
$TaskId = $Context.context.task_id

if (
    [string]::IsNullOrWhiteSpace($ClientId) -or
    [string]::IsNullOrWhiteSpace($ProjectId) -or
    [string]::IsNullOrWhiteSpace($WorkerId) -or
    [string]::IsNullOrWhiteSpace($TaskId)
) {
    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : INCOMPLETE WORKER CONTEXT"
    exit 12
}

Write-Host "CLIENT  : $ClientId"
Write-Host "PROJECT : $ProjectId"
Write-Host "WORKER  : $WorkerId"
Write-Host "TASK    : $TaskId"
Write-Host ""

# =================================================
# 3. SECURITE
# =================================================

if ($Context.security.client_isolation -ne $true) {
    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : CLIENT ISOLATION INVALID"
    exit 13
}

if ($Context.security.project_isolation -ne $true) {
    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : PROJECT ISOLATION INVALID"
    exit 14
}

if ($Context.security.worker_isolation -ne $true) {
    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : WORKER ISOLATION INVALID"
    exit 15
}

if ($Context.security.financial_boundary -ne $true) {
    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : FINANCIAL BOUNDARY INVALID"
    exit 16
}

if ($Context.security.external_actions_blocked -ne $true) {
    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : EXTERNAL ACTIONS NOT BLOCKED"
    exit 17
}

Write-Host "SECURITY : VALID"

# =================================================
# 4. PERMISSIONS
# =================================================

if ($Context.permissions.read -ne $true) {
    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : READ PERMISSION DENIED"
    exit 18
}

if ($Context.permissions.write -ne $true) {
    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : WRITE PERMISSION DENIED"
    exit 19
}

if ($Context.permissions.financial_actions -ne $false) {
    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : FINANCIAL ACTION DETECTED"
    exit 20
}

Write-Host "PERMISSIONS : VALID"

# =================================================
# 5. OBJECTIF
# =================================================

if ([string]::IsNullOrWhiteSpace($Objective)) {
    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : OBJECTIVE EMPTY"
    exit 21
}

Write-Host ""
Write-Host "OBJECTIVE :"
Write-Host $Objective
Write-Host ""

# =================================================
# 6. EXECUTION SIMULEE
# =================================================

$Result = [ordered]@{
    execution_id = "EXEC-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff'))"
    context_id = $Context.context.context_id
    client_id = $ClientId
    project_id = $ProjectId
    worker_id = $WorkerId
    task_id = $TaskId
    objective = $Objective

    result = [ordered]@{
        status = "SUCCESS"
        summary = "Tâche exécutée avec succès en mode simulation."
        worker = $WorkerId
        action = "SIMULATED_EXECUTION"
    }

    security = [ordered]@{
        client_isolation = $true
        project_isolation = $true
        worker_isolation = $true
        financial_actions = $false
        external_actions = $false
    }

    generated_at = (Get-Date).ToUniversalTime().ToString("o")
}

# =================================================
# 7. SAUVEGARDE
# =================================================

$OutputPath = Join-Path `
    $Root `
    "memory\runtime\EXECUTION-$TaskId.json"

$Result |
    ConvertTo-Json -Depth 30 |
    Set-Content $OutputPath -Encoding UTF8

# =================================================
# 8. RESULTAT
# =================================================

Write-Host "RESULT : SUCCESS"
Write-Host "MODE   : SIMULATION"
Write-Host ""
Write-Host "OUTPUT : $OutputPath"
Write-Host ""
Write-Host "WORKER EXECUTION : READY"

exit 0