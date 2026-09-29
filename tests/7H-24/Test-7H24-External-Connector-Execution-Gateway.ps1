$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Dir = Join-Path $Root "core\runtime\execution-gateway"

$ConfigPath = Join-Path `
    $Dir `
    "EXECUTION-GATEWAY-CONFIG.json"

$Validator = Join-Path `
    $Dir `
    "Validate-Execution-Gateway.ps1"

$Runtime = Join-Path `
    $Dir `
    "EXTERNAL-CONNECTOR-EXECUTION-GATEWAY.ps1"

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
Write-Host "7H-24 - EXTERNAL CONNECTOR EXECUTION GATEWAY"
Write-Host "============================================="
Write-Host ""

# ============================================================
# TEST 1
# ============================================================

try {
    & $Validator $ConfigPath | Out-Host

    if ($LASTEXITCODE -eq 0) {
        Pass-Test "Execution Gateway Config valide"
    }
    else {
        Fail-Test "Execution Gateway Config invalide"
    }
}
catch {
    Fail-Test "validation Gateway"
}

. $Runtime

# ============================================================
# BASE VALID
# ============================================================

$base = @{
    ConfigPath = $ConfigPath
    ExecutionId = "EXEC-7H24-001"
    CorrelationId = "CORR-7H24-001"
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
}

# ============================================================
# TEST 2
# Execution authorized
# ============================================================

$result = Invoke-ExternalConnectorExecutionGateway @base

if (
    $result.status -eq "AUTHORIZED" -and
    $result.externalCallAllowed -eq $false -and
    $result.externalCallPerformed -eq $false
) {
    Pass-Test "exécution complète autorisée mais sans appel externe"
}
else {
    Fail-Test "exécution complète incorrecte"
}

# ============================================================
# TEST 3
# Capability absent
# ============================================================

$test = $base.Clone()
$test.CapabilityAuthorized = $false

$result = Invoke-ExternalConnectorExecutionGateway @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "CAPABILITY_NOT_AUTHORIZED"
) {
    Pass-Test "capability absente bloquée"
}
else {
    Fail-Test "capability absente non bloquée"
}

# ============================================================
# TEST 4
# Policy BLOCKED
# ============================================================

$test = $base.Clone()
$test.PolicyDecision = "BLOCKED"

$result = Invoke-ExternalConnectorExecutionGateway @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "POLICY_BLOCKED"
) {
    Pass-Test "policy BLOCKED respectée"
}
else {
    Fail-Test "policy BLOCKED contournable"
}

# ============================================================
# TEST 5
# NEEDS_HUMAN
# ============================================================

$test = $base.Clone()
$test.PolicyDecision = "NEEDS_HUMAN"

$result = Invoke-ExternalConnectorExecutionGateway @test

if (
    $result.status -eq "NEEDS_HUMAN" -and
    $result.reason -eq "HUMAN_APPROVAL_REQUIRED"
) {
    Pass-Test "NEEDS_HUMAN respecté"
}
else {
    Fail-Test "NEEDS_HUMAN non respecté"
}

# ============================================================
# TEST 6
# Adapter absent
# ============================================================

$test = $base.Clone()
$test.AdapterId = ""

$result = Invoke-ExternalConnectorExecutionGateway @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "ADAPTER_REQUIRED"
) {
    Pass-Test "adapter absent bloqué"
}
else {
    Fail-Test "adapter absent non bloqué"
}

# ============================================================
# TEST 7
# Credential absent
# ============================================================

$test = $base.Clone()
$test.CredentialRef = ""

$result = Invoke-ExternalConnectorExecutionGateway @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "CREDENTIAL_REFERENCE_REQUIRED"
) {
    Pass-Test "credentialRef absent bloqué"
}
else {
    Fail-Test "credentialRef absent non bloqué"
}

# ============================================================
# TEST 8
# Health unavailable
# ============================================================

$test = $base.Clone()
$test.HealthState = "UNAVAILABLE"
$test.HealthExecutionAllowed = $false

$result = Invoke-ExternalConnectorExecutionGateway @test

if (
    $result.status -eq "BLOCKED" -and
    (
        $result.reason -eq "HEALTH_NOT_APPROVED" -or
        $result.reason -eq "CONNECTOR_UNAVAILABLE"
    )
) {
    Pass-Test "connector indisponible bloqué"
}
else {
    Fail-Test "connector indisponible non bloqué"
}

# ============================================================
# TEST 9
# Idempotency invalide
# ============================================================

$test = $base.Clone()
$test.IdempotencyValid = $false

$result = Invoke-ExternalConnectorExecutionGateway @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "IDEMPOTENCY_INVALID"
) {
    Pass-Test "idempotency invalide bloquée"
}
else {
    Fail-Test "idempotency invalide non bloquée"
}

# ============================================================
# TEST 10
# Duplicate
# ============================================================

$test = $base.Clone()
$test.DuplicateExecution = $true

$result = Invoke-ExternalConnectorExecutionGateway @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "DUPLICATE_EXECUTION"
) {
    Pass-Test "double exécution bloquée"
}
else {
    Fail-Test "double exécution non bloquée"
}

# ============================================================
# TEST 11
# Secret forwarding
# ============================================================

$test = $base.Clone()
$test.SecretForwardingAttempt = $true

$result = Invoke-ExternalConnectorExecutionGateway @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "SECRET_FORWARDING_ATTEMPT"
) {
    Pass-Test "transmission de secret bloquée"
}
else {
    Fail-Test "transmission de secret non bloquée"
}

# ============================================================
# TEST 12
# Direct connector execution
# ============================================================

$test = $base.Clone()
$test.DirectConnectorExecution = $true

$result = Invoke-ExternalConnectorExecutionGateway @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "DIRECT_CONNECTOR_EXECUTION_FORBIDDEN"
) {
    Pass-Test "exécution directe du connector bloquée"
}
else {
    Fail-Test "exécution directe du connector non bloquée"
}

# ============================================================
# TEST 13
# Context incomplete
# ============================================================

$test = $base.Clone()
$test.ProjectId = ""

$result = Invoke-ExternalConnectorExecutionGateway @test

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
# TEST 14
# LIVE disabled
# ============================================================

$test = $base.Clone()
$test.Mode = "LIVE"
$test.PolicyDecision = "LIVE"

$result = Invoke-ExternalConnectorExecutionGateway @test

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
# Retry exhausted
# ============================================================

$test = $base.Clone()
$test.Attempt = 4
$test.MaxAttempts = 3

$result = Invoke-ExternalConnectorExecutionGateway @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "RETRY_EXHAUSTED"
) {
    Pass-Test "retry épuisé bloqué"
}
else {
    Fail-Test "retry épuisé non bloqué"
}

Write-Host ""
Write-Host "RESULTATS 7H-24"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"
Write-Host ""

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "External Connector Execution Gateway opérationnel."
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1