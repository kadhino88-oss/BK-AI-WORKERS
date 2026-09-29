$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Dir = Join-Path $Root "core\runtime\execution-events"
$EventDir = Join-Path $Dir "events"

$ConfigPath = Join-Path `
    $Dir `
    "EXECUTION-EVENT-CONFIG.json"

$Validator = Join-Path `
    $Dir `
    "Validate-Execution-Event.ps1"

$Runtime = Join-Path `
    $Dir `
    "EXECUTION-EVENT-RUNTIME.ps1"

$EventPath = Join-Path `
    $EventDir `
    "EXECUTION-EVENT-LEDGER-7H27.jsonl"

if (Test-Path -LiteralPath $EventPath) {
    Remove-Item -LiteralPath $EventPath -Force
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
Write-Host "7H-27 - EXECUTION EVENT BUS & LIFECYCLE"
Write-Host "============================================="
Write-Host ""

# ============================================================
# TEST 1
# ============================================================

try {
    & $Validator $ConfigPath | Out-Host

    if ($LASTEXITCODE -eq 0) {
        Pass-Test "Execution Event Config valide"
    }
    else {
        Fail-Test "Execution Event Config invalide"
    }
}
catch {
    Fail-Test "validation Execution Event"
}

. $Runtime

# ============================================================
# BASE
# ============================================================

$base = @{
    ConfigPath = $ConfigPath
    ExecutionId = "EXEC-7H27-001"
    CorrelationId = "CORR-7H27-001"
    TenantId = "TENANT-001"
    ClientId = "CLIENT-001"
    ProjectId = "PROJECT-001"
    WorkerId = "MAYA"
    SkillId = "SKILL-001"
    TaskId = "TASK-001"
}

# ============================================================
# TEST 2
# Transition CREATED → VALIDATING
# ============================================================

$result = Test-ExecutionTransition `
    -ConfigPath $ConfigPath `
    -FromState "CREATED" `
    -ToState "VALIDATING"

if ($result.status -eq "ALLOWED") {
    Pass-Test "transition CREATED → VALIDATING autorisée"
}
else {
    Fail-Test "transition CREATED → VALIDATING incorrecte"
}

# ============================================================
# TEST 3
# Transition VALIDATING → AUTHORIZED
# ============================================================

$result = Test-ExecutionTransition `
    -ConfigPath $ConfigPath `
    -FromState "VALIDATING" `
    -ToState "AUTHORIZED"

if ($result.status -eq "ALLOWED") {
    Pass-Test "transition VALIDATING → AUTHORIZED autorisée"
}
else {
    Fail-Test "transition VALIDATING → AUTHORIZED incorrecte"
}

# ============================================================
# TEST 4
# Transition AUTHORIZED → RUNNING
# ============================================================

$result = Test-ExecutionTransition `
    -ConfigPath $ConfigPath `
    -FromState "AUTHORIZED" `
    -ToState "RUNNING"

if ($result.status -eq "ALLOWED") {
    Pass-Test "transition AUTHORIZED → RUNNING autorisée"
}
else {
    Fail-Test "transition AUTHORIZED → RUNNING incorrecte"
}

# ============================================================
# TEST 5
# Transition RUNNING → COMPLETED
# ============================================================

$result = Test-ExecutionTransition `
    -ConfigPath $ConfigPath `
    -FromState "RUNNING" `
    -ToState "COMPLETED"

if ($result.status -eq "ALLOWED") {
    Pass-Test "transition RUNNING → COMPLETED autorisée"
}
else {
    Fail-Test "transition RUNNING → COMPLETED incorrecte"
}

# ============================================================
# TEST 6
# Transition terminale interdite
# ============================================================

$result = Test-ExecutionTransition `
    -ConfigPath $ConfigPath `
    -FromState "COMPLETED" `
    -ToState "RUNNING"

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "INVALID_TRANSITION"
) {
    Pass-Test "retour COMPLETED → RUNNING bloqué"
}
else {
    Fail-Test "transition terminale contournable"
}

# ============================================================
# TEST 7
# Event creation
# ============================================================

$event = New-ExecutionEvent `
    @base `
    -EventType "STATE_CHANGED" `
    -FromState "CREATED" `
    -ToState "VALIDATING" `
    -Message "Execution validation started"

if (
    $event.status -eq "CREATED" -and
    $event.eventId
) {
    Pass-Test "événement créé correctement"
}
else {
    Fail-Test "création événement incorrecte"
}

# ============================================================
# TEST 8
# Secret sanitization
# ============================================================

$data = [pscustomobject]@{
    status = "TEST"
    api_key = "SECRET_MUST_DISAPPEAR"
    access_token = "TOKEN_MUST_DISAPPEAR"
    normalValue = "SAFE"
}

$event = New-ExecutionEvent `
    @base `
    -EventType "DATA_TEST" `
    -FromState "CREATED" `
    -ToState "VALIDATING" `
    -Message "Security test" `
    -Data $data

$serialized = $event | ConvertTo-Json -Depth 20 -Compress

if (
    $serialized -notmatch "SECRET_MUST_DISAPPEAR" -and
    $serialized -notmatch "TOKEN_MUST_DISAPPEAR" -and
    $serialized -match "SAFE"
) {
    Pass-Test "données sensibles filtrées de l'événement"
}
else {
    Fail-Test "données sensibles présentes dans l'événement"
}

# ============================================================
# TEST 9
# Event recording
# ============================================================

$event = New-ExecutionEvent `
    @base `
    -EventType "STATE_CHANGED" `
    -FromState "CREATED" `
    -ToState "VALIDATING" `
    -Message "Execution validation started"

$record = Write-ExecutionEvent `
    -EventPath $EventPath `
    -Event $event

if (
    $record.status -eq "RECORDED" -and
    (Test-Path -LiteralPath $EventPath)
) {
    Pass-Test "événement enregistré dans le Event Ledger"
}
else {
    Fail-Test "événement non enregistré"
}

# ============================================================
# TEST 10
# History
# ============================================================

$historyLines = @(
    Get-Content `
        -LiteralPath $EventPath `
        -Encoding UTF8
)

$matchingEvents = @()

foreach ($line in $historyLines) {

    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }

    try {
        $parsedEvent = $line | ConvertFrom-Json
    }
    catch {
        continue
    }

    if (
        $parsedEvent.executionId -eq $base.ExecutionId -and
        $parsedEvent.eventType -eq "STATE_CHANGED" -and
        $parsedEvent.fromState -eq "CREATED" -and
        $parsedEvent.toState -eq "VALIDATING"
    ) {
        $matchingEvents += $parsedEvent
    }
}

if ($matchingEvents.Count -ge 1) {
    Pass-Test "historique événementiel correctement récupéré"
}
else {
    Fail-Test "historique événementiel incorrect"
}
# TEST 11
# Lifecycle helper
# ============================================================

$state = Get-ExecutionLifecycleState `
    -ConfigPath $ConfigPath `
    -CurrentState "RUNNING" `
    -RequestedState "COMPLETED"

if (
    $state.status -eq "AUTHORIZED" -and
    $state.nextState -eq "COMPLETED"
) {
    Pass-Test "lifecycle helper autorise COMPLETED"
}
else {
    Fail-Test "lifecycle helper incorrect"
}

# ============================================================
# TEST 12
# Invalid transition
# ============================================================

$state = Get-ExecutionLifecycleState `
    -ConfigPath $ConfigPath `
    -CurrentState "FAILED" `
    -RequestedState "RUNNING"

if (
    $state.status -eq "BLOCKED" -and
    $state.reason -eq "INVALID_TRANSITION"
) {
    Pass-Test "lifecycle helper bloque FAILED → RUNNING"
}
else {
    Fail-Test "lifecycle helper laisse passer une transition interdite"
}

# ============================================================
# TEST 13
# Context incomplete
# ============================================================

$test = $base.Clone()

$test.ProjectId = ""

$result = New-ExecutionEvent `
    @test `
    -EventType "STATE_CHANGED" `
    -FromState "CREATED" `
    -ToState "VALIDATING"

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "EVENT_CONTEXT_INCOMPLETE" -and
    $result.field -eq "ProjectId"
) {
    Pass-Test "contexte événementiel incomplet bloqué"
}
else {
    Fail-Test "contexte événementiel incomplet non bloqué"
}

# ============================================================
# TEST 14
# Append only
# ============================================================

$before = (Get-Content `
    -LiteralPath $EventPath `
    -Encoding UTF8).Count

$event2 = New-ExecutionEvent `
    @base `
    -EventType "STATE_CHANGED" `
    -FromState "VALIDATING" `
    -ToState "AUTHORIZED" `
    -Message "Execution authorized"

$record2 = Write-ExecutionEvent `
    -EventPath $EventPath `
    -Event $event2

$after = (Get-Content `
    -LiteralPath $EventPath `
    -Encoding UTF8).Count

if (
    $record2.status -eq "RECORDED" -and
    $after -eq ($before + 1)
) {
    Pass-Test "Event Ledger append-only respecté"
}
else {
    Fail-Test "Event Ledger append-only incorrect"
}

# ============================================================
# TEST 15
# LIVE
# ============================================================

$event3 = New-ExecutionEvent `
    @base `
    -EventType "STATE_CHANGED" `
    -FromState "AUTHORIZED" `
    -ToState "RUNNING"

if (
    $event3.status -eq "CREATED" -and
    $event3.externalCallPerformed -eq $false
) {
    Pass-Test "Event lifecycle sans appel externe"
}
else {
    Fail-Test "appel externe inattendu"
}

Write-Host ""
Write-Host "RESULTATS 7H-27"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"
Write-Host ""

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Execution Event Bus & Lifecycle opérationnels."
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1