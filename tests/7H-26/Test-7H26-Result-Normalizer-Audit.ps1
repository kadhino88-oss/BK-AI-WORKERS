$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Dir = Join-Path $Root "core\runtime\result-audit"
$AuditDir = Join-Path $Dir "audit"

$ConfigPath = Join-Path `
    $Dir `
    "RESULT-AUDIT-CONFIG.json"

$Validator = Join-Path `
    $Dir `
    "Validate-Result-Audit.ps1"

$Runtime = Join-Path `
    $Dir `
    "RESULT-NORMALIZER-RUNTIME.ps1"

$AuditPath = Join-Path `
    $AuditDir `
    "EXECUTION-AUDIT-7H26.jsonl"

if (Test-Path -LiteralPath $AuditPath) {
    Remove-Item -LiteralPath $AuditPath -Force
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
Write-Host "7H-26 - RESULT NORMALIZER & AUDIT LEDGER"
Write-Host "============================================="
Write-Host ""

# ============================================================
# TEST 1
# ============================================================

try {
    & $Validator $ConfigPath | Out-Host

    if ($LASTEXITCODE -eq 0) {
        Pass-Test "Result Audit Config valide"
    }
    else {
        Fail-Test "Result Audit Config invalide"
    }
}
catch {
    Fail-Test "validation Result Audit"
}

. $Runtime

# ============================================================
# BASE
# ============================================================

$base = @{
    ConfigPath = $ConfigPath
    ExecutionId = "EXEC-7H26-001"
    CorrelationId = "CORR-7H26-001"
    TenantId = "TENANT-001"
    ClientId = "CLIENT-001"
    ProjectId = "PROJECT-001"
    WorkerId = "MAYA"
    SkillId = "SKILL-001"
    TaskId = "TASK-001"
    ToolId = "TOOL-001"
    ConnectorId = "crm.controlled"
    AdapterId = "crm.default"
    Action = "READ"
    Mode = "SIMULATION"
    Status = "SIMULATED"
    Reason = ""
    FailedStage = ""
    Provider = "CRM"
    Operation = "READ_CONTACT"
    Attempt = 1
    DurationMs = 125
    ExternalCallPerformed = $false
    SecretExposure = $false
    Data = @{
        contactId = "CONTACT-001"
        name = "Client Test"
    }
}

# ============================================================
# TEST 2
# Normalisation
# ============================================================

$result = Normalize-ExecutionResult @base

if (
    $result.status -eq "SIMULATED" -and
    $result.resultVersion -eq "1.0" -and
    $result.executionId -eq "EXEC-7H26-001" -and
    $result.externalCallPerformed -eq $false
) {
    Pass-Test "résultat correctement normalisé"
}
else {
    Fail-Test "normalisation incorrecte"
}

# ============================================================
# TEST 3
# Secret sanitization
# ============================================================

$test = $base.Clone()

$test.Data = @{
    contactId = "CONTACT-001"
    api_key = "SECRET_SHOULD_DISAPPEAR"
    access_token = "TOKEN_SHOULD_DISAPPEAR"
    password = "PASSWORD_SHOULD_DISAPPEAR"
    nested = @{
        client_secret = "SECRET"
    }
}

$result = Normalize-ExecutionResult @test

$serialized = $result | ConvertTo-Json -Depth 20 -Compress

if (
    $serialized -notmatch "SECRET_SHOULD_DISAPPEAR" -and
    $serialized -notmatch "TOKEN_SHOULD_DISAPPEAR" -and
    $serialized -notmatch "PASSWORD_SHOULD_DISAPPEAR"
) {
    Pass-Test "données sensibles supprimées du résultat"
}
else {
    Fail-Test "données sensibles présentes dans le résultat"
}

# ============================================================
# TEST 4
# Context incomplete
# ============================================================

$test = $base.Clone()
$test.ProjectId = ""

$result = Normalize-ExecutionResult @test

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
# TEST 5
# Invalid status
# ============================================================

$test = $base.Clone()
$test.Status = "INVALID_STATUS"

$result = Normalize-ExecutionResult @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "INVALID_RESULT_STATUS"
) {
    Pass-Test "statut de résultat invalide bloqué"
}
else {
    Fail-Test "statut invalide non bloqué"
}

# ============================================================
# TEST 6
# LIVE
# ============================================================

$test = $base.Clone()
$test.Mode = "LIVE"

$result = Normalize-ExecutionResult @test

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
# TEST 7
# Secret exposure flag
# ============================================================

$test = $base.Clone()
$test.SecretExposure = $true

$result = Normalize-ExecutionResult @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "SECRET_EXPOSURE_DETECTED"
) {
    Pass-Test "secret exposure bloqué"
}
else {
    Fail-Test "secret exposure non bloqué"
}

# ============================================================
# TEST 8
# Audit ledger
# ============================================================

$result = Normalize-ExecutionResult @base

$audit = Write-AuditLedgerEntry `
    -AuditPath $AuditPath `
    -NormalizedResult $result

if (
    $audit.status -eq "RECORDED" -and
    (Test-Path -LiteralPath $AuditPath)
) {
    Pass-Test "entrée d'audit enregistrée"
}
else {
    Fail-Test "entrée d'audit non enregistrée"
}

# ============================================================
# TEST 9
# Audit secret check
# ============================================================

$check = Test-AuditLedgerForSecrets `
    -AuditPath $AuditPath

if (
    $check.status -eq "VALID" -and
    $check.secretExposure -eq $false
) {
    Pass-Test "audit ledger sans secret"
}
else {
    Fail-Test "secret détecté dans audit ledger"
}

# ============================================================
# TEST 10
# Append-only
# ============================================================

$before = (Get-Content `
    -LiteralPath $AuditPath `
    -Encoding UTF8).Count

$test = $base.Clone()

$test.ExecutionId = "EXEC-7H26-002"
$test.CorrelationId = "CORR-7H26-002"

$result2 = Normalize-ExecutionResult @test

$audit2 = Write-AuditLedgerEntry `
    -AuditPath $AuditPath `
    -NormalizedResult $result2

$after = (Get-Content `
    -LiteralPath $AuditPath `
    -Encoding UTF8).Count

if (
    $audit2.status -eq "RECORDED" -and
    $after -eq ($before + 1)
) {
    Pass-Test "audit ledger append-only respecté"
}
else {
    Fail-Test "audit ledger append-only incorrect"
}
# TEST 11
# Negative duration
# ============================================================

$test = $base.Clone()
$test.DurationMs = -1

$result = Normalize-ExecutionResult @test

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "INVALID_DURATION"
) {
    Pass-Test "durée négative bloquée"
}
else {
    Fail-Test "durée négative non bloquée"
}

# ============================================================
# TEST 12
# Final SUCCESS
# ============================================================

$test = $base.Clone()
$test.Status = "SUCCESS"
$test.Mode = "CONTROLLED"
$test.DurationMs = 250

$result = Normalize-ExecutionResult @test

if (
    $result.status -eq "SUCCESS" -and
    $result.mode -eq "CONTROLLED" -and
    $result.externalCallPerformed -eq $false
) {
    Pass-Test "SUCCESS contrôlé correctement normalisé"
}
else {
    Fail-Test "SUCCESS contrôlé incorrect"
}

Write-Host ""
Write-Host "RESULTATS 7H-26"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"
Write-Host ""

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Execution Result Normalizer & Audit Ledger opérationnels."
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1