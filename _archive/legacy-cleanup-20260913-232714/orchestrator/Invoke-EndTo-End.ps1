param(
    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$ProjectId,

    [Parameter(Mandatory = $true)]
    [string]$WorkerId,

    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [Parameter(Mandatory = $true)]
    [string]$Objective
)

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$ContextBridge = Join-Path `
    $Root `
    "orchestrator\context\Invoke-Context-Bridge.ps1"

$WorkerExecution = Join-Path `
    $Root `
    "orchestrator\Worker-Execution.ps1"

$WorkerResult = Join-Path `
    $Root `
    "orchestrator\Worker-Result.ps1"

$BridgePath = Join-Path `
    $Root `
    "memory\runtime\BRIDGE-$TaskId.json"

$FinalResultPath = Join-Path `
    $Root `
    "memory\runtime\RESULT-$TaskId.json"

Write-Host ""
Write-Host "============================================"
Write-Host " ORCHESTRATOR END-TO-END ENGINE"
Write-Host " PHASE 6C"
Write-Host "============================================"
Write-Host ""

# =================================================
# 1. IDENTIFICATION DE LA TACHE
# =================================================

Write-Host "TASK REQUEST"
Write-Host "------------"
Write-Host "CLIENT  : $ClientId"
Write-Host "PROJECT : $ProjectId"
Write-Host "WORKER  : $WorkerId"
Write-Host "TASK    : $TaskId"
Write-Host ""
Write-Host "OBJECTIVE :"
Write-Host $Objective
Write-Host ""

# =================================================
# 2. CONTEXT BRIDGE
# =================================================

Write-Host "STEP 1/4 : CONTEXT BRIDGE"

& $ContextBridge `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -WorkerId $WorkerId `
    -TaskId $TaskId

if ($LASTEXITCODE -ne 0) {

    Write-Host ""
    Write-Host "END-TO-END : BLOCKED"
    Write-Host "REASON : CONTEXT BRIDGE FAILURE"

    exit 20
}

if (-not (Test-Path $BridgePath)) {

    Write-Host ""
    Write-Host "END-TO-END : ERROR"
    Write-Host "REASON : BRIDGE OUTPUT NOT FOUND"

    exit 21
}

Write-Host "STEP 1/4 : SUCCESS"
Write-Host ""

# =================================================
# 3. EXECUTION WORKER
# =================================================

Write-Host "STEP 2/4 : WORKER EXECUTION"

& $WorkerExecution `
    -ContextPath $BridgePath `
    -Objective $Objective

if ($LASTEXITCODE -ne 0) {

    Write-Host ""
    Write-Host "END-TO-END : BLOCKED"
    Write-Host "REASON : WORKER EXECUTION FAILURE"

    exit 22
}

Write-Host "STEP 2/4 : SUCCESS"
Write-Host ""

# =================================================
# 4. RETOUR WORKER
# =================================================

Write-Host "STEP 3/4 : WORKER RESULT"

& $WorkerResult `
    -TaskId $TaskId

if ($LASTEXITCODE -ne 0) {

    Write-Host ""
    Write-Host "END-TO-END : BLOCKED"
    Write-Host "REASON : WORKER RESULT FAILURE"

    exit 23
}

Write-Host "STEP 3/4 : SUCCESS"
Write-Host ""

# =================================================
# 5. VERIFICATION RESULTAT FINAL
# =================================================

Write-Host "STEP 4/4 : FINAL VALIDATION"

if (-not (Test-Path $FinalResultPath)) {

    Write-Host "STATUS : ERROR"
    Write-Host "REASON : FINAL RESULT NOT FOUND"

    exit 24
}

try {

    $FinalResult =
        Get-Content $FinalResultPath -Raw |
        ConvertFrom-Json
}
catch {

    Write-Host "STATUS : ERROR"
    Write-Host "REASON : INVALID FINAL RESULT"

    exit 25
}

if ($FinalResult.result.status -ne "SUCCESS") {

    Write-Host "STATUS : BLOCKED"
    Write-Host "REASON : WORKER RESULT NOT SUCCESS"

    exit 26
}

if ($FinalResult.orchestrator.received -ne $true) {

    Write-Host "STATUS : ERROR"
    Write-Host "REASON : ORCHESTRATOR DID NOT RECEIVE RESULT"

    exit 27
}

if ($FinalResult.orchestrator.validated -ne $true) {

    Write-Host "STATUS : ERROR"
    Write-Host "REASON : RESULT NOT VALIDATED"

    exit 28
}

if ($FinalResult.orchestrator.task_closed -ne $true) {

    Write-Host "STATUS : ERROR"
    Write-Host "REASON : TASK NOT CLOSED"

    exit 29
}

Write-Host "FINAL RESULT : VALID"
Write-Host ""

# =================================================
# 6. RAPPORT FINAL
# =================================================

Write-Host "============================================"
Write-Host " END-TO-END SUCCESS"
Write-Host "============================================"
Write-Host ""

Write-Host "CLIENT      : $ClientId"
Write-Host "PROJECT     : $ProjectId"
Write-Host "WORKER      : $WorkerId"
Write-Host "TASK        : $TaskId"
Write-Host ""

Write-Host "CONTEXT     : VALID"
Write-Host "MEMORY      : LOADED"
Write-Host "SECURITY    : VALID"
Write-Host "EXECUTION   : SUCCESS"
Write-Host "RESULT      : RECEIVED"
Write-Host "VALIDATION  : SUCCESS"
Write-Host "TASK        : CLOSED"
Write-Host ""

Write-Host "FINAL FILE : $FinalResultPath"
Write-Host ""

Write-Host "ORCHESTRATOR END-TO-END : SUCCESS"
Write-Host "PHASE 6C : READY"

exit 0