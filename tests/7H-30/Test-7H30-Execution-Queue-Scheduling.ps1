$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Dir = Join-Path $Root "core\runtime\execution-queue"
$QueueDir = Join-Path $Dir "queue"

$ConfigPath = Join-Path `
    $Dir `
    "EXECUTION-QUEUE-CONFIG.json"

$Validator = Join-Path `
    $Dir `
    "Validate-Execution-Queue.ps1"

$Runtime = Join-Path `
    $Dir `
    "EXECUTION-QUEUE-RUNTIME.ps1"

# Nettoyage test
if (Test-Path -LiteralPath $QueueDir) {
    Get-ChildItem `
        -LiteralPath $QueueDir `
        -Filter "*.json" `
        -File `
        -ErrorAction SilentlyContinue |
        Remove-Item -Force
}

$Pass = 0
$Fail = 0

function Pass-Test($message) {
    $script:Pass++
    Write-Host "PASS : $message" -ForegroundColor Green
}

function Fail-Test($message) {
    $script:Fail++
    Write-Host "FAIL : $message" -ForegroundColor Red
}

Write-Host ""
Write-Host "============================================="
Write-Host "7H-30 - EXECUTION QUEUE & SCHEDULING"
Write-Host "============================================="
Write-Host ""

# ============================================================
# TEST 1
# ============================================================

try {
    & $Validator $ConfigPath | Out-Host

    if ($LASTEXITCODE -eq 0) {
        Pass-Test "Execution Queue Config valide"
    }
    else {
        Fail-Test "Execution Queue Config invalide"
    }
}
catch {
    Fail-Test "validation Execution Queue"
}

. $Runtime

# ============================================================
# BASE 1
# ============================================================

$base1 = @{
    ConfigPath = $ConfigPath
    QueueDirectory = $QueueDir

    ExecutionId = "EXEC-7H30-001"
    CorrelationId = "CORR-7H30-001"

    TenantId = "TENANT-001"
    ClientId = "CLIENT-001"
    ProjectId = "PROJECT-001"

    WorkerId = "MAYA"
    SkillId = "SKILL-001"
    TaskId = "TASK-001"

    ConnectorId = "crm.controlled"
    Operation = "CREATE_TASK"

    IdempotencyKey = "IDEMP-7H30-001"

    Priority = 50
    Mode = "SIMULATION"
}

# ============================================================
# TEST 2
# Queue item
# ============================================================

$item1 = New-ExecutionQueueItem @base1

if (
    $item1.status -eq "QUEUED" -and
    (Test-Path -LiteralPath $item1.filePath)
) {
    Pass-Test "exécution correctement placée en queue"
}
else {
    Fail-Test "mise en queue incorrecte"
}

# ============================================================
# TEST 3
# Priority selection
# ============================================================

$base2 = $base1.Clone()

$base2.ExecutionId = "EXEC-7H30-002"
$base2.CorrelationId = "CORR-7H30-002"
$base2.TaskId = "TASK-002"
$base2.IdempotencyKey = "IDEMP-7H30-002"
$base2.Priority = 90

$item2 = New-ExecutionQueueItem @base2

$selected = Select-NextExecution `
    -ConfigPath $ConfigPath `
    -QueueDirectory $QueueDir `
    -CurrentRunningCount 0

if (
    $selected.status -eq "SELECTED" -and
    $selected.executionId -eq "EXEC-7H30-002"
) {
    Pass-Test "scheduler sélectionne la priorité la plus élevée"
}
else {
    Fail-Test "priorité scheduler incorrecte"
}

# ============================================================
# TEST 4
# FIFO à priorité identique
# ============================================================

$FifoQueueDir = Join-Path `
    $Dir `
    "queue-fifo-test"

if (Test-Path -LiteralPath $FifoQueueDir) {
    Get-ChildItem `
        -LiteralPath $FifoQueueDir `
        -Filter "*.json" `
        -File `
        -ErrorAction SilentlyContinue |
        Remove-Item -Force
}
else {
    New-Item `
        -ItemType Directory `
        -Force `
        -Path $FifoQueueDir | Out-Null
}

$FifoBase1 = $base1.Clone()

$FifoBase1.QueueDirectory = $FifoQueueDir
$FifoBase1.ExecutionId = "EXEC-7H30-FIFO-001"
$FifoBase1.CorrelationId = "CORR-7H30-FIFO-001"
$FifoBase1.TaskId = "TASK-FIFO-001"
$FifoBase1.IdempotencyKey = "IDEMP-7H30-FIFO-001"
$FifoBase1.Priority = 50

$FifoItem1 = New-ExecutionQueueItem @FifoBase1

$FifoBase2 = $base1.Clone()

$FifoBase2.QueueDirectory = $FifoQueueDir
$FifoBase2.ExecutionId = "EXEC-7H30-FIFO-002"
$FifoBase2.CorrelationId = "CORR-7H30-FIFO-002"
$FifoBase2.TaskId = "TASK-FIFO-002"
$FifoBase2.IdempotencyKey = "IDEMP-7H30-FIFO-002"
$FifoBase2.Priority = 50

$FifoItem2 = New-ExecutionQueueItem @FifoBase2

$selected2 = Select-NextExecution `
    -ConfigPath $ConfigPath `
    -QueueDirectory $FifoQueueDir `
    -CurrentRunningCount 0

if (
    $FifoItem1.status -eq "QUEUED" -and
    $FifoItem2.status -eq "QUEUED" -and
    $selected2.status -eq "SELECTED" -and
    $selected2.priority -eq 50 -and
    $selected2.executionId -eq "EXEC-7H30-FIFO-001"
) {
    Pass-Test "FIFO respecté entre tâches de priorité identique"
}
else {
    Fail-Test "FIFO scheduler incorrect"
}

# Nettoyage queue dédiée FIFO
if (Test-Path -LiteralPath $FifoQueueDir) {
    Get-ChildItem `
        -LiteralPath $FifoQueueDir `
        -Filter "*.json" `
        -File `
        -ErrorAction SilentlyContinue |
        Remove-Item -Force
}
# TEST 5
# Duplicate execution ID
# ============================================================

$duplicateExecution = $base1.Clone()

$duplicateExecution.CorrelationId = "CORR-7H30-DUP"
$duplicateExecution.TaskId = "TASK-DUP"
$duplicateExecution.IdempotencyKey = "IDEMP-7H30-DUP"

$result = New-ExecutionQueueItem @duplicateExecution

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "DUPLICATE_EXECUTION_ID"
) {
    Pass-Test "executionId dupliqué bloqué"
}
else {
    Fail-Test "executionId dupliqué non bloqué"
}

# ============================================================
# TEST 6
# Duplicate idempotency key
# ============================================================

$duplicateKey = $base1.Clone()

$duplicateKey.ExecutionId = "EXEC-7H30-004"
$duplicateKey.CorrelationId = "CORR-7H30-004"
$duplicateKey.TaskId = "TASK-004"

$result = New-ExecutionQueueItem @duplicateKey

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "DUPLICATE_IDEMPOTENCY_KEY"
) {
    Pass-Test "idempotencyKey dupliquée bloquée"
}
else {
    Fail-Test "idempotencyKey dupliquée non bloquée"
}

# ============================================================
# TEST 7
# Transition QUEUED → RUNNING
# ============================================================

$running = Set-ExecutionQueueStatus `
    -QueueDirectory $QueueDir `
    -QueueId $item1.queueId `
    -Status "RUNNING"

if (
    $running.status -eq "UPDATED" -and
    $running.currentStatus -eq "RUNNING"
) {
    Pass-Test "transition QUEUED → RUNNING autorisée"
}
else {
    Fail-Test "transition QUEUED → RUNNING incorrecte"
}

# ============================================================
# TEST 8
# Transition RUNNING → COMPLETED
# ============================================================

$completed = Set-ExecutionQueueStatus `
    -QueueDirectory $QueueDir `
    -QueueId $item1.queueId `
    -Status "COMPLETED"

if (
    $completed.status -eq "UPDATED" -and
    $completed.currentStatus -eq "COMPLETED"
) {
    Pass-Test "transition RUNNING → COMPLETED autorisée"
}
else {
    Fail-Test "transition RUNNING → COMPLETED incorrecte"
}

# ============================================================
# TEST 9
# Transition terminale interdite
# ============================================================

$invalid = Set-ExecutionQueueStatus `
    -QueueDirectory $QueueDir `
    -QueueId $item1.queueId `
    -Status "RUNNING"

if (
    $invalid.status -eq "BLOCKED" -and
    $invalid.reason -eq "INVALID_QUEUE_TRANSITION"
) {
    Pass-Test "retour COMPLETED → RUNNING bloqué"
}
else {
    Fail-Test "transition terminale contournable"
}

# ============================================================
# TEST 10
# Concurrent limit
# ============================================================

$selectedBlocked = Select-NextExecution `
    -ConfigPath $ConfigPath `
    -QueueDirectory $QueueDir `
    -CurrentRunningCount 10

if (
    $selectedBlocked.status -eq "WAIT" -and
    $selectedBlocked.reason -eq "CONCURRENCY_LIMIT_REACHED"
) {
    Pass-Test "limite de concurrence respectée"
}
else {
    Fail-Test "limite de concurrence non respectée"
}

# ============================================================
# TEST 11
# Cancel queued
# ============================================================

$cancelCandidate = $base1.Clone()

$cancelCandidate.ExecutionId = "EXEC-7H30-005"
$cancelCandidate.CorrelationId = "CORR-7H30-005"
$cancelCandidate.TaskId = "TASK-005"
$cancelCandidate.IdempotencyKey = "IDEMP-7H30-005"
$cancelCandidate.Priority = 30

$cancelItem = New-ExecutionQueueItem @cancelCandidate

$cancel = Cancel-ExecutionQueueItem `
    -QueueDirectory $QueueDir `
    -QueueId $cancelItem.queueId

if (
    $cancel.status -eq "CANCELLED"
) {
    Pass-Test "exécution QUEUED annulée correctement"
}
else {
    Fail-Test "annulation QUEUED incorrecte"
}

# ============================================================
# TEST 12
# Cancel running blocked
# ============================================================

$runningCandidate = $base1.Clone()

$runningCandidate.ExecutionId = "EXEC-7H30-006"
$runningCandidate.CorrelationId = "CORR-7H30-006"
$runningCandidate.TaskId = "TASK-006"
$runningCandidate.IdempotencyKey = "IDEMP-7H30-006"
$runningCandidate.Priority = 20

$runningItem = New-ExecutionQueueItem @runningCandidate

Set-ExecutionQueueStatus `
    -QueueDirectory $QueueDir `
    -QueueId $runningItem.queueId `
    -Status "RUNNING" | Out-Null

$cancelRunning = Cancel-ExecutionQueueItem `
    -QueueDirectory $QueueDir `
    -QueueId $runningItem.queueId

if (
    $cancelRunning.status -eq "BLOCKED" -and
    $cancelRunning.reason -eq "CANCEL_ONLY_QUEUED"
) {
    Pass-Test "annulation d'une exécution RUNNING bloquée"
}
else {
    Fail-Test "annulation RUNNING non protégée"
}

# ============================================================
# TEST 13
# Client isolation
# ============================================================

$client2 = $base1.Clone()

$client2.ExecutionId = "EXEC-7H30-007"
$client2.CorrelationId = "CORR-7H30-007"
$client2.TaskId = "TASK-007"
$client2.IdempotencyKey = "IDEMP-7H30-007"
$client2.ClientId = "CLIENT-002"
$client2.Priority = 10

$clientItem = New-ExecutionQueueItem @client2

if (
    $clientItem.status -eq "QUEUED"
) {
    Pass-Test "client différent isolé"
}
else {
    Fail-Test "isolation client incorrecte"
}

# ============================================================
# TEST 14
# No secrets
# ============================================================

$queueFiles = @(
    Get-ChildItem `
        -LiteralPath $QueueDir `
        -Filter "*.json" `
        -File
)

$secretFound = $false

foreach ($file in $queueFiles) {

    $content = Get-Content `
        -LiteralPath $file.FullName `
        -Raw `
        -Encoding UTF8

    if (
        $content -match '(?i)"api.?key"\s*:' -or
        $content -match '(?i)"access.?token"\s*:' -or
        $content -match '(?i)"password"\s*:' -or
        $content -match '(?i)"client.?secret"\s*:' -or
        $content -match '(?i)"private.?key"\s*:'
    ) {
        $secretFound = $true
    }
}

if (-not $secretFound) {
    Pass-Test "queue sans secret"
}
else {
    Fail-Test "secret détecté dans la queue"
}

# ============================================================
# TEST 15
# Context incomplete
# ============================================================

$bad = $base1.Clone()

$bad.ExecutionId = "EXEC-7H30-008"
$bad.CorrelationId = "CORR-7H30-008"
$bad.TaskId = "TASK-008"
$bad.IdempotencyKey = "IDEMP-7H30-008"
$bad.ProjectId = ""

$result = New-ExecutionQueueItem @bad

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "CONTEXT_INCOMPLETE" -and
    $result.field -eq "ProjectId"
) {
    Pass-Test "contexte incomplet bloqué"
}
else {
    Fail-Test "contexte incomplet non bloqué"
}

# ============================================================
# TEST 16
# Priority bounds
# ============================================================

$badPriority = $base1.Clone()

$badPriority.ExecutionId = "EXEC-7H30-009"
$badPriority.CorrelationId = "CORR-7H30-009"
$badPriority.TaskId = "TASK-009"
$badPriority.IdempotencyKey = "IDEMP-7H30-009"
$badPriority.Priority = 999

$result = New-ExecutionQueueItem @badPriority

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "PRIORITY_TOO_HIGH"
) {
    Pass-Test "priorité hors limites bloquée"
}
else {
    Fail-Test "priorité hors limites non bloquée"
}

# ============================================================
# CLEANUP
# ============================================================

if (Test-Path -LiteralPath $QueueDir) {
    Get-ChildItem `
        -LiteralPath $QueueDir `
        -Filter "*.json" `
        -File `
        -ErrorAction SilentlyContinue |
        Remove-Item -Force
}

Write-Host ""
Write-Host "RESULTATS 7H-30"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"
Write-Host ""

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Execution Queue & Scheduling Manager opérationnel."
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1