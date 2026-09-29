$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Engine = "$Root\core\runtime\execution-policy\EXECUTION-POLICY-ENGINE.ps1"
$Validator = "$Root\core\runtime\execution-policy\Validate-Execution-Policy.ps1"
$Config = "$Root\core\runtime\execution-policy\EXECUTION-POLICY-CONFIG.json"

$Passed = 0
$Failed = 0

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "       7H-15 EXECUTION POLICY TESTS" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

foreach ($File in @($Engine,$Validator,$Config)) {

    if (-not (Test-Path -LiteralPath $File)) {
        Write-Host "Fichier absent : $File" -ForegroundColor Red
        exit 1
    }
}

# ============================================================
# TEST 1 : CONFIG
# ============================================================

Write-Host "TEST 1 : CONFIGURATION"

& $Validator -ConfigPath $Config

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
    -AuthorizationDecision "AUTHORIZED" `
    -WorkerId "MAYA" `
    -SkillId "CRM_AUTOMATION" `
    -ToolId "CRM" `
    -Action "READ" `
    -Mode "SIMULATION"

if ($r2.decision -eq "SIMULATION" -and $r2.allowed -eq $true) {
    Write-Host "PASS : SIMULATION" -ForegroundColor Green
    $Passed++
}
else {
    Write-Host "FAIL" -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 3 : LIVE DESACTIVE
# ============================================================

Write-Host ""
Write-Host "TEST 3 : LIVE DESACTIVE"

$r3 = & $Engine `
    -AuthorizationDecision "AUTHORIZED" `
    -WorkerId "MAYA" `
    -SkillId "CRM_AUTOMATION" `
    -ToolId "CRM" `
    -Action "READ" `
    -Mode "LIVE"

if ($r3.decision -eq "BLOCKED" -and $r3.status -eq "LIVE_DISABLED") {
    Write-Host "PASS : LIVE bloque par défaut." -ForegroundColor Green
    $Passed++
}
else {
    Write-Host "FAIL" -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 4 : FINANCE
# ============================================================

Write-Host ""
Write-Host "TEST 4 : FINANCE"

$r4 = & $Engine `
    -AuthorizationDecision "AUTHORIZED" `
    -WorkerId "MAYA" `
    -SkillId "STRATEGIE" `
    -ToolId "PAYMENTS" `
    -Action "FINANCIAL_COMMIT" `
    -Mode "SIMULATION" `
    -FinancialRequested

if ($r4.decision -eq "NEEDS_HUMAN") {
    Write-Host "PASS : KADER_APPROVAL_REQUIRED." -ForegroundColor Green
    $Passed++
}
else {
    Write-Host "FAIL" -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 5 : ACTION NON AUTORISEE
# ============================================================

Write-Host ""
Write-Host "TEST 5 : AUTHORIZATION REFUSEE"

$r5 = & $Engine `
    -AuthorizationDecision "DENIED" `
    -WorkerId "SAM" `
    -SkillId "SECURITY" `
    -ToolId "CRM" `
    -Action "UPDATE" `
    -Mode "SIMULATION"

if ($r5.decision -eq "BLOCKED") {
    Write-Host "PASS : execution bloquée." -ForegroundColor Green
    $Passed++
}
else {
    Write-Host "FAIL" -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 6 : BESOIN HUMAIN
# ============================================================

Write-Host ""
Write-Host "TEST 6 : AUTHORIZATION NEEDS HUMAN"

$r6 = & $Engine `
    -AuthorizationDecision "NEEDS_HUMAN" `
    -WorkerId "MAYA" `
    -SkillId "STRATEGIE" `
    -ToolId "PAYMENTS" `
    -Action "FINANCIAL_COMMIT" `
    -Mode "LIVE"

if ($r6.decision -eq "NEEDS_HUMAN") {
    Write-Host "PASS : validation humaine maintenue." -ForegroundColor Green
    $Passed++
}
else {
    Write-Host "FAIL" -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 7 : MODE INVALIDE
# ============================================================

Write-Host ""
Write-Host "TEST 7 : MODE INVALIDE"

$r7 = & $Engine `
    -AuthorizationDecision "AUTHORIZED" `
    -WorkerId "MAYA" `
    -SkillId "CRM_AUTOMATION" `
    -ToolId "CRM" `
    -Action "READ" `
    -Mode "UNKNOWN"

if ($r7.decision -eq "BLOCKED" -and $r7.status -eq "INVALID_MODE") {
    Write-Host "PASS : mode invalide bloque." -ForegroundColor Green
    $Passed++
}
else {
    Write-Host "FAIL" -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 8 : LIVE HAUT RISQUE
# ============================================================

Write-Host ""
Write-Host "TEST 8 : LIVE / ACTION HAUT RISQUE"

$r8 = & $Engine `
    -AuthorizationDecision "AUTHORIZED" `
    -WorkerId "LUCAS" `
    -SkillId "WEBMASTER" `
    -ToolId "WORDPRESS" `
    -Action "PUBLISH" `
    -Mode "LIVE"

if ($r8.decision -eq "BLOCKED" -or $r8.decision -eq "NEEDS_HUMAN") {
    Write-Host "PASS : action LIVE à haut risque non autonome." -ForegroundColor Green
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
Write-Host "              RESULTATS 7H-15" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "PASS : $Passed" -ForegroundColor Green
Write-Host "FAIL : $Failed" -ForegroundColor Red
Write-Host ""

if ($Failed -eq 0) {

    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Execution Policy Engine opérationnel." -ForegroundColor Green
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1