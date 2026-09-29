$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Dir = Join-Path $Root "core\runtime\execution-pipeline"

$ConfigPath = Join-Path `
    $Dir `
    "EXECUTION-PIPELINE-CONFIG.json"

$Validator = Join-Path `
    $Dir `
    "Validate-Execution-Pipeline.ps1"

$Runtime = Join-Path `
    $Dir `
    "EXECUTION-PIPELINE-RUNTIME.ps1"

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
Write-Host "7H-25 - EXTERNAL CONNECTOR EXECUTION PIPELINE"
Write-Host "============================================="
Write-Host ""

# ============================================================
# TEST 1
# ============================================================

try {
    & $Validator $ConfigPath | Out-Host

    if ($LASTEXITCODE -eq 0) {
        Pass-Test "Execution Pipeline Config valide"
    }
    else {
        Fail-Test "Execution Pipeline Config invalide"
    }
}
catch {
    Fail-Test "validation Execution Pipeline"
}

. $Runtime

# ============================================================
# BASE COMPLETE
# ============================================================

$base = @{
    ConfigPath = $ConfigPath
    ExecutionId = "EXEC-7H25-001"
    CorrelationId = "CORR-7H25-001"
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
    Mode = "SIMULATION"
    CapabilityAuthorized = $true
    PolicyDecision = "SIMULATION"
    HealthState = "HEALTHY"
    HealthExecutionAllowed = $true
    IdempotencyValid = $true
    DuplicateExecution = $false
    Attempt = 1
    MaxAttempts = 3
    TimeoutValid = $true
    DirectConnectorExecution = $false
    SecretForwardingAttempt = $false
    AdapterResolved = $true
    CredentialResolved = $true
    ConnectorResolved = $true
}

# ============================================================
# TEST 2
# PIPELINE COMPLETE
# ============================================================

$result = Invoke-ExternalConnectorExecutionPipeline @base

if (
    $result.status -eq "AUTHORIZED" -and
    $result.pipelineCompleted -eq $true -and
    $result.externalCallPerformed -eq $false -and
    $result.secretExposure -eq $false -and
    $result.auditRequired -eq $true
) {
    Pass-Test "pipeline complète exécutée dans le bon ordre"
}
else {
    Fail-Test "pipeline complète incorrecte"
}

# ============================================================
# TEST 3
# Capability
# ============================================================

$test = $base.Clone()
$test.CapabilityAuthorized = $false

$result = Invoke-ExternalConnectorExecutionPipeline @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "CAPABILITY_NOT_AUTHORIZED" -and
    $result.failedStage -eq "CAPABILITY"
) {
    Pass-Test "capability bloque le pipeline"
}
else {
    Fail-Test "capability contournable"
}

# ============================================================
# TEST 4
# Context
# ============================================================

$test = $base.Clone()
$test.ProjectId = ""

$result = Invoke-ExternalConnectorExecutionPipeline @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "CONTEXT_INCOMPLETE" -and
    $result.failedStage -eq "CONTEXT:ProjectId"
) {
    Pass-Test "contexte incomplet bloque le pipeline"
}
else {
    Fail-Test "contexte contournable"
}

# ============================================================
# TEST 5
# Policy
# ============================================================

$test = $base.Clone()
$test.PolicyDecision = "BLOCKED"

$result = Invoke-ExternalConnectorExecutionPipeline @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "POLICY_BLOCKED" -and
    $result.failedStage -eq "POLICY"
) {
    Pass-Test "policy bloque le pipeline"
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

$result = Invoke-ExternalConnectorExecutionPipeline @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "ADAPTER_NOT_RESOLVED" -and
    $result.failedStage -eq "ADAPTER"
) {
    Pass-Test "adapter non résolu bloque le pipeline"
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

$result = Invoke-ExternalConnectorExecutionPipeline @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "CREDENTIAL_NOT_RESOLVED" -and
    $result.failedStage -eq "CREDENTIAL"
) {
    Pass-Test "credential non résolu bloque le pipeline"
}
else {
    Fail-Test "credential non résolu non bloqué"
}

# ============================================================
# TEST 8
# Health
# ============================================================

$test = $base.Clone()
$test.HealthState = "UNAVAILABLE"
$test.HealthExecutionAllowed = $false

$result = Invoke-ExternalConnectorExecutionPipeline @test

if (
    $result.status -eq "BLOCKED" -and
    $result.failedStage -eq "HEALTH"
) {
    Pass-Test "health indisponible bloque le pipeline"
}
else {
    Fail-Test "health indisponible non bloqué"
}

# ============================================================
# TEST 9
# Idempotency
# ============================================================

$test = $base.Clone()
$test.IdempotencyValid = $false

$result = Invoke-ExternalConnectorExecutionPipeline @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "IDEMPOTENCY_INVALID" -and
    $result.failedStage -eq "IDEMPOTENCY"
) {
    Pass-Test "idempotency invalide bloque le pipeline"
}
else {
    Fail-Test "idempotency contournable"
}

# ============================================================
# TEST 10
# Duplicate
# ============================================================

$test = $base.Clone()
$test.DuplicateExecution = $true

$result = Invoke-ExternalConnectorExecutionPipeline @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "DUPLICATE_EXECUTION" -and
    $result.failedStage -eq "IDEMPOTENCY"
) {
    Pass-Test "duplicate bloque le pipeline"
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

$result = Invoke-ExternalConnectorExecutionPipeline @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "CONNECTOR_NOT_RESOLVED" -and
    $result.failedStage -eq "CONNECTOR"
) {
    Pass-Test "connector non résolu bloque le pipeline"
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

$result = Invoke-ExternalConnectorExecutionPipeline @test

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
# Direct connector execution
# ============================================================

$test = $base.Clone()
$test.DirectConnectorExecution = $true

$result = Invoke-ExternalConnectorExecutionPipeline @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "DIRECT_CONNECTOR_EXECUTION_FORBIDDEN"
) {
    Pass-Test "exécution directe bloquée"
}
else {
    Fail-Test "exécution directe non bloquée"
}

# ============================================================
# TEST 14
# LIVE
# ============================================================

$test = $base.Clone()
$test.Mode = "LIVE"
$test.PolicyDecision = "LIVE"

$result = Invoke-ExternalConnectorExecutionPipeline @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "LIVE_EXECUTION_DISABLED"
) {
    Pass-Test "LIVE bloqué"
}
else {
    Fail-Test "LIVE accessible"
}

# ============================================================
# TEST 15
# Retry exhausted
# ============================================================

$test = $base.Clone()
$test.Attempt = 4
$test.MaxAttempts = 3

$result = Invoke-ExternalConnectorExecutionPipeline @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "RETRY_EXHAUSTED"
) {
    Pass-Test "retry épuisé bloque le pipeline"
}
else {
    Fail-Test "retry épuisé non bloqué"
}

Write-Host ""
Write-Host "RESULTATS 7H-25"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"
Write-Host ""

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "External Connector Execution Pipeline opérationnel."
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1