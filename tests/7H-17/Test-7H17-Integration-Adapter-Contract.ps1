$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$Dir = Join-Path $Root "core\runtime\integration-adapters"

$Validator = Join-Path $Dir "Validate-Integration-Adapter-Contract.ps1"
$ContractPath = Join-Path $Dir "INTEGRATION-ADAPTER-CONTRACT.json"
$Runtime = Join-Path $Dir "ADAPTER-CONTRACT-RUNTIME.ps1"

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
Write-Host "7H-17 - INTEGRATION ADAPTER CONTRACT"
Write-Host "============================================="
Write-Host ""

# TEST 1
try {
    & $Validator $ContractPath | Out-Host
    if ($LASTEXITCODE -eq 0) {
        Pass-Test "contrat JSON valide"
    }
    else {
        Fail-Test "contrat JSON invalide"
    }
}
catch {
    Fail-Test "validation du contrat"
}

# Charge le runtime
. $Runtime

# Base commune
$base = @{
    AdapterId       = "adapter.test"
    Provider        = "TEST_PROVIDER"
    Category        = "TEST"
    AdapterVersion  = "1.0.0"
    ExecutionId     = "EXEC-7H17-001"
    CorrelationId   = "CORR-7H17-001"
    TenantId        = "TENANT-001"
    ClientId        = "CLIENT-001"
    ProjectId       = "PROJECT-001"
    WorkerId        = "MAYA"
    SkillId         = "SKILL-001"
    TaskId          = "TASK-001"
    ToolId          = "TOOL-001"
    Action          = "READ"
    Mode            = "SIMULATION"
    PolicyDecision  = "SIMULATION"
    Operation       = "TEST_OPERATION"
    Parameters      = @{
        recordId = "123"
    }
}

# TEST 2
$result = New-IntegrationAdapterRequest @base

if (
    $result.response.status -eq "SIMULATED" -and
    $result.security.secretsProvidedToAdapter -eq $false -and
    $result.security.tenantIsolation -eq $true -and
    $result.security.clientIsolation -eq $true -and
    $result.security.projectIsolation -eq $true
) {
    Pass-Test "SIMULATION conforme au contrat"
}
else {
    Fail-Test "SIMULATION non conforme"
}

# TEST 3
$base["Parameters"] = @{
    recordId = "123"
    api_key = "SHOULD_NEVER_APPEAR"
}

$result = New-IntegrationAdapterRequest @base

if ($result.status -eq "BLOCKED" -and $result.reason -eq "SECRET_EXPOSURE_ATTEMPT") {
    Pass-Test "secret détecté et bloqué"
}
else {
    Fail-Test "secret non bloqué"
}

# TEST 4
$base["Parameters"] = @{
    recordId = "123"
}

$base["ClientId"] = ""

$result = New-IntegrationAdapterRequest @base

if ($result.status -eq "BLOCKED" -and $result.reason -eq "CONTEXT_INCOMPLETE") {
    Pass-Test "clientId vide bloqué"
}
else {
    Fail-Test "clientId vide non bloqué"
}

# TEST 5
$base["ClientId"] = "CLIENT-001"
$base["PolicyDecision"] = "BLOCKED"

$result = New-IntegrationAdapterRequest @base

if ($result.status -eq "BLOCKED" -and $result.reason -eq "POLICY_BLOCKED") {
    Pass-Test "policy BLOCKED maintenue"
}
else {
    Fail-Test "policy BLOCKED contournable"
}

# TEST 6
$base["PolicyDecision"] = "NEEDS_HUMAN"

$result = New-IntegrationAdapterRequest @base

if ($result.status -eq "NEEDS_HUMAN") {
    Pass-Test "NEEDS_HUMAN maintenu"
}
else {
    Fail-Test "NEEDS_HUMAN non respecté"
}

# TEST 7
$base["Mode"] = "LIVE"
$base["PolicyDecision"] = "LIVE"

$result = New-IntegrationAdapterRequest @base

if (
    $result.executionReady -eq $true -and
    $result.execution.mode -eq "LIVE" -and
    $result.security.secretsProvidedToAdapter -eq $false
) {
    Pass-Test "LIVE préparé sans exposition de secret"
}
else {
    Fail-Test "LIVE non conforme"
}

# TEST 8
$base["Mode"] = "LIVE"
$base["PolicyDecision"] = "SIMULATION"

$result = New-IntegrationAdapterRequest @base

if ($result.status -eq "BLOCKED" -and $result.reason -eq "POLICY_NOT_LIVE") {
    Pass-Test "LIVE bloqué lorsque la policy reste SIMULATION"
}
else {
    Fail-Test "mauvaise séparation mode/policy"
}

Write-Host ""
Write-Host "RESULTATS 7H-17"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"
Write-Host ""

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Integration Adapter Contract opérationnel."
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1