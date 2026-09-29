$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Dir = Join-Path $Root "core\runtime\controlled-connectors"

$CatalogPath = Join-Path `
    $Dir `
    "CONTROLLED-CONNECTOR-CATALOG.json"

$Validator = Join-Path `
    $Dir `
    "Validate-Controlled-Connector-Catalog.ps1"

$Runtime = Join-Path `
    $Dir `
    "CONTROLLED-CONNECTOR-RUNTIME.ps1"

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
Write-Host "7H-20 - CONTROLLED EXTERNAL CONNECTORS"
Write-Host "============================================="
Write-Host ""

# ============================================================
# TEST 1
# ============================================================

try {
    & $Validator $CatalogPath | Out-Host

    if ($LASTEXITCODE -eq 0) {
        Pass-Test "Controlled Connector Catalog valide"
    }
    else {
        Fail-Test "Controlled Connector Catalog invalide"
    }
}
catch {
    Fail-Test "validation du Connector Catalog"
}

. $Runtime

# ============================================================
# TEST 2
# Résolution Gmail
# ============================================================

$gmail = Resolve-ControlledConnector `
    -CatalogPath $CatalogPath `
    -Provider "GMAIL" `
    -Category "EMAIL" `
    -Operation "READ_MESSAGES"

if (
    $gmail.status -eq "RESOLVED" -and
    $gmail.connectorId -eq "gmail.controlled"
) {
    Pass-Test "GMAIL correctement résolu"
}
else {
    Fail-Test "résolution GMAIL incorrecte"
}

# ============================================================
# TEST 3
# Opération non autorisée
# ============================================================

$result = Resolve-ControlledConnector `
    -CatalogPath $CatalogPath `
    -Provider "GMAIL" `
    -Category "EMAIL" `
    -Operation "DELETE_ALL_MESSAGES"

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "OPERATION_NOT_ALLOWED"
) {
    Pass-Test "opération non autorisée bloquée"
}
else {
    Fail-Test "opération non autorisée non bloquée"
}

# ============================================================
# TEST 4
# Provider inconnu
# ============================================================

$result = Resolve-ControlledConnector `
    -CatalogPath $CatalogPath `
    -Provider "UNKNOWN" `
    -Category "UNKNOWN" `
    -Operation "READ"

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "CONNECTOR_NOT_REGISTERED"
) {
    Pass-Test "connector inconnu bloqué"
}
else {
    Fail-Test "connector inconnu non bloqué"
}

# ============================================================
# TEST 5
# Simulation
# ============================================================

$result = Invoke-ControlledConnector `
    -Connector $gmail `
    -ExecutionId "EXEC-7H20-001" `
    -CorrelationId "CORR-7H20-001" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -CredentialRef "cred.client001.gmail" `
    -Mode "SIMULATION" `
    -Parameters @{
        mailbox = "primary"
    }

if (
    $result.status -eq "SIMULATED" -and
    $result.externalCall.performed -eq $false -and
    $result.credential.secretExposed -eq $false
) {
    Pass-Test "SIMULATION sans appel externe"
}
else {
    Fail-Test "SIMULATION non conforme"
}

# ============================================================
# TEST 6
# Controlled
# ============================================================

$result = Invoke-ControlledConnector `
    -Connector $gmail `
    -ExecutionId "EXEC-7H20-002" `
    -CorrelationId "CORR-7H20-002" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -CredentialRef "cred.client001.gmail" `
    -Mode "CONTROLLED" `
    -Parameters @{
        mailbox = "primary"
    }

if (
    $result.status -eq "CONTROLLED_READY" -and
    $result.externalCall.performed -eq $false -and
    $result.credential.secretExposed -eq $false
) {
    Pass-Test "CONTROLLED préparé sans appel externe"
}
else {
    Fail-Test "CONTROLLED non conforme"
}

# ============================================================
# TEST 7
# LIVE bloqué
# ============================================================

$result = Invoke-ControlledConnector `
    -Connector $gmail `
    -ExecutionId "EXEC-7H20-003" `
    -CorrelationId "CORR-7H20-003" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -CredentialRef "cred.client001.gmail" `
    -Mode "LIVE"

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "LIVE_EXECUTION_DISABLED"
) {
    Pass-Test "LIVE bloqué par défaut"
}
else {
    Fail-Test "LIVE accessible alors qu'il doit être bloqué"
}

# ============================================================
# TEST 8
# CredentialRef absent
# ============================================================

$result = Invoke-ControlledConnector `
    -Connector $gmail `
    -ExecutionId "EXEC-7H20-004" `
    -CorrelationId "CORR-7H20-004" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -CredentialRef "" `
    -Mode "SIMULATION"

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
# TEST 9
# Secret brut dans Parameters
# ============================================================

$result = Invoke-ControlledConnector `
    -Connector $gmail `
    -ExecutionId "EXEC-7H20-005" `
    -CorrelationId "CORR-7H20-005" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -CredentialRef "cred.client001.gmail" `
    -Mode "SIMULATION" `
    -Parameters @{
        api_key = "DO_NOT_ALLOW"
    }

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "SECRET_EXPOSURE_ATTEMPT"
) {
    Pass-Test "secret brut détecté et bloqué"
}
else {
    Fail-Test "secret brut non bloqué"
}

# ============================================================
# TEST 10
# Contexte incomplet
# ============================================================

$result = Invoke-ControlledConnector `
    -Connector $gmail `
    -ExecutionId "EXEC-7H20-006" `
    -CorrelationId "CORR-7H20-006" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "" `
    -CredentialRef "cred.client001.gmail" `
    -Mode "SIMULATION"

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

Write-Host ""
Write-Host "RESULTATS 7H-20"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"
Write-Host ""

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Controlled External Connectors opérationnels."
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1