$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Engine = "$Root\core\runtime\integration-enforcement\INTEGRATION-RUNTIME-ENFORCER.ps1"
$Validator = "$Root\core\runtime\integration-enforcement\Validate-Integration-Runtime-Enforcement.ps1"

$Passed = 0
$Failed = 0

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "        7H-16 INTEGRATION RUNTIME TESTS" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# PRECHECK
# ============================================================

foreach ($File in @($Engine,$Validator)) {

    if (-not (Test-Path -LiteralPath $File)) {

        Write-Host "FICHIER ABSENT : $File" -ForegroundColor Red
        exit 1
    }
}

# ============================================================
# TEST 1 : VALIDATOR
# ============================================================

Write-Host "TEST 1 : VALIDATION ENGINE"

& $Validator -EnginePath $Engine

if ($LASTEXITCODE -eq 0) {

    Write-Host "PASS" -ForegroundColor Green
    $Passed++

}
else {

    Write-Host "FAIL" -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 2 : SIMULATION
# ============================================================

Write-Host ""
Write-Host "TEST 2 : SIMULATION"

$r2 = & $Engine `
    -PolicyDecision "SIMULATION" `
    -PolicyStatus "SIMULATION_ALLOWED" `
    -PolicyAllowed $true `
    -WorkerId "MAYA" `
    -SkillId "CRM_AUTOMATION" `
    -ToolId "CRM" `
    -Action "READ" `
    -ExecutionId "EXEC-7H16-001" `
    -CorrelationId "CORR-7H16-001" `
    -TenantId "TENANT-7H16-001" `
    -ClientId "CLIENT-7H16-001" `
    -ProjectId "PROJECT-7H16-001" `
    -Mode "SIMULATION"

if (
    $r2.decision -eq "SIMULATION" -and
    $r2.executionAllowed -eq $true -and
    $r2.externalCallAllowed -eq $false
) {

    Write-Host "PASS : simulation autorisée sans appel externe." -ForegroundColor Green
    $Passed++

}
else {

    Write-Host "FAIL" -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 3 : SIMULATION + EXECUTE
# ============================================================

Write-Host ""
Write-Host "TEST 3 : SIMULATION + EXECUTE"

$r3 = & $Engine `
    -PolicyDecision "SIMULATION" `
    -PolicyStatus "SIMULATION_ALLOWED" `
    -PolicyAllowed $true `
    -WorkerId "MAYA" `
    -SkillId "CRM_AUTOMATION" `
    -ToolId "CRM" `
    -Action "READ" `
    -ExecutionId "EXEC-7H16-002" `
    -CorrelationId "CORR-7H16-002" `
    -TenantId "TENANT-7H16-001" `
    -ClientId "CLIENT-7H16-001" `
    -ProjectId "PROJECT-7H16-001" `
    -Mode "SIMULATION" `
    -Execute

if (
    $r3.decision -eq "BLOCKED" -and
    $r3.externalCallAllowed -eq $false
) {

    Write-Host "PASS : appel externe interdit en simulation." -ForegroundColor Green
    $Passed++

}
else {

    Write-Host "FAIL" -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 4 : POLICY BLOCKED
# ============================================================

Write-Host ""
Write-Host "TEST 4 : POLICY BLOCKED"

$r4 = & $Engine `
    -PolicyDecision "BLOCKED" `
    -PolicyStatus "AUTHORIZATION_FAILED" `
    -PolicyAllowed $false `
    -WorkerId "SAM" `
    -SkillId "SECURITY" `
    -ToolId "CRM" `
    -Action "UPDATE" `
    -ExecutionId "EXEC-7H16-003" `
    -CorrelationId "CORR-7H16-003" `
    -TenantId "TENANT-7H16-001" `
    -ClientId "CLIENT-7H16-001" `
    -ProjectId "PROJECT-7H16-001" `
    -Mode "SIMULATION"

if ($r4.decision -eq "BLOCKED") {

    Write-Host "PASS : policy bloquée maintenue." -ForegroundColor Green
    $Passed++

}
else {

    Write-Host "FAIL" -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 5 : NEEDS HUMAN
# ============================================================

Write-Host ""
Write-Host "TEST 5 : NEEDS HUMAN"

$r5 = & $Engine `
    -PolicyDecision "NEEDS_HUMAN" `
    -PolicyStatus "KADER_APPROVAL_REQUIRED" `
    -PolicyAllowed $false `
    -WorkerId "MAYA" `
    -SkillId "STRATEGIE" `
    -ToolId "PAYMENTS" `
    -Action "FINANCIAL_COMMIT" `
    -ExecutionId "EXEC-7H16-004" `
    -CorrelationId "CORR-7H16-004" `
    -TenantId "TENANT-7H16-001" `
    -ClientId "CLIENT-7H16-001" `
    -ProjectId "PROJECT-7H16-001" `
    -Mode "LIVE"

if (
    $r5.decision -eq "NEEDS_HUMAN" -and
    $r5.externalCallAllowed -eq $false
) {

    Write-Host "PASS : validation humaine maintenue." -ForegroundColor Green
    $Passed++

}
else {

    Write-Host "FAIL" -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 6 : LIVE PREPARATION
# ============================================================

Write-Host ""
Write-Host "TEST 6 : LIVE / PREPARATION"

$r6 = & $Engine `
    -PolicyDecision "LIVE" `
    -PolicyStatus "LIVE_ALLOWED" `
    -PolicyAllowed $true `
    -WorkerId "LUCAS" `
    -SkillId "WEBMASTER" `
    -ToolId "WORDPRESS" `
    -Action "PUBLISH" `
    -ExecutionId "EXEC-7H16-005" `
    -CorrelationId "CORR-7H16-005" `
    -TenantId "TENANT-7H16-001" `
    -ClientId "CLIENT-7H16-001" `
    -ProjectId "PROJECT-7H16-001" `
    -Mode "LIVE"

if (
    $r6.decision -eq "LIVE_READY" -and
    $r6.externalCallAllowed -eq $false
) {

    Write-Host "PASS : LIVE prépare sans exécution externe." -ForegroundColor Green
    $Passed++

}
else {

    Write-Host "FAIL" -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 7 : LIVE EXECUTION EXPLICIT
# ============================================================

Write-Host ""
Write-Host "TEST 7 : LIVE / EXECUTION EXPLICITE"

$r7 = & $Engine `
    -PolicyDecision "LIVE" `
    -PolicyStatus "LIVE_ALLOWED" `
    -PolicyAllowed $true `
    -WorkerId "LUCAS" `
    -SkillId "WEBMASTER" `
    -ToolId "WORDPRESS" `
    -Action "PUBLISH" `
    -ExecutionId "EXEC-7H16-006" `
    -CorrelationId "CORR-7H16-006" `
    -TenantId "TENANT-7H16-001" `
    -ClientId "CLIENT-7H16-001" `
    -ProjectId "PROJECT-7H16-001" `
    -Mode "LIVE" `
    -Execute

if (
    $r7.decision -eq "LIVE_EXECUTION_AUTHORIZED" -and
    $r7.externalCallAllowed -eq $true
) {

    Write-Host "PASS : Runtime autorise le passage vers l'adaptateur." -ForegroundColor Green
    $Passed++

}
else {

    Write-Host "FAIL" -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 8 : CONTEXTE INCOMPLET
# ============================================================

Write-Host ""
Write-Host "TEST 8 : CONTEXTE INCOMPLET"

$r8 = & $Engine `
    -PolicyDecision "LIVE" `
    -PolicyStatus "LIVE_ALLOWED" `
    -PolicyAllowed $true `
    -WorkerId "LUCAS" `
    -SkillId "WEBMASTER" `
    -ToolId "WORDPRESS" `
    -Action "PUBLISH" `
    -ExecutionId "" `
    -CorrelationId "CORR-7H16-007" `
    -TenantId "TENANT-7H16-001" `
    -ClientId "CLIENT-7H16-001" `
    -ProjectId "PROJECT-7H16-001" `
    -Mode "LIVE"

if (
    $r8.decision -eq "BLOCKED" -and
    $r8.status -eq "CONTEXT_INCOMPLETE"
) {

    Write-Host "PASS : contexte incomplet bloqué." -ForegroundColor Green
    $Passed++

}
else {

    Write-Host "FAIL" -ForegroundColor Red
    $Failed++
}

# ============================================================
# RESULTAT
# ============================================================

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "              RESULTATS 7H-16" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "PASS : $Passed" -ForegroundColor Green
Write-Host "FAIL : $Failed" -ForegroundColor Red
Write-Host ""

if ($Failed -eq 0) {

    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Integration Runtime Enforcement opérationnel." -ForegroundColor Green
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1