param(
    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$ProjectId,

    [Parameter(Mandatory = $true)]
    [string]$WorkerId,

    [Parameter(Mandatory = $true)]
    [string]$TaskId
)

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$RuntimePath = Join-Path $Root "memory\runtime"

$ActiveContextPath =
    Join-Path $RuntimePath "ACTIVE-$TaskId.json"

$HierarchicalMemoryPath =
    Join-Path $RuntimePath "HIERARCHICAL-$TaskId.json"

$OutputPath =
    Join-Path $RuntimePath "BRIDGE-$TaskId.json"

Write-Host ""
Write-Host "============================================"
Write-Host " ORCHESTRATOR CONTEXT BRIDGE"
Write-Host " PHASE 6A"
Write-Host "============================================"
Write-Host ""

# =================================================
# 1. CONTEXTE ACTIF
# =================================================

if (-not (Test-Path $ActiveContextPath)) {

    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : ACTIVE CONTEXT NOT FOUND"

    exit 10
}

try {

    $activeContext =
        Get-Content $ActiveContextPath -Raw |
        ConvertFrom-Json
}
catch {

    Write-Host "STATUS : ERROR"
    Write-Host "REASON : INVALID ACTIVE CONTEXT"

    exit 11
}

# =================================================
# 2. VERIFICATION IDENTITE
# =================================================

if (
    $activeContext.client.id -ne $ClientId -or
    $activeContext.project.id -ne $ProjectId -or
    $activeContext.worker.id -ne $WorkerId -or
    $activeContext.task.id -ne $TaskId
) {

    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : CONTEXT IDENTITY MISMATCH"

    exit 12
}

Write-Host "IDENTITY : VALID"

# =================================================
# 3. MEMOIRE HIERARCHIQUE
# =================================================

if (-not (Test-Path $HierarchicalMemoryPath)) {

    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : HIERARCHICAL MEMORY NOT FOUND"

    exit 13
}

try {

    $memory =
        Get-Content $HierarchicalMemoryPath -Raw |
        ConvertFrom-Json
}
catch {

    Write-Host "STATUS : ERROR"
    Write-Host "REASON : INVALID HIERARCHICAL MEMORY"

    exit 14
}

Write-Host "MEMORY : LOADED"

# =================================================
# 4. VERIFICATION ISOLATION
# =================================================

if ($memory.context.client_id -ne $ClientId) {

    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : CLIENT ISOLATION FAILURE"

    exit 15
}

if ($memory.context.project_id -ne $ProjectId) {

    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : PROJECT ISOLATION FAILURE"

    exit 16
}

if ($memory.context.worker_id -ne $WorkerId) {

    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : WORKER ISOLATION FAILURE"

    exit 17
}

Write-Host "ISOLATION : VALID"

# =================================================
# 5. VERIFICATION PERMISSIONS
# =================================================

if ($activeContext.permissions.read -ne $true) {

    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : READ PERMISSION DENIED"

    exit 18
}

if ($activeContext.permissions.write -ne $true) {

    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : WRITE PERMISSION DENIED"

    exit 19
}

# =================================================
# 6. FRONTIERE FINANCIERE
# =================================================

$financialActions =
    $activeContext.permissions.financial_actions

if ($financialActions -ne $false) {

    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : FINANCIAL BOUNDARY VIOLATION"

    exit 20
}

Write-Host "FINANCIAL BOUNDARY : SECURE"

# =================================================
# 7. ACTIONS EXTERNES
# =================================================

$externalActions =
    $activeContext.permissions.external_actions

if ($externalActions -ne $false) {

    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : EXTERNAL ACTIONS NOT ALLOWED IN PHASE 6A"

    exit 21
}

Write-Host "EXTERNAL ACTIONS : BLOCKED"

# =================================================
# 8. CONSTRUCTION DU CONTEXTE WORKER
# =================================================

$workerContext = [ordered]@{

    context = [ordered]@{
        context_id = $activeContext.context_id
        client_id = $ClientId
        project_id = $ProjectId
        worker_id = $WorkerId
        task_id = $TaskId
    }

    client = [ordered]@{
        id = $ClientId
    }

    project = [ordered]@{
        id = $ProjectId
    }

    worker = [ordered]@{
        id = $WorkerId
    }

    task = [ordered]@{
        id = $TaskId
        objective = $activeContext.task.objective
    }

    permissions = [ordered]@{
        read = $activeContext.permissions.read
        write = $activeContext.permissions.write
        external_actions = $externalActions
        financial_actions = $financialActions
    }

    memory = $memory.hierarchy

    security = [ordered]@{
        client_isolation = $true
        project_isolation = $true
        worker_isolation = $true
        financial_boundary = $true
        external_actions_blocked = $true
    }

    status = "SUCCESS"

    generated_at =
        (Get-Date).ToUniversalTime().ToString("o")
}

# =================================================
# 9. ECRITURE
# =================================================

$workerContext |
    ConvertTo-Json -Depth 30 |
    Set-Content $OutputPath -Encoding UTF8

# =================================================
# 10. RESULTAT
# =================================================

Write-Host ""
Write-Host "CLIENT      : $ClientId"
Write-Host "PROJECT     : $ProjectId"
Write-Host "WORKER      : $WorkerId"
Write-Host "TASK        : $TaskId"
Write-Host ""

Write-Host "CONTEXT     : VALID"
Write-Host "MEMORY      : VALID"
Write-Host "ISOLATION   : VALID"
Write-Host "PERMISSIONS : VALID"
Write-Host "SECURITY    : VALID"
Write-Host ""

Write-Host "OUTPUT : $OutputPath"
Write-Host ""
Write-Host "BRIDGE : SUCCESS"
Write-Host "STATUS : READY"

exit 0