$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Dir = Join-Path $Root "core\runtime\execution-controls"

$ConfigPath = Join-Path `
    $Dir `
    "EXECUTION-CONTROLS-CONFIG.json"

$Validator = Join-Path `
    $Dir `
    "Validate-Execution-Controls.ps1"

$Runtime = Join-Path `
    $Dir `
    "EXECUTION-CONTROLS-RUNTIME.ps1"

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
Write-Host "7H-23 - RETRY / TIMEOUT / IDEMPOTENCY"
Write-Host "============================================="
Write-Host ""

# ============================================================
# TEST 1
# ============================================================

try {
    & $Validator $ConfigPath | Out-Host

    if ($LASTEXITCODE -eq 0) {
        Pass-Test "Execution Controls valides"
    }
    else {
        Fail-Test "Execution Controls invalides"
    }
}
catch {
    Fail-Test "validation Execution Controls"
}

. $Runtime

# ============================================================
# TEST 2
# Timeout valide
# ============================================================

$result = Get-TimeoutDecision `
    -ConfigPath $ConfigPath `
    -TimeoutSeconds 30

if (
    $result.status -eq "VALID" -and
    $result.timeoutSeconds -eq 30
) {
    Pass-Test "timeout valide accepté"
}
else {
    Fail-Test "timeout valide incorrect"
}

# ============================================================
# TEST 3
# Timeout excessif
# ============================================================

$result = Get-TimeoutDecision `
    -ConfigPath $ConfigPath `
    -TimeoutSeconds 999

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "TIMEOUT_TOO_HIGH"
) {
    Pass-Test "timeout excessif bloqué"
}
else {
    Fail-Test "timeout excessif non bloqué"
}

# ============================================================
# TEST 4
# Retry
# ============================================================

$result = Get-RetryDecision `
    -ConfigPath $ConfigPath `
    -Attempt 1 `
    -PreviousAttemptFailed $true

if (
    $result.status -eq "RETRY" -and
    $result.retryAllowed -eq $true
) {
    Pass-Test "retry contrôlé autorisé"
}
else {
    Fail-Test "retry contrôlé incorrect"
}

# ============================================================
# TEST 5
# Retry exhausted
# ============================================================

$result = Get-RetryDecision `
    -ConfigPath $ConfigPath `
    -Attempt 4 `
    -PreviousAttemptFailed $true

if (
    $result.status -eq "EXHAUSTED" -and
    $result.retryAllowed -eq $false
) {
    Pass-Test "retry épuisé correctement bloqué"
}
else {
    Fail-Test "retry épuisé non bloqué"
}

# ============================================================
# TEST 6
# Idempotency key
# ============================================================

$idemp = New-IdempotencyKey `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -Operation "CREATE_TASK" `
    -TaskId "TASK-001" `
    -ExecutionId "EXEC-7H23-001"

if (
    $idemp.status -eq "CREATED" -and
    $idemp.idempotencyKey -match '^IDEMP-[a-f0-9]{64}$'
) {
    Pass-Test "idempotency key correctement générée"
}
else {
    Fail-Test "idempotency key incorrecte"
}

# ============================================================
# TEST 7
# Idempotency duplicate
# ============================================================

$duplicate = Test-IdempotencyDuplicate `
    -IdempotencyKey $idemp.idempotencyKey `
    -KnownKeys @(
        $idemp.idempotencyKey
    )

if (
    $duplicate.status -eq "DUPLICATE" -and
    $duplicate.executionAllowed -eq $false
) {
    Pass-Test "double exécution correctement bloquée"
}
else {
    Fail-Test "double exécution non bloquée"
}

# ============================================================
# TEST 8
# Idempotency validation
# ============================================================

$validation = Validate-IdempotencyKey `
    -ConfigPath $ConfigPath `
    -IdempotencyKey $idemp.idempotencyKey

if (
    $validation.status -eq "VALID"
) {
    Pass-Test "idempotency key validée"
}
else {
    Fail-Test "idempotency key invalide"
}

# ============================================================
# TEST 9
# Execution Control Decision
# ============================================================

$decision = Get-ExecutionControlDecision `
    -ConfigPath $ConfigPath `
    -ExecutionId "EXEC-7H23-002" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -Operation "READ_CONTACT" `
    -TaskId "TASK-002" `
    -IdempotencyKey $idemp.idempotencyKey `
    -TimeoutSeconds 30 `
    -Attempt 1 `
    -PreviousAttemptFailed $false `
    -KnownIdempotencyKeys @() `
    -Mode "SIMULATION"

if (
    $decision.status -eq "AUTHORIZED" -and
    $decision.externalCallAllowed -eq $false
) {
    Pass-Test "décision d'exécution contrôlée autorisée"
}
else {
    Fail-Test "décision d'exécution incorrecte"
}

# ============================================================
# TEST 10
# LIVE bloqué
# ============================================================

$newIdemp = New-IdempotencyKey `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -Operation "READ_CONTACT" `
    -TaskId "TASK-003" `
    -ExecutionId "EXEC-7H23-003"

$decision = Get-ExecutionControlDecision `
    -ConfigPath $ConfigPath `
    -ExecutionId "EXEC-7H23-003" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -Operation "READ_CONTACT" `
    -TaskId "TASK-003" `
    -IdempotencyKey $newIdemp.idempotencyKey `
    -TimeoutSeconds 30 `
    -Attempt 1 `
    -Mode "LIVE"

if (
    $decision.status -eq "BLOCKED" -and
    $decision.reason -eq "LIVE_EXECUTION_DISABLED"
) {
    Pass-Test "LIVE toujours bloqué"
}
else {
    Fail-Test "LIVE accessible"
}

# ============================================================
# TEST 11
# Contexte incomplet
# ============================================================

$incompleteIdemp = New-IdempotencyKey `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -Operation "READ_CONTACT" `
    -TaskId "TASK-004" `
    -ExecutionId "EXEC-7H23-004"

$decision = Get-ExecutionControlDecision `
    -ConfigPath $ConfigPath `
    -ExecutionId "EXEC-7H23-004" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "" `
    -Operation "READ_CONTACT" `
    -TaskId "TASK-004" `
    -IdempotencyKey $incompleteIdemp.idempotencyKey `
    -TimeoutSeconds 30 `
    -Attempt 1 `
    -Mode "SIMULATION"

if (
    $decision.status -eq "BLOCKED" -and
    $decision.reason -eq "CONTEXT_INCOMPLETE" -and
    $decision.field -eq "ProjectId"
) {
    Pass-Test "contexte incomplet bloqué"
}
else {
    Fail-Test "contexte incomplet non bloqué"
}

# ============================================================
# TEST 12
# Idempotency key absente
# ============================================================

$decision = Get-ExecutionControlDecision `
    -ConfigPath $ConfigPath `
    -ExecutionId "EXEC-7H23-005" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -Operation "CREATE_TASK" `
    -TaskId "TASK-005" `
    -IdempotencyKey "" `
    -TimeoutSeconds 30 `
    -Attempt 1 `
    -Mode "SIMULATION"

if (
    $decision.status -eq "BLOCKED" -and
    $decision.reason -eq "IDEMPOTENCY_KEY_REQUIRED"
) {
    Pass-Test "idempotency obligatoire respectée"
}
else {
    Fail-Test "idempotency obligatoire non respectée"
}

Write-Host ""
Write-Host "RESULTATS 7H-23"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"
Write-Host ""

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Retry / Timeout / Idempotency Manager opérationnel."
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1