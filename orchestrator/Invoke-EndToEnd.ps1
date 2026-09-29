param(
    [Parameter(Mandatory=$true)]
    [string]$ContextPath,

    [Parameter(Mandatory=$true)]
    [string]$Objective
)

$ErrorActionPreference = "Continue"

# ============================================================
# BK AI WORKERS
# END-TO-END ORCHESTRATOR
# PHASE 6C / 6D
# ============================================================

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$WorkerExecution = Join-Path $Root "orchestrator\Worker-Execution.ps1"
$WorkerResult    = Join-Path $Root "orchestrator\Worker-Result.ps1"
$RuntimePath     = Join-Path $Root "memory\runtime"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " END-TO-END EXECUTION ENGINE"
Write-Host "============================================"
Write-Host ""

# ============================================================
# 1. INPUT VALIDATION
# ============================================================

if (-not (Test-Path $ContextPath)) {

    Write-Host "STATUS : ERROR"
    Write-Host "REASON : CONTEXT PATH NOT FOUND"
    Write-Host "PATH   : $ContextPath"

    exit 50
}

if ([string]::IsNullOrWhiteSpace($Objective)) {

    Write-Host "STATUS : ERROR"
    Write-Host "REASON : OBJECTIVE EMPTY"

    exit 51
}

# ============================================================
# 2. LOAD BRIDGE JSON
# ============================================================

try {

    $Bridge = Get-Content `
        -Path $ContextPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json

}
catch {

    Write-Host "STATUS : ERROR"
    Write-Host "REASON : INVALID BRIDGE JSON"

    exit 52
}

# ============================================================
# 3. EXTRACT IDENTITY
# ============================================================

# Le Bridge peut contenir l'identité directement
# ou dans un objet "context".
# On accepte les deux formats.

$ClientId = $null
$ProjectId = $null
$WorkerId = $null
$TaskId = $null

# Format direct
if ($null -ne $Bridge.client_id) {
    $ClientId = [string]$Bridge.client_id
}

if ($null -ne $Bridge.project_id) {
    $ProjectId = [string]$Bridge.project_id
}

if ($null -ne $Bridge.worker_id) {
    $WorkerId = [string]$Bridge.worker_id
}

if ($null -ne $Bridge.task_id) {
    $TaskId = [string]$Bridge.task_id
}

# Format imbriqué : context
if ($null -ne $Bridge.context) {

    if ([string]::IsNullOrWhiteSpace($ClientId) -and
        $null -ne $Bridge.context.client_id) {
        $ClientId = [string]$Bridge.context.client_id
    }

    if ([string]::IsNullOrWhiteSpace($ProjectId) -and
        $null -ne $Bridge.context.project_id) {
        $ProjectId = [string]$Bridge.context.project_id
    }

    if ([string]::IsNullOrWhiteSpace($WorkerId) -and
        $null -ne $Bridge.context.worker_id) {
        $WorkerId = [string]$Bridge.context.worker_id
    }

    if ([string]::IsNullOrWhiteSpace($TaskId) -and
        $null -ne $Bridge.context.task_id) {
        $TaskId = [string]$Bridge.context.task_id
    }
}

# Format imbriqué : identity
if ($null -ne $Bridge.identity) {

    if ([string]::IsNullOrWhiteSpace($ClientId) -and
        $null -ne $Bridge.identity.client_id) {
        $ClientId = [string]$Bridge.identity.client_id
    }

    if ([string]::IsNullOrWhiteSpace($ProjectId) -and
        $null -ne $Bridge.identity.project_id) {
        $ProjectId = [string]$Bridge.identity.project_id
    }

    if ([string]::IsNullOrWhiteSpace($WorkerId) -and
        $null -ne $Bridge.identity.worker_id) {
        $WorkerId = [string]$Bridge.identity.worker_id
    }

    if ([string]::IsNullOrWhiteSpace($TaskId) -and
        $null -ne $Bridge.identity.task_id) {
        $TaskId = [string]$Bridge.identity.task_id
    }
}

# ============================================================
# 4. FALLBACK : READ ACTIVE CONTEXT
# ============================================================

# Si le Bridge ne contient pas les IDs, on récupère
# le dernier ACTIVE context correspondant au TaskId présent
# dans le nom du fichier.

if (
    [string]::IsNullOrWhiteSpace($TaskId)
) {

    $TaskMatch = [regex]::Match(
        [System.IO.Path]::GetFileNameWithoutExtension($ContextPath),
        "TASK-\d{8}-\d{6}-\d{3}"
    )

    if ($TaskMatch.Success) {
        $TaskId = $TaskMatch.Value
    }
}

if (
    -not [string]::IsNullOrWhiteSpace($TaskId) -and
    (
        [string]::IsNullOrWhiteSpace($ClientId) -or
        [string]::IsNullOrWhiteSpace($ProjectId) -or
        [string]::IsNullOrWhiteSpace($WorkerId)
    )
) {

    $ActiveFile = Get-ChildItem `
        -Path $RuntimePath `
        -Filter "ACTIVE-*.json" `
        -File `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -like "*$TaskId*"
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -ne $ActiveFile) {

        try {

            $ActiveContext = Get-Content `
                -Path $ActiveFile.FullName `
                -Raw `
                -Encoding UTF8 |
                ConvertFrom-Json

            if ([string]::IsNullOrWhiteSpace($ClientId)) {
                if ($null -ne $ActiveContext.client_id) {
                    $ClientId = [string]$ActiveContext.client_id
                }
            }

            if ([string]::IsNullOrWhiteSpace($ProjectId)) {
                if ($null -ne $ActiveContext.project_id) {
                    $ProjectId = [string]$ActiveContext.project_id
                }
            }

            if ([string]::IsNullOrWhiteSpace($WorkerId)) {
                if ($null -ne $ActiveContext.worker_id) {
                    $WorkerId = [string]$ActiveContext.worker_id
                }
            }

            if ([string]::IsNullOrWhiteSpace($TaskId)) {
                if ($null -ne $ActiveContext.task_id) {
                    $TaskId = [string]$ActiveContext.task_id
                }
            }

        }
        catch {
            # On continue vers la validation finale.
        }
    }
}

# ============================================================
# 5. FINAL IDENTITY VALIDATION
# ============================================================

if ([string]::IsNullOrWhiteSpace($ClientId)) {

    Write-Host "STATUS : ERROR"
    Write-Host "REASON : CLIENT ID MISSING"

    exit 53
}

if ([string]::IsNullOrWhiteSpace($ProjectId)) {

    Write-Host "STATUS : ERROR"
    Write-Host "REASON : PROJECT ID MISSING"

    exit 54
}

if ([string]::IsNullOrWhiteSpace($WorkerId)) {

    Write-Host "STATUS : ERROR"
    Write-Host "REASON : WORKER ID MISSING"

    exit 55
}

if ([string]::IsNullOrWhiteSpace($TaskId)) {

    Write-Host "STATUS : ERROR"
    Write-Host "REASON : TASK ID MISSING"

    exit 56
}

Write-Host "CLIENT  : $ClientId"
Write-Host "PROJECT : $ProjectId"
Write-Host "WORKER  : $WorkerId"
Write-Host "TASK    : $TaskId"
Write-Host ""

# ============================================================
# 6. SECURITY
# ============================================================

Write-Host "SECURITY : VALIDATING"
Write-Host ""

# Finance remains blocked.
$FinancialActions = $false

if ($null -ne $Bridge.permissions) {

    if ($Bridge.permissions.financial_actions -eq $true) {
        $FinancialActions = $true
    }
}

if ($FinancialActions) {

    Write-Host "STATUS : NEEDS_HUMAN"
    Write-Host "REASON : FINANCIAL ACTION DETECTED"
    Write-Host "AUTHORIZATION : KADER"

    exit 20
}

# External actions remain blocked during simulation.
$ExternalActions = $false

if ($null -ne $Bridge.permissions) {

    if ($Bridge.permissions.external_actions -eq $true) {
        $ExternalActions = $true
    }
}

if ($ExternalActions) {

    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : EXTERNAL ACTIONS NOT AUTHORIZED"

    exit 21
}

Write-Host "FINANCIAL ACTIONS : BLOCKED"
Write-Host "EXTERNAL ACTIONS  : BLOCKED"
Write-Host "SECURITY          : VALID"
Write-Host ""

# ============================================================
# 7. CHECK ENGINES
# ============================================================

if (-not (Test-Path $WorkerExecution)) {

    Write-Host "STATUS : ERROR"
    Write-Host "REASON : Worker-Execution.ps1 NOT FOUND"

    exit 58
}

if (-not (Test-Path $WorkerResult)) {

    Write-Host "STATUS : ERROR"
    Write-Host "REASON : Worker-Result.ps1 NOT FOUND"

    exit 59
}

if (-not (Test-Path $RuntimePath)) {

    New-Item `
        -ItemType Directory `
        -Path $RuntimePath `
        -Force |
        Out-Null
}

# ============================================================
# 8. WORKER EXECUTION
# ============================================================

Write-Host "============================================"
Write-Host " WORKER EXECUTION"
Write-Host "============================================"
Write-Host ""

& $WorkerExecution `
    -ContextPath $ContextPath `
    -Objective $Objective

# Worker-Execution peut utiliser le TaskId fourni
# par le Bridge. On cherche ensuite le fichier réellement créé.

$ExecutionFile = Get-ChildItem `
    -Path $RuntimePath `
    -Filter "EXECUTION-*.json" `
    -File `
    -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -like "*$TaskId*"
    } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if ($null -eq $ExecutionFile) {

    Write-Host ""
    Write-Host "STATUS : ERROR"
    Write-Host "REASON : EXECUTION FILE NOT CREATED"

    exit 60
}

$ExecutionPath = $ExecutionFile.FullName

Write-Host ""
Write-Host "EXECUTION : CREATED"
Write-Host "FILE      : $ExecutionPath"
Write-Host ""

# ============================================================
# 9. WORKER RESULT
# ============================================================

Write-Host "============================================"
Write-Host " WORKER RESULT"
Write-Host "============================================"
Write-Host ""

& $WorkerResult `
    -ExecutionPath $ExecutionPath

$ResultFileObject = Get-ChildItem `
    -Path $RuntimePath `
    -Filter "RESULT-*.json" `
    -File `
    -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -like "*$TaskId*"
    } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if ($null -eq $ResultFileObject) {

    Write-Host ""
    Write-Host "STATUS : ERROR"
    Write-Host "REASON : RESULT FILE NOT CREATED"

    exit 61
}

$ResultFile = $ResultFileObject.FullName

# ============================================================
# 10. READ RESULT
# ============================================================

try {

    $FinalResult = Get-Content `
        -Path $ResultFile `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json

}
catch {

    Write-Host "STATUS : ERROR"
    Write-Host "REASON : INVALID RESULT JSON"

    exit 62
}

Write-Host ""
Write-Host "============================================"
Write-Host " END-TO-END RESULT"
Write-Host "============================================"
Write-Host ""

Write-Host "CLIENT  : $ClientId"
Write-Host "PROJECT : $ProjectId"
Write-Host "WORKER  : $WorkerId"
Write-Host "TASK    : $TaskId"
Write-Host "STATUS  : $($FinalResult.status)"
Write-Host ""

switch ($FinalResult.status) {

    "SUCCESS" {

        Write-Host "TASK : CLOSED"
        Write-Host "ORCHESTRATOR : SUCCESS"
    }

    "PARTIAL_SUCCESS" {

        Write-Host "TASK : PARTIAL"
        Write-Host "ORCHESTRATOR : PARTIAL_SUCCESS"
    }

    "NEEDS_HUMAN" {

        Write-Host "TASK : HUMAN INTERVENTION REQUIRED"
        Write-Host "AUTHORIZATION : KADER"
        Write-Host "ORCHESTRATOR : NEEDS_HUMAN"
    }

    "BLOCKED" {

        Write-Host "TASK : BLOCKED"
        Write-Host "ORCHESTRATOR : BLOCKED"
    }

    default {

        Write-Host "TASK : $($FinalResult.status)"
    }
}

Write-Host ""
Write-Host "RESULT FILE : $ResultFile"
Write-Host ""

Write-Host "============================================"
Write-Host " END-TO-END COMPLETE"
Write-Host "============================================"
Write-Host ""

exit 0