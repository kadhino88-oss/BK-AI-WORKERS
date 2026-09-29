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

$DataPath = Join-Path $Root "memory\data"
$RuntimePath = Join-Path $Root "memory\runtime"

$OutputPath = Join-Path $RuntimePath "HIERARCHICAL-$TaskId.json"

Write-Host ""
Write-Host "============================================"
Write-Host " HIERARCHICAL MEMORY LOADER"
Write-Host " PHASE 5E"
Write-Host "============================================"
Write-Host ""

# -------------------------------------------------
# FONCTION : CHARGER UNE MEMOIRE
# -------------------------------------------------

function Load-Memory {
    param(
        [string]$Path,
        [string]$Level
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    try {
        $memory = Get-Content $Path -Raw | ConvertFrom-Json

        return [ordered]@{
            level = $Level
            source = $Path
            data = $memory
        }
    }
    catch {
        Write-Host "MEMORY ERROR : $Path"
        return $null
    }
}

# -------------------------------------------------
# MEMOIRE GLOBALE
# -------------------------------------------------

$GlobalPath = Join-Path $DataPath "global"

$globalMemory = @()

if (Test-Path $GlobalPath) {

    $files = Get-ChildItem $GlobalPath -Filter "*.json" -File

    foreach ($file in $files) {

        $item = Load-Memory $file.FullName "GLOBAL"

        if ($null -ne $item) {
            $globalMemory += $item
        }
    }
}

# -------------------------------------------------
# MEMOIRE CLIENT
# -------------------------------------------------

$ClientPath = Join-Path $DataPath "clients\$ClientId"

$clientMemory = @()

if (Test-Path $ClientPath) {

    $files = Get-ChildItem $ClientPath -Filter "*.json" -File

    foreach ($file in $files) {

        $item = Load-Memory $file.FullName "CLIENT"

        if ($null -ne $item) {
            $clientMemory += $item
        }
    }
}

# -------------------------------------------------
# MEMOIRE PROJET
# -------------------------------------------------

$ProjectPath = Join-Path $DataPath "projects\$ProjectId"

$projectMemory = @()

if (Test-Path $ProjectPath) {

    $files = Get-ChildItem $ProjectPath -Filter "*.json" -File

    foreach ($file in $files) {

        $item = Load-Memory $file.FullName "PROJECT"

        if ($null -ne $item) {
            $projectMemory += $item
        }
    }
}

# -------------------------------------------------
# MEMOIRE WORKER
# -------------------------------------------------

$WorkerPath = Join-Path $DataPath "workers\$WorkerId"

$workerMemory = @()

if (Test-Path $WorkerPath) {

    $files = Get-ChildItem $WorkerPath -Filter "*.json" -File

    foreach ($file in $files) {

        $item = Load-Memory $file.FullName "WORKER"

        if ($null -ne $item) {
            $workerMemory += $item
        }
    }
}

# -------------------------------------------------
# MEMOIRE TASK
# -------------------------------------------------

$TaskPath = Join-Path $DataPath "tasks\$TaskId"

$taskMemory = @()

if (Test-Path $TaskPath) {

    $files = Get-ChildItem $TaskPath -Filter "*.json" -File

    foreach ($file in $files) {

        $item = Load-Memory $file.FullName "TASK"

        if ($null -ne $item) {
            $taskMemory += $item
        }
    }
}

# -------------------------------------------------
# MEMOIRE EXECUTION
# -------------------------------------------------

$ExecutionPath = Join-Path $DataPath "executions\$TaskId"

$executionMemory = @()

if (Test-Path $ExecutionPath) {

    $files = Get-ChildItem $ExecutionPath -Filter "*.json" -File

    foreach ($file in $files) {

        $item = Load-Memory $file.FullName "EXECUTION"

        if ($null -ne $item) {
            $executionMemory += $item
        }
    }
}

# -------------------------------------------------
# CONSTRUCTION DU CONTEXTE
# -------------------------------------------------

$hierarchicalMemory = [ordered]@{

    context = [ordered]@{
        client_id = $ClientId
        project_id = $ProjectId
        worker_id = $WorkerId
        task_id = $TaskId
    }

    hierarchy = [ordered]@{

        global = $globalMemory

        client = $clientMemory

        project = $projectMemory

        worker = $workerMemory

        task = $taskMemory

        execution = $executionMemory
    }

    generated_at = (Get-Date).ToUniversalTime().ToString("o")
}

# -------------------------------------------------
# ECRITURE
# -------------------------------------------------

$hierarchicalMemory |
    ConvertTo-Json -Depth 20 |
    Set-Content $OutputPath -Encoding UTF8

# -------------------------------------------------
# RESULTAT
# -------------------------------------------------

Write-Host "CLIENT      : $ClientId"
Write-Host "PROJECT     : $ProjectId"
Write-Host "WORKER      : $WorkerId"
Write-Host "TASK        : $TaskId"
Write-Host ""

Write-Host "GLOBAL      : $($globalMemory.Count) mémoire(s)"
Write-Host "CLIENT      : $($clientMemory.Count) mémoire(s)"
Write-Host "PROJECT     : $($projectMemory.Count) mémoire(s)"
Write-Host "WORKER      : $($workerMemory.Count) mémoire(s)"
Write-Host "TASK        : $($taskMemory.Count) mémoire(s)"
Write-Host "EXECUTION   : $($executionMemory.Count) mémoire(s)"
Write-Host ""

Write-Host "OUTPUT      : $OutputPath"
Write-Host ""
Write-Host "HIERARCHICAL MEMORY : LOADED"
Write-Host "STATUS : READY"

exit 0