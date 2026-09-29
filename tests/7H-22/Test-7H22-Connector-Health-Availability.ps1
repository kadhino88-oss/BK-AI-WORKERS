$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Dir = Join-Path $Root "core\runtime\connector-health"

$ConfigPath = Join-Path `
    $Dir `
    "CONNECTOR-HEALTH-CONFIG.json"

$Validator = Join-Path `
    $Dir `
    "Validate-Connector-Health.ps1"

$Runtime = Join-Path `
    $Dir `
    "CONNECTOR-HEALTH-RUNTIME.ps1"

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
Write-Host "7H-22 - CONNECTOR HEALTH & AVAILABILITY"
Write-Host "============================================="
Write-Host ""

# ============================================================
# TEST 1
# ============================================================

try {
    & $Validator $ConfigPath | Out-Host

    if ($LASTEXITCODE -eq 0) {
        Pass-Test "Health Config valide"
    }
    else {
        Fail-Test "Health Config invalide"
    }
}
catch {
    Fail-Test "validation Health Config"
}

. $Runtime

# ============================================================
# TEST 2
# Health GMAIL
# ============================================================

$result = Get-ConnectorHealthState `
    -ConfigPath $ConfigPath `
    -ConnectorId "gmail.controlled"

if (
    $result.status -eq "HEALTHY" -and
    $result.available -eq $true
) {
    Pass-Test "GMAIL HEALTHY et disponible"
}
else {
    Fail-Test "GMAIL health incorrect"
}

# ============================================================
# TEST 3
# CRM degraded
# ============================================================

$result = Get-ConnectorHealthState `
    -ConfigPath $ConfigPath `
    -ConnectorId "crm.controlled"

if (
    $result.status -eq "DEGRADED" -and
    $result.retryRecommended -eq $true
) {
    Pass-Test "CRM DEGRADED correctement signalé"
}
else {
    Fail-Test "CRM DEGRADED incorrect"
}

# ============================================================
# TEST 4
# Connector inconnu
# ============================================================

$result = Get-ConnectorHealthState `
    -ConfigPath $ConfigPath `
    -ConnectorId "unknown.connector"

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "CONNECTOR_NOT_FOUND"
) {
    Pass-Test "connector inconnu bloqué"
}
else {
    Fail-Test "connector inconnu non bloqué"
}

# ============================================================
# TEST 5
# Retry plan
# ============================================================

$result = New-RetryPlan `
    -ConfigPath $ConfigPath `
    -ConnectorId "gmail.controlled" `
    -Attempt 1 `
    -PreviousAttemptFailed $true

if (
    $result.status -eq "RETRY" -and
    $result.retryAllowed -eq $true -and
    $result.attempt -eq 1
) {
    Pass-Test "retry contrôlé correctement planifié"
}
else {
    Fail-Test "retry incorrect"
}

# ============================================================
# TEST 6
# Retry épuisé
# ============================================================

$result = New-RetryPlan `
    -ConfigPath $ConfigPath `
    -ConnectorId "gmail.controlled" `
    -Attempt 4 `
    -PreviousAttemptFailed $true

if (
    $result.status -eq "EXHAUSTED" -and
    $result.retryAllowed -eq $false
) {
    Pass-Test "limite de retry respectée"
}
else {
    Fail-Test "limite de retry non respectée"
}

# ============================================================
# TEST 7
# Circuit fermé
# ============================================================

$circuit = New-CircuitBreakerState `
    -ConnectorId "gmail.controlled" `
    -FailureCount 0 `
    -State "CLOSED"

$result = Evaluate-CircuitBreaker `
    -ConfigPath $ConfigPath `
    -CircuitState $circuit

if (
    $result.status -eq "CLOSED" -and
    $result.executionAllowed -eq $true
) {
    Pass-Test "circuit CLOSED autorise l'exécution"
}
else {
    Fail-Test "circuit CLOSED incorrect"
}

# ============================================================
# TEST 8
# Circuit ouvert
# ============================================================

$circuit = New-CircuitBreakerState `
    -ConnectorId "gmail.controlled" `
    -FailureCount 3 `
    -State "OPEN"

$result = Evaluate-CircuitBreaker `
    -ConfigPath $ConfigPath `
    -CircuitState $circuit

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "CIRCUIT_OPEN" -and
    $result.executionAllowed -eq $false
) {
    Pass-Test "circuit OPEN bloque l'exécution"
}
else {
    Fail-Test "circuit OPEN non bloqué"
}

# ============================================================
# TEST 9
# Exécution gérée
# ============================================================

$result = Invoke-HealthManagedExecution `
    -ConfigPath $ConfigPath `
    -ConnectorId "gmail.controlled" `
    -ExecutionId "EXEC-7H22-001" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -FailureCount 0 `
    -Mode "SIMULATION"

if (
    $result.status -eq "READY" -and
    $result.externalCallPerformed -eq $false -and
    $result.secretExposure -eq $false
) {
    Pass-Test "exécution gérée prête sans appel externe"
}
else {
    Fail-Test "exécution gérée incorrecte"
}

# ============================================================
# TEST 10
# LIVE interdit
# ============================================================

$result = Invoke-HealthManagedExecution `
    -ConfigPath $ConfigPath `
    -ConnectorId "gmail.controlled" `
    -ExecutionId "EXEC-7H22-002" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -FailureCount 0 `
    -Mode "LIVE"

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "LIVE_EXECUTION_DISABLED"
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

$result = Invoke-HealthManagedExecution `
    -ConfigPath $ConfigPath `
    -ConnectorId "gmail.controlled" `
    -ExecutionId "EXEC-7H22-003" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "" `
    -FailureCount 0 `
    -Mode "SIMULATION"

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "CONTEXT_INCOMPLETE" -and
    $result.field -eq "ProjectId"
) {
    Pass-Test "contexte incomplet correctement bloqué"
}
else {
    Fail-Test "contexte incomplet non bloqué"
}

# ============================================================
# TEST 12
# Secret exposure
# ============================================================

$testObject = [pscustomobject]@{
    connectorId = "gmail.controlled"
    apiKey = $null
    accessToken = $null
    password = $null
}

$serialized = $testObject | ConvertTo-Json -Depth 10

if (
    $serialized -notmatch '"apiKey"\s*:\s*"[^"]+"' -and
    $serialized -notmatch '"accessToken"\s*:\s*"[^"]+"' -and
    $serialized -notmatch '"password"\s*:\s*"[^"]+"'
) {
    Pass-Test "aucun secret brut présent dans le modèle de health"
}
else {
    Fail-Test "secret brut détecté"
}

Write-Host ""
Write-Host "RESULTATS 7H-22"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"
Write-Host ""

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Connector Health & Availability Manager opérationnel."
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1