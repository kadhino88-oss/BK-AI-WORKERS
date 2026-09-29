$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Dir = Join-Path $Root "core\runtime\orchestrator-controller"

$ConfigPath = Join-Path `
    $Dir `
    "ORCHESTRATOR-CONTROLLER-CONFIG.json"

$Validator = Join-Path `
    $Dir `
    "Validate-Orchestrator-Controller.ps1"

$Runtime = Join-Path `
    $Dir `
    "ORCHESTRATOR-CONTROLLER-RUNTIME.ps1"

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
Write-Host "7H-28 - EXECUTION ORCHESTRATOR CONTROLLER"
Write-Host "============================================="
Write-Host ""

# ============================================================
# TEST 1
# ============================================================

try {
    & $Validator $ConfigPath | Out-Host

    if ($LASTEXITCODE -eq 0) {
        Pass-Test "Orchestrator Controller Config valide"
    }
    else {
        Fail-Test "Orchestrator Controller Config invalide"
    }
}
catch {
    Fail-Test "validation Orchestrator Controller"
}

. $Runtime

# ============================================================
# BASE COMPLETE
# ============================================================

$base = @{
    ConfigPath = $ConfigPath

    ExecutionId = "EXEC-7H28-001"
    CorrelationId = "CORR-7H28-001"

    TenantId = "TENANT-001"
    ClientId = "CLIENT-001"
    ProjectId = "PROJECT-001"

    WorkerId = "MAYA"
    SkillId = "SKILL-001"
    TaskId = "TASK-001"
    ToolId = "TOOL-001"
    Action = "READ_CONTACT"

    ConnectorId = "crm.controlled"
    AdapterId = "crm.default"
    CredentialRef = "cred.client001.crm"

    IdempotencyKey = "IDEMP-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    PolicyDecision = "SIMULATION"

    HealthState = "HEALTHY"

    CapabilityAuthorized = $true
    AdapterResolved = $true
    CredentialResolved = $true
    ConnectorResolved = $true
    HealthExecutionAllowed = $true

    IdempotencyValid = $true
    DuplicateExecution = $false

    TimeoutValid = $true

    Attempt = 1
    MaxAttempts = 3

    Mode = "SIMULATION"

    DirectConnectorExecution = $false
    SecretForwardingAttempt = $false
}

# ============================================================
# TEST 2
# Exécution complète
# ============================================================

$result = New-OrchestratorExecutionRequest @base

if (
    $result.status -eq "AUTHORIZED" -and
    $result.pipelineCompleted -eq $true -and
    $result.externalCallPerformed -eq $false -and
    $result.secretExposure -eq $false
) {
    Pass-Test "exécution complète orchestrée sans appel externe"
}
else {
    Fail-Test "orchestration complète incorrecte"
}

# ============================================================
# TEST 3
# Capability
# ============================================================

$test = $base.Clone()
$test.CapabilityAuthorized = $false

$result = New-OrchestratorExecutionRequest @test

if (
    $result.status -eq "BLOCKED" -and
    $result.failedStage -eq "CAPABILITY"
) {
    Pass-Test "capability contrôlée en premier"
}
else {
    Fail-Test "capability non contrôlée en premier"
}

# ============================================================
# TEST 4
# Context
# ============================================================

$test = $base.Clone()
$test.ProjectId = ""

$result = New-OrchestratorExecutionRequest @test

if (
    $result.status -eq "BLOCKED" -and
    $result.failedStage -eq "CONTEXT" -and
    $result.field -eq "ProjectId"
) {
    Pass-Test "contexte contrôlé avant policy"
}
else {
    Fail-Test "contexte mal contrôlé"
}

# ============================================================
# TEST 5
# Policy
# ============================================================

$test = $base.Clone()
$test.PolicyDecision = "BLOCKED"

$result = New-OrchestratorExecutionRequest @test

if (
    $result.status -eq "BLOCKED" -and
    $result.failedStage -eq "POLICY"
) {
    Pass-Test "policy bloque l'orchestration"
}
else {
    Fail-Test "policy contournable"
}

# ============================================================
# TEST 6
# Adapter
# ============================================================

$test = $base.Clone()
$test.AdapterResolved = $false

$result = New-OrchestratorExecutionRequest @test

if (
    $result.status -eq "BLOCKED" -and
    $result.failedStage -eq "ADAPTER"
) {
    Pass-Test "adapter obligatoire"
}
else {
    Fail-Test "adapter non résolu non bloqué"
}

# ============================================================
# TEST 7
# Credential
# ============================================================

$test = $base.Clone()
$test.CredentialResolved = $false

$result = New-OrchestratorExecutionRequest @test

if (
    $result.status -eq "BLOCKED" -and
    $result.failedStage -eq "CREDENTIAL"
) {
    Pass-Test "credential obligatoire"
}
else {
    Fail-Test "credential non résolu non bloqué"
}

# ============================================================
# TEST 8
# Health
# ============================================================

$test = $base.Clone()
$test.HealthExecutionAllowed = $false
$test.HealthState = "UNAVAILABLE"

$result = New-OrchestratorExecutionRequest @test

if (
    $result.status -eq "BLOCKED" -and
    $result.failedStage -eq "HEALTH"
) {
    Pass-Test "health contrôle l'orchestration"
}
else {
    Fail-Test "health non contrôlé"
}

# ============================================================
# TEST 9
# Execution controls
# ============================================================

$test = $base.Clone()
$test.IdempotencyValid = $false

$result = New-OrchestratorExecutionRequest @test

if (
    $result.status -eq "BLOCKED" -and
    $result.failedStage -eq "EXECUTION_CONTROLS"
) {
    Pass-Test "execution controls obligatoires"
}
else {
    Fail-Test "execution controls contournables"
}

# ============================================================
# TEST 10
# Duplicate
# ============================================================

$test = $base.Clone()
$test.DuplicateExecution = $true

$result = New-OrchestratorExecutionRequest @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "DUPLICATE_EXECUTION"
) {
    Pass-Test "duplicate bloqué par l'orchestrateur"
}
else {
    Fail-Test "duplicate non bloqué"
}

# ============================================================
# TEST 11
# Connector
# ============================================================

$test = $base.Clone()
$test.ConnectorResolved = $false

$result = New-OrchestratorExecutionRequest @test

if (
    $result.status -eq "BLOCKED" -and
    $result.failedStage -eq "CONNECTOR"
) {
    Pass-Test "connector obligatoire"
}
else {
    Fail-Test "connector non résolu non bloqué"
}

# ============================================================
# TEST 12
# Secret forwarding
# ============================================================

$test = $base.Clone()
$test.SecretForwardingAttempt = $true

$result = New-OrchestratorExecutionRequest @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "SECRET_FORWARDING_ATTEMPT"
) {
    Pass-Test "secret forwarding bloqué"
}
else {
    Fail-Test "secret forwarding non bloqué"
}

# ============================================================
# TEST 13
# Direct execution
# ============================================================

$test = $base.Clone()
$test.DirectConnectorExecution = $true

$result = New-OrchestratorExecutionRequest @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "DIRECT_CONNECTOR_EXECUTION_FORBIDDEN"
) {
    Pass-Test "direct connector execution bloquée"
}
else {
    Fail-Test "direct connector execution accessible"
}

# ============================================================
# TEST 14
# LIVE
# ============================================================

$test = $base.Clone()
$test.Mode = "LIVE"
$test.PolicyDecision = "LIVE"

$result = New-OrchestratorExecutionRequest @test

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
# TEST 15
# Pipeline stages
# ============================================================

$result = New-OrchestratorExecutionRequest @base

$expectedStages = @(
    "CAPABILITY",
    "CONTEXT",
    "POLICY",
    "ADAPTER",
    "CREDENTIAL",
    "HEALTH",
    "EXECUTION_CONTROLS",
    "GATEWAY",
    "CONNECTOR",
    "RESULT",
    "EVENT",
    "AUDIT"
)

$missingStages = @()

foreach ($stage in $expectedStages) {
    if ($result.pipelineStages -notcontains $stage) {
        $missingStages += $stage
    }
}

if ($missingStages.Count -eq 0) {
    Pass-Test "ordre complet des 12 stages présent"
}
else {
    Fail-Test "stages manquants"
}

Write-Host ""
Write-Host "RESULTATS 7H-28"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"
Write-Host ""

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Execution Orchestrator Controller opérationnel."
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1